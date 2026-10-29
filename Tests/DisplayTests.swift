// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreVideo
import QuartzCore
import IOSurface

@main struct DisplayTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.005), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            NSApp.updateWindows()
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        } while Date() < until
    }
    static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        let view = try MetalVideoView(rendering: true)
        let metal = view.layer as! CAMetalLayer
        expect(metal.displaySyncEnabled && metal.presentsWithTransaction, "default full-frame synchronized transaction presentation")
        var pixels: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true]
        expect(CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            attributes as CFDictionary, &pixels) == kCVReturnSuccess, "create NV12 test image")
        let buffer = pixels!
        CVPixelBufferLockBaseAddress(buffer, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<8 { for col in 0..<8 { y[row*stride+col] = col < 4 ? 64 : 192 } }
        memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!, 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)*4)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let surface = CVPixelBufferGetIOSurface(buffer)!.takeUnretainedValue()
        func frame(_ sequence: UInt64) -> SurfaceFrame {
            var event = APFrameEvent()
            event.surface_port = IOSurfaceCreateMachPort(surface)
            event.session = 1; event.sequence = sequence
            event.width = 8; event.height = 8; event.color_info = 1
            return SurfaceFrame(event: event)!
        }
        view.display(frame(1))
        func row(_ size: Int) -> [Int] {
            let image = view.snapshotImage(size: CGSize(width: size, height: size))!
            let data = image.dataProvider!.data!
            let bytes = CFDataGetBytePtr(data)!
            return (0..<size).map { Int(bytes[(size/2)*image.bytesPerRow + $0*4]) }
        }
        let native = row(8)
        expect(native.prefix(4).allSatisfy { abs($0-64) <= 1 }, "1:1 dark luma remains exact")
        expect(native.suffix(4).allSatisfy { abs($0-192) <= 1 }, "1:1 light luma remains exact")
        let scaled = row(32)
        expect(scaled.allSatisfy { (63...193).contains($0) }, "no ringing beyond source contrast")
        expect(scaled[14] < 80 && scaled[17] > 176, "upscaled edge is less soft than bilinear")
        expect(zip(scaled, scaled.dropFirst()).allSatisfy { $0 <= $1 }, "edge remains monotonic")
        expect(row(4) == [64,64,192,192], "downscaling preserves aligned flat regions")

        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pump(0.3)
        view.display(frame(2))
        // No run-loop turn between these calls: the last frame must be retained
        // until the display callback can render, even if input stops.
        for sequence in 3...20 { view.display(frame(UInt64(sequence))) }
        let deadline = Date().addingTimeInterval(3)
        while view.lastSubmittedSequence != 20 && Date() < deadline {
            pump(0.01)
        }
        print("display submitted=\(view.submittedFrames) last=\(view.lastSubmittedSequence) skipped=\(view.skippedFrames) visible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) bounds=\(view.bounds)")
        expect(view.lastSubmittedSequence == 20, "newest pending frame is submitted without further input")
        view.display(nil)
        let count = view.submittedFrames
        pump(0.1)
        expect(view.submittedFrames == count, "disconnect cancels pending rendering")
        print("PASS: Metal luma scaling, edge bounds, display-clock latest frame and disconnect")
    }
}
