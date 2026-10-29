// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin

/// A private Unix socket, protected by a 0700 directory and 0600 socket.
/// Socket connections track stream lifetime only. Pixel buffers travel as
/// private IOSurface Mach rights, without copying pixels through the socket.
final class FrameServer: @unchecked Sendable {
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var clients = Set<Int32>()
    private var stopped = false
    private var activeSession: UInt64?
    private var sessions = Set<UInt64>()
    private var disconnectedSessions = Set<UInt64>()
    private var service: mach_port_t = 0
    private let mailbox = FrameMailbox()
    private let directory: URL
    let socketPath: String
    let serviceName = "local.airplayer.frames." + UUID().uuidString
    var onFrame: ((SurfaceFrame?) -> Void)?
    var onStats: ((String) -> Void)?
    var onTransportError: ((String) -> Void)?

    init() throws {
        // macOS sockaddr_un.sun_path is only 104 bytes. Use a short /tmp path.
        directory = URL(fileURLWithPath: "/tmp/ap-\(UUID().uuidString)", isDirectory: true)
        socketPath = directory.appendingPathComponent("video").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw POSIXError(.ENOTSOCK)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: path.map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 4) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd
        service = APCreateFrameService(serviceName)
        guard service != 0 else { stop(); throw POSIXError(.ENOTSUP) }
    }

    func start() {
        let fd = listener
        let servicePort = service
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let self {
                self.lock.lock()
                let done = self.stopped
                self.lock.unlock()
                if done { break }
                var event = APFrameEvent()
                let result = APReceiveFrame(servicePort, &event, 100)
                if result < 0 { break }
                if result == 0 { self.receive(event) }
            }
        }
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            while let self {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                self.lock.lock()
                if self.stopped {
                    self.lock.unlock()
                    Darwin.close(client)
                    break
                }
                self.clients.insert(client)
                self.lock.unlock()
                DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                    self?.watchSession(from: client)
                }
            }
        }
    }

    private func readExactly(_ count: Int, from fd: Int32) -> Data? {
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { buffer -> Bool in
            var offset = 0
            while offset < count {
                let received = Darwin.recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { return false }
                offset += received
            }
            return true
        }
        return success ? data : nil
    }

    private func watchSession(from fd: Int32) {
        var session: UInt64?
        defer {
            lock.lock()
            if let session {
                sessions.remove(session)
                disconnectedSessions.insert(session)
                // Keep this bounded across long-running reconnect sessions.
                if disconnectedSessions.count > 512 { disconnectedSessions = [session] }
            }
            if let session, activeSession == session {
                activeSession = nil
                if !stopped { submit(nil) }
            }
            clients.remove(fd)
            // Close under the same lock as stop() to prevent descriptor reuse races.
            Darwin.close(fd)
            lock.unlock()
        }
        guard let hello = readExactly(16, from: fd) else { return }
        let valid = hello.withUnsafeBytes { bytes in
            UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self)) == 0x32435041 &&
            UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) == 1
        }
        guard valid else { return }
        let id = hello.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        guard id != 0 else { return }
        session = id
        lock.lock()
        sessions.insert(id)
        lock.unlock()
        // Only EOF is expected after the fixed-size control handshake.
        _ = readExactly(1, from: fd)
    }

    private var measuredSession: UInt64 = 0
    private var measuredStart = ProcessInfo.processInfo.systemUptime
    private var receivedCount: UInt64 = 0
    private var lastSize = ""

    private func receive(_ event: APFrameEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, !disconnectedSessions.contains(event.session) else {
            APReleasePort(event.surface_port)
            APReturnFrame(event.reply_port, event.sequence)
            return
        }
        if event.kind == 2 {
            if activeSession == event.session { activeSession = nil; submit(nil) }
            return
        }
        guard let frame = SurfaceFrame(event: event) else { return }
        activeSession = frame.session
        let now = ProcessInfo.processInfo.systemUptime
        let size = "\(frame.width)x\(frame.height)"
        if measuredSession != frame.session || lastSize != size {
            measuredSession = frame.session
            measuredStart = now
            receivedCount = 0
            lastSize = size
            report("VIDEO size=\(size) transport=IOSurface renderer=Metal format=\(frame.isNV12 ? "NV12" : "BGRA")")
        }
        receivedCount += 1
        let elapsed = now - measuredStart
        if elapsed >= 5 {
            report(String(format: "VIDEO size=%@ received_fps=%.1f producer_dropped=%llu ui_superseded=%llu",
                size, Double(receivedCount) / elapsed, frame.producerDropped, mailbox.superseded))
            measuredStart = now
            receivedCount = 0
        }
        submit(frame)
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onStats?(message) }
    }

    private func submit(_ frame: SurfaceFrame?) {
        mailbox.submit(frame) { [weak self] frame in self?.onFrame?(frame) }
    }

    private func transportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onTransportError?(message) }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        mailbox.invalidate()
        APDestroyFrameService(service)
        service = 0
        // Readers own client closes; shutdown wakes a blocking read safely.
        for fd in clients { Darwin.shutdown(fd, SHUT_RDWR) }
        let fd = listener
        listener = -1
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { stop() }
}
