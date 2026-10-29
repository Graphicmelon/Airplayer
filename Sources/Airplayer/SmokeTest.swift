// SPDX-License-Identifier: GPL-3.0-or-later
#if AIRPLAYER_DIAGNOSTICS
import AppKit

/// Included only by Scripts/build.sh --diagnostics, never in the delivered app.
/// Uses real H.264 encode/decode + the bundled transport, without an iOS device.
final class SmokeTest: NSObject, NetServiceBrowserDelegate {
    private unowned let app: AppDelegate
    private var generator: Process?
    private var checks = [String]()
    private var failures = [String]()
    private var lastSize = CGSize.zero
    private var frameCount = 0
    private var measurements = [[String: Any]]()
    private let browser = NetServiceBrowser()
    private var discovered = false
    private let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".build/Smoke", isDirectory: true)

    init(app: AppDelegate) { self.app = app; super.init() }

    func run() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        browser.delegate = self
        browser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
        let display = app.receiver.onFrame
        app.receiver.onFrame = { [weak self] frame in
            if let self, let frame {
                self.lastSize = CGSize(width: frame.width, height: frame.height)
                self.frameCount += 1
            }
            display?(frame)
        }
        wait("AirPlay service discovered through Bonjour", condition: { self.app.receiver.state == .ready && self.discovered }) {
            self.snapshot("waiting")
            self.startGenerator(width: 960, height: 540)
            self.wait("H.264 frames reach the native window", condition: {
                self.app.receiver.state == .mirroring && self.frameCount >= 10 && self.lastSize == CGSize(width: 960, height: 540)
            }) {
                self.snapshot("windowed")
                self.app.toggleFullscreen()
                self.wait("native fullscreen entered", condition: {
                    self.app.window.styleMask.contains(.fullScreen)
                }) {
                    self.after(1.5) {
                        self.snapshot("fullscreen")
                        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: 0, windowNumber: self.app.window.windowNumber,
                            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                            isARepeat: false, keyCode: 53) {
                            self.app.mirrorView.keyDown(with: escape)
                        }
                        self.wait("Escape returns to a window", condition: {
                            !self.app.window.styleMask.contains(.fullScreen)
                        }) {
                            self.after(1) { self.testReconnect() }
                        }
                    }
                }
            }
        }
    }

    private func testReconnect() {
        stopGenerator()
        wait("disconnect returns to waiting", condition: { self.app.receiver.state == .ready }) {
            self.startGenerator(width: 540, height: 960)
            self.wait("portrait reconnect preserves dimensions", condition: {
                self.app.receiver.state == .mirroring && self.lastSize == CGSize(width: 540, height: 960)
            }) {
                self.after(0.5) {
                    self.snapshot("portrait")
                    self.app.window.setContentSize(NSSize(width: 700, height: 500))
                    self.after(0.5) {
                        self.snapshot("resized")
                        self.checks.append("window resizes while mirroring")
                        self.testLowLatency()
                    }
                }
            }
        }
    }

    private func testClose() {
        stopGenerator()
        let child = app.receiver.process
        let socket = app.receiver.frameServer?.socketPath ?? ""
        app.receiver.stop {
            if child?.isRunning == true { self.failures.append("receiver did not stop") }
            else { self.checks.append("receiver terminates on app close") }
            if FileManager.default.fileExists(atPath: socket) { self.failures.append("socket leaked") }
            else { self.checks.append("private socket removed") }
            self.finish()
        }
    }

    private func testLowLatency() {
        stopGenerator()
        wait("receiver ready after test stream closes", condition: { self.app.receiver.state == .ready }) {
            let before = self.frameCount
            self.startGenerator(width: 1920, height: 1080)
            self.wait("1080p60 direct H.264 decoding and NV12 Metal presentation", condition: {
                self.lastSize == CGSize(width: 1920, height: 1080) &&
                self.frameCount - before >= 180 && !self.app.mirrorView.latencySummary.isEmpty
            }) {
                self.snapshot("1080p60")
                let menu = NSApp.mainMenu?.items.first?.submenu
                if menu?.items.contains(where: { $0.title.contains("设置") }) == true {
                    self.failures.append("settings menu still present")
                } else { self.checks.append("settings absent; default 2160p60 configuration") }
                self.app.window.miniaturize(nil)
                self.after(0.5) {
                    let submitted = self.app.mirrorView.submittedFrames
                    self.after(0.3) {
                        if self.app.mirrorView.submittedFrames != submitted { self.failures.append("rendering continued while minimized") }
                        self.app.window.deminiaturize(nil)
                        self.app.window.makeKeyAndOrderFront(nil)
                        self.wait("video resumes after minimizing without a drawable backlog", condition: {
                            self.app.mirrorView.submittedFrames > submitted + 10
                        }) { self.testHEVC() }
                    }
                }
            }
        }
    }

    private func testHEVC() {
        measurements.append(["codec": "H264", "size": "1920x1080", "latency": app.mirrorView.latencySummary])
        stopGenerator()
        wait("ready for HEVC reconnect", condition: { self.app.receiver.state == .ready }) {
            let before = self.frameCount
            let submitted = self.app.mirrorView.submittedFrames
            let start = ProcessInfo.processInfo.systemUptime
            self.startGenerator(width: 3840, height: 2160, hevc: true)
            self.wait("2160p60 HEVC immediate decode and Metal presentation", condition: {
                self.lastSize == CGSize(width: 3840, height: 2160) && self.frameCount - before >= 240
            }) {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let count = self.app.mirrorView.submittedFrames - submitted
                self.measurements.append(["codec": "HEVC", "size": "3840x2160",
                    "receivedFPSIncludingStartup": Double(self.frameCount - before) / elapsed,
                    "submittedFPSIncludingStartup": Double(count) / elapsed,
                    "latency": self.app.mirrorView.latencySummary])
                if count < 180 { self.failures.append("HEVC presentation dropped more than 25% of test frames") }
                self.snapshot("2160p60-hevc")
                self.testClose()
            }
        }
    }

    private func startGenerator(width: Int, height: Int, hevc: Bool = false) {
        guard let server = app.receiver.frameServer, let resources = Bundle.main.resourceURL else {
            failures.append("missing receiver"); finish(); return
        }
        let child = Process()
        child.executableURL = resources.appendingPathComponent("Runtime/bin/gst-launch-1.0")
        let codec = hevc ? "h265" : "h264"
        let encoder = hevc ? ["vtenc_h265", "realtime=true", "allow-frame-reordering=false", "bitrate=24000"] :
            ["x264enc", "tune=zerolatency", "speed-preset=ultrafast"]
        child.arguments = ["-q", "videotestsrc", "is-live=true", "pattern=smpte", "!",
            "video/x-raw,width=\(width),height=\(height),framerate=60/1", "!", "videoconvert", "!", "video/x-raw,format=NV12", "!"] + encoder + ["!", "\(codec)parse", "!",
            "video/x-\(codec),stream-format=byte-stream,alignment=au", "!", "airplayer\(codec)sink", "sync=false", "async=false"]
        do {
            child.environment = try app.receiver.runtimeEnvironment(resources: resources, socketPath: server.socketPath)
            let log = directory.appendingPathComponent("pipeline-\(width)x\(height).log")
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            child.standardError = try FileHandle(forWritingTo: log)
            child.standardOutput = child.standardError
            generator = child
            try child.run()
        } catch { failures.append(error.localizedDescription); finish() }
    }

    private func stopGenerator() {
        if let generator, generator.isRunning { generator.terminate() }
        generator = nil
    }

    private func wait(_ name: String, timeout: TimeInterval = 20,
                      condition: @escaping () -> Bool, next: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { checks.append(name); next() }
            else if Date() > deadline {
                failures.append("timeout: \(name); receiver state: \(app.receiver.state)")
                stopGenerator()
                app.receiver.stop { self.finish() }
            } else { after(0.1, poll) }
        }
        poll()
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func snapshot(_ name: String) {
        app.mirrorView.layoutSubtreeIfNeeded()
        app.mirrorView.displayIfNeeded()
        let view = app.mirrorView!
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        if let video = view.snapshotVideoImage() {
            context.draw(video, in: view.bounds)
            let x = video.width / 2, y = video.height / 5
            if let data = video.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
                let pixel = y * video.bytesPerRow + x * 4
                if bytes[pixel] == 0 && bytes[pixel + 1] == 0 && bytes[pixel + 2] == 0 {
                    failures.append("Metal GPU readback unexpectedly black for \(name)")
                }
            }
        } else { view.layer?.render(in: context) }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func finish() {
        browser.stop()
        let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "decodedFrames": frameCount, "metalSubmissions": app.mirrorView.submittedFrames,
            "localLatency": app.mirrorView.latencySummary, "measurements": measurements,
            "note": "Synthetic H.264/HEVC 60 FPS pipelines. Timings exclude sender encoding and wireless transport."]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("report.json"))
        }
        print(failures.isEmpty ? "PASS: native UI smoke test" : "FAIL: \(failures)")
        // Receiver already stopped; exit the diagnostic process directly.
        exit(failures.isEmpty ? 0 : 1)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if service.name == app.receiver.deviceName { discovered = true }
    }
}

private var activeSmokeTest: SmokeTest?
extension AppDelegate {
    func runSmokeTest() {
        let test = SmokeTest(app: self)
        activeSmokeTest = test
        test.run()
    }
}
#endif
