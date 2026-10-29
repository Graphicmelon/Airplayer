// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Metal
import QuartzCore
import IOSurface

/// Samples the received IOSurface directly as a Metal texture. No CGImage or
/// CPU texture upload is involved in normal rendering.
private final class VideoDisplayClock: NSObject {
    weak var view: MetalVideoView?
    init(_ view: MetalVideoView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.displayTick() }
}

final class MetalVideoView: NSView {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let nv12Pipeline: MTLRenderPipelineState
    private let metal = CAMetalLayer()
    private let inFlight = DispatchSemaphore(value: 1)
    // Main-thread state: keep only the newest requested image while the GPU
    // is busy; retry it on the next display tick even if input has stopped.
    private var needsRender = false
    private var refreshLink: CADisplayLink?
    private(set) var currentFrame: SurfaceFrame?
    private(set) var submittedFrames: UInt64 = 0
    private(set) var skippedFrames: UInt64 = 0
    private(set) var lastSubmittedSequence: UInt64 = 0
    var onError: ((String) -> Void)?
    var onStats: ((String) -> Void)?
    let timings = PipelineTimings()

    init(rendering: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Airplayer.Metal", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法创建 Metal 显示设备。"])
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex video_vertex(uint id [[vertex_id]]) {
            const float2 p[] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};
            const float2 t[] = {float2(0,1), float2(1,1), float2(0,0), float2(1,0)};
            return {float4(p[id],0,1), t[id]};
        }
        fragment float4 video_fragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            return image.sample(s, v.uv);
        }
        struct YUV { float4 coefficients; float4 ranges; float4 scales; float4 extra; };
        float4 cubic_weights(float t) {
            float t2 = t*t, t3 = t2*t;
            return float4(-0.5*t + t2 - 0.5*t3, 1.0 - 2.5*t2 + 1.5*t3,
                          0.5*t + 2.0*t2 - 1.5*t3, -0.5*t2 + 0.5*t3);
        }
        float luma_sample(texture2d<float> y, float2 uv, float2 extent, bool upscale) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 size = float2(y.get_width(), y.get_height());
            float2 point = uv * size - 0.5;
            if (!upscale) return y.sample(s, clamp(uv, 0.5/size, (extent-0.5)/size)).r;
            int2 base = int2(floor(point));
            float4 wx = cubic_weights(fract(point.x)), wy = cubic_weights(fract(point.y));
            float value = 0.0, low = 1.0, high = 0.0;
            for (int j = 0; j < 4; ++j) {
                for (int i = 0; i < 4; ++i) {
                    uint2 p = uint2(clamp(base + int2(i-1,j-1), int2(0), int2(extent)-1));
                    float sample = y.read(p).r;
                    value += sample * wx[i] * wy[j];
                    if (i >= 1 && i <= 2 && j >= 1 && j <= 2) {
                        low = min(low, sample); high = max(high, sample);
                    }
                }
            }
            // Preserve edge contrast without bright/dark ringing around text.
            return clamp(value, low, high);
        }
        fragment float4 nv12_fragment(Vertex v [[stage_in]], texture2d<float> y [[texture(0)]],
            texture2d<float> uv [[texture(1)]], constant YUV &u [[buffer(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float Y = (luma_sample(y, v.uv * u.scales.xy, u.extra.zw, u.extra.y > 0.5)
                       - u.ranges.y) * u.ranges.x;
            float2 chromaSize = float2(uv.get_width(), uv.get_height());
            float2 chromaUV = clamp(v.uv * u.scales.zw, 0.5/chromaSize,
                                   u.scales.zw - 0.5/chromaSize);
            float2 C = (uv.sample(s, chromaUV).rg - u.ranges.w) * u.ranges.z;
            float3 rgb = clamp(float3(Y + u.coefficients.x*C.y,
                Y + u.coefficients.y*C.x + u.coefficients.z*C.y,
                Y + u.coefficients.w*C.x), 0.0, 1.0);
            float3 linear;
            if (u.extra.x > 0.5)
                linear = select(rgb / 4.5, pow((rgb + 0.099) / 1.099, float3(1.0 / 0.45)), rgb >= 0.081);
            else
                linear = select(rgb / 12.92, pow((rgb + 0.055) / 1.055, float3(2.4)), rgb > 0.04045);
            return float4(linear, 1);
        }
        """, options: nil)
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = library.makeFunction(name: "video_vertex")
        description.fragmentFunction = library.makeFunction(name: "video_fragment")
        description.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: description)
        description.fragmentFunction = library.makeFunction(name: "nv12_fragment")
        nv12Pipeline = try device.makeRenderPipelineState(descriptor: description)
        super.init(frame: .zero)
        wantsLayer = true
        metal.device = device
        metal.pixelFormat = .bgra8Unorm_srgb
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.framebufferOnly = true
        metal.maximumDrawableCount = 2
        // Synchronize full-frame swaps and submit them with the compositor.
        metal.displaySyncEnabled = true
        metal.isOpaque = true
        metal.backgroundColor = NSColor.black.cgColor
        metal.presentsWithTransaction = true
        layer = metal
        if rendering {
            let link = displayLink(target: VideoDisplayClock(self), selector: #selector(VideoDisplayClock.tick(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            refreshLink = link
        }
    }

    deinit { refreshLink?.invalidate() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        updateDrawableSize()
        needsRender = currentFrame != nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
        needsRender = currentFrame != nil
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let refresh = Float(window?.screen?.maximumFramesPerSecond ?? 60)
        refreshLink?.preferredFrameRateRange = CAFrameRateRange(minimum: refresh, maximum: refresh, preferred: refresh)
    }

    func display(_ frame: SurfaceFrame?) {
        currentFrame = frame
        needsRender = frame != nil
        refreshLink?.isPaused = frame == nil
        // Transactions already synchronize the actual presentation. Avoid a
        // second, independent wait for the next display-link callback.
        if frame != nil { render() }
    }

    fileprivate func displayTick() {
        guard needsRender else { return }
        render()
    }

    private func render() {
        guard let frame = currentFrame, let window, window.isVisible,
              window.occlusionState.contains(.visible), !isHidden,
              bounds.width > 0, bounds.height > 0 else { return }
        guard inFlight.wait(timeout: .now()) == .success else { skippedFrames &+= 1; return }
        guard let textures = textures(for: frame),
              let drawable = metal.nextDrawable(), let command = queue.makeCommandBuffer() else {
            inFlight.signal()
            skippedFrames &+= 1
            return
        }
        guard encode(textures: textures, frame: frame, target: drawable.texture, command: command) else {
            inFlight.signal(); return
        }
        needsRender = false
        let semaphore = inFlight
        command.addCompletedHandler { [weak self, frame, textures] buffer in
            // The shared buffer may be reused only after GPU execution finishes.
            withExtendedLifetime((frame, textures)) {}
            semaphore.signal()
            let error = buffer.error
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.onError?("视频显示失败：\(error.localizedDescription)")
                }
            }
        }
        let timings = self.timings
        drawable.addPresentedHandler { [weak self, frame] drawable in
            let presentedNS = UInt64(max(0, drawable.presentedTime) * 1_000_000_000)
            if let report = timings.record(frame: frame, presentedNS: presentedNS) {
                DispatchQueue.main.async { self?.onStats?(report) }
            }
        }
        command.commit()
        // Wait for scheduling, never for GPU completion or source timestamps.
        command.waitUntilScheduled()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        drawable.present()
        CATransaction.commit()
        // Submit the implicit transaction promptly instead of waiting for a
        // later AppKit run-loop pass.
        CATransaction.flush()
        submittedFrames &+= 1
        lastSubmittedSequence = frame.sequence
    }

    private func textures(for frame: SurfaceFrame) -> [MTLTexture]? {
        let formats: [MTLPixelFormat] = frame.isNV12 ? [.r8Unorm, .rg8Unorm] : [.bgra8Unorm_srgb]
        var textures = [MTLTexture]()
        for (plane, format) in formats.enumerated() {
            let width = frame.isNV12 ? IOSurfaceGetWidthOfPlane(frame.surface, plane) : IOSurfaceGetWidth(frame.surface)
            let height = frame.isNV12 ? IOSurfaceGetHeightOfPlane(frame.surface, plane) : IOSurfaceGetHeight(frame.surface)
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            description.storageMode = .shared
            description.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: description, iosurface: frame.surface, plane: plane) else { return nil }
            textures.append(texture)
        }
        return textures
    }

    private func encode(textures: [MTLTexture], frame: SurfaceFrame, target: MTLTexture,
                        command: MTLCommandBuffer) -> Bool {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let width = Double(target.width), height = Double(target.height)
        let scale = min(width / Double(frame.width), height / Double(frame.height))
        let videoWidth = Double(frame.width) * scale, videoHeight = Double(frame.height) * scale
        encoder.setViewport(MTLViewport(originX: (width - videoWidth) / 2, originY: (height - videoHeight) / 2,
            width: videoWidth, height: videoHeight, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(frame.isNV12 ? nv12Pipeline : pipeline)
        for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
        if frame.isNV12 {
            let coefficients: [Float]
            switch frame.colorInfo & 255 {
            case 2: coefficients = [1.402, -0.344136, -0.714136, 1.772]
            case 3: coefficients = [1.4746, -0.164553, -0.571353, 1.8814]
            default: coefficients = [1.5748, -0.187324, -0.468124, 1.8556]
            }
            let ranges: [Float] = frame.isFullRange ? [1, 0, 1, 128/255] : [255/219, 16/255, 255/224, 128/255]
            let scales: [Float] = [Float(frame.width) / Float(textures[0].width), Float(frame.height) / Float(textures[0].height),
                Float((frame.width + 1)/2) / Float(textures[1].width), Float((frame.height + 1)/2) / Float(textures[1].height)]
            let uniforms = coefficients + ranges + scales + [frame.colorInfo & 256 == 0 ? 0 : 1,
                scale > 1.001 ? 1 : 0, Float(frame.width), Float(frame.height)]
            uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    #if AIRPLAYER_DIAGNOSTICS
    func snapshotImage(size: CGSize? = nil) -> CGImage? {
        guard let frame = currentFrame else { return nil }
        let outputSize = size ?? metal.drawableSize
        let width = max(1, Int(outputSize.width)), height = max(1, Int(outputSize.height))
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
            width: width, height: height, mipmapped: false)
        target.storageMode = .shared
        target.usage = .renderTarget
        guard let textures = textures(for: frame),
              let output = device.makeTexture(descriptor: target), let command = queue.makeCommandBuffer(),
              encode(textures: textures, frame: frame, target: output, command: command) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    #endif
}
