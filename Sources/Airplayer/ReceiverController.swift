// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

enum ReceiverState: Equatable {
    case starting
    case ready
    case mirroring
    case failed(String)
}

/// Owns the receiver for exactly one application lifetime. All UI callbacks run
/// on the main queue. UxPlay owns protocol, Bonjour and audio output. VideoToolbox decodes video.
final class ReceiverController {
    let deviceName: String
    private let deviceID: String
    private(set) var state: ReceiverState = .starting
    var onState: ((ReceiverState) -> Void)?
    var onFrame: ((SurfaceFrame?) -> Void)?
    private(set) var process: Process?
    private(set) var frameServer: FrameServer?
    private var output: Pipe?
    private var startupTimeout: DispatchWorkItem?
    private var logRemainder = Data()
    private var recentLog = ""
    private var stopping = false
    private var shutdownCompletions = [() -> Void]()
    private var logFile: FileHandle?
    private var runID = UUID()

    init() {
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
        // Bonjour instance names are limited to 63 UTF-8 bytes.
        var name = "Airplayer · \(host)"
        #if AIRPLAYER_DIAGNOSTICS
        let diagnosing = CommandLine.arguments.contains("--smoke-test")
        if diagnosing { name = "Airplayer Test · \(UUID().uuidString.prefix(8))" }
        #endif
        while name.utf8.count > 63 { name.removeLast() }
        deviceName = name
        // A stable, app-specific ID avoids colliding with macOS's own receiver
        // or relying on MAC addresses redacted by newer macOS versions.
        let defaults = UserDefaults.standard
        #if AIRPLAYER_DIAGNOSTICS
        if diagnosing {
            let bytes = withUnsafeBytes(of: UUID().uuid) { Array($0.prefix(5)) }
            deviceID = "02:" + bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            return
        }
        #endif
        if let saved = defaults.string(forKey: "ReceiverDeviceID"),
           saved.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil {
            deviceID = saved
        } else {
            let uuid = UUID().uuid
            var bytes = withUnsafeBytes(of: uuid) { Array($0.prefix(6)) }
            bytes[0] = (bytes[0] & 0xfc) | 0x02
            deviceID = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            defaults.set(deviceID, forKey: "ReceiverDeviceID")
        }
    }

    func start() {
        precondition(Thread.isMainThread)
        guard process == nil, !stopping else { return }
        let runID = UUID()
        self.runID = runID
        guard let resources = Bundle.main.resourceURL else {
            setState(.failed("应用资源缺失，请重新构建 Airplayer。")); return
        }
        let executable = resources.appendingPathComponent("Runtime/bin/uxplay")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            setState(.failed("未找到投屏接收组件，请重新构建 Airplayer。")); return
        }
        do {
            let server = try FrameServer()
            frameServer = server
            server.onFrame = { [weak self] frame in
                guard let self, !self.stopping else { return }
                self.onFrame?(frame)
                if frame != nil { self.setState(.mirroring) }
                else if self.state == .mirroring { self.setState(.ready) }
            }
            server.onTransportError = { [weak self] message in
                guard let self, !self.stopping else { return }
                self.onFrame?(nil)
                self.setState(.failed(message))
            }
            server.start()
            openLog()
            server.onStats = { [weak self] message in self?.writeDiagnostic(message) }
            writeDiagnostic("REQUEST size=\(ReceiverConfiguration.width)x\(ReceiverConfiguration.height) max_fps=60 codec=\(ReceiverConfiguration.height > 1080 ? "H264+HEVC" : "H264") decoder=VideoToolbox-immediate timestamp_sync=false display_clock=true display_sync=true transaction_present=true")
            let child = Process()
            child.executableURL = executable
            child.arguments = ["-n", deviceName, "-nh", "-m", deviceID, "-rc", "/dev/null"] + ReceiverConfiguration.arguments
            child.environment = try runtimeEnvironment(resources: resources, socketPath: server.socketPath)
            child.currentDirectoryURL = resources
            let pipe = Pipe()
            output = pipe
            child.standardOutput = pipe
            child.standardError = pipe
            child.standardInput = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                guard !bytes.isEmpty else { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async {
                    guard let self, self.runID == runID else { return }
                    self.consumeLog(bytes)
                }
            }
            child.terminationHandler = { [weak self] child in
                DispatchQueue.main.async {
                    guard let self, self.runID == runID else { return }
                    self.didExit(status: child.terminationStatus)
                }
            }
            process = child
            setState(.starting)
            try child.run()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.runID == runID, self.state == .starting, !self.stopping else { return }
                self.setState(.failed("接收器启动超时。请检查系统的本地网络权限，然后重新打开 Airplayer。"))
                if let child = self.process, child.isRunning { self.terminate(child) }
            }
            startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        } catch {
            output?.fileHandleForReading.readabilityHandler = nil
            process = nil
            frameServer?.stop()
            frameServer = nil
            setState(.failed("无法启动接收器：\(error.localizedDescription)"))
        }
    }

    func runtimeEnvironment(resources: URL, socketPath: String) throws -> [String: String] {
        let runtime = resources.appendingPathComponent("Runtime")
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("local.airplayer.mac", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        // Isolate from any user GStreamer/UxPlay setup, including stale registries.
        for key in Array(env.keys) where key.hasPrefix("GST_") || key.hasPrefix("DYLD_") { env.removeValue(forKey: key) }
        env["AIRPLAYER_FRAME_SOCKET"] = socketPath
        env["AIRPLAYER_FRAME_SERVICE"] = frameServer?.serviceName
        env["AIRPLAYER_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        env["GST_PLUGIN_PATH_1_0"] = runtime.appendingPathComponent("plugins").path
        env["GST_PLUGIN_SYSTEM_PATH_1_0"] = ""
        env["GST_PLUGIN_SCANNER_1_0"] = runtime.appendingPathComponent("bin/gst-plugin-scanner").path
        env["GST_REGISTRY_1_0"] = cache.appendingPathComponent("registry-\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1").bin").path
        env["UXPLAYRC"] = "/dev/null"
        return env
    }

    private func openLog() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        let directory = library.appendingPathComponent("Logs/Airplayer", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("receiver.log")
            try Data().write(to: url, options: .atomic)
            logFile = try FileHandle(forWritingTo: url)
        } catch { /* Diagnostics must never prevent mirroring. */ }
    }

    private func consumeLog(_ data: Data) {
        try? logFile?.write(contentsOf: data)
        logRemainder.append(data)
        while let end = logRemainder.firstIndex(of: 10) {
            let line = String(decoding: logRemainder[..<end], as: UTF8.self)
            logRemainder.removeSubrange(...end)
            recentLog = String((recentLog + line + "\n").suffix(6000))
            if line == "AIRPLAYER_READY" && state == .starting && !stopping {
                startupTimeout?.cancel()
                setState(.ready)
            }
        }
        if logRemainder.count > 64 * 1024 { logRemainder.removeAll(keepingCapacity: true) }
    }

    func writeDiagnostic(_ message: String) {
        try? logFile?.write(contentsOf: Data((message + "\n").utf8))
    }

    private func didExit(status: Int32) {
        startupTimeout?.cancel()
        output?.fileHandleForReading.readabilityHandler = nil
        // Drain the final pipe bytes before using diagnostics from a failed launch.
        if let bytes = try? output?.fileHandleForReading.readToEnd(), !bytes.isEmpty { consumeLog(bytes) }
        output = nil
        frameServer?.stop()
        frameServer = nil
        process = nil
        try? logFile?.close()
        logFile = nil
        onFrame?(nil)
        if stopping {
            finishStop()
        } else {
            if case .failed = state { return }
            let message: String
            if recentLog.contains("dnssd_register") || recentLog.contains("DNSServiceRegister") {
                message = "无法广播投屏服务。请允许 Airplayer 访问本地网络，然后重新打开应用。"
            } else {
                message = "投屏接收器已停止（\(status)）。请重新打开 Airplayer。"
            }
            setState(.failed(message))
        }
    }

    private func setState(_ newState: ReceiverState) {
        guard state != newState else { return }
        state = newState
        onState?(newState)
    }

    func stop(completion: @escaping () -> Void) {
        precondition(Thread.isMainThread)
        beginStop(completion: completion)
    }

    private func finishStop() {
        let completions = shutdownCompletions
        shutdownCompletions.removeAll()
        completions.forEach { $0() }
    }

    private func beginStop(completion: @escaping () -> Void) {
        shutdownCompletions.append(completion)
        guard !stopping else { return }
        stopping = true
        startupTimeout?.cancel()
        frameServer?.stop()
        guard let child = process else { finishStop(); return }
        if child.isRunning { terminate(child) }
    }

    private func terminate(_ child: Process) {
        child.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak child] in
            if let child, child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
    }
}
