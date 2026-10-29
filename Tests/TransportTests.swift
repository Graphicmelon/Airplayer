// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOSurface
import Darwin

@main struct TransportTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func pump(until condition: () -> Bool, timeout: TimeInterval = 4) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }
    static func hello(_ session: UInt64) -> Data {
        var words: [UInt32] = [0x32435041, 1]
        var id = session.littleEndian
        var data = words.withUnsafeMutableBytes { Data($0) }
        withUnsafeBytes(of: &id) { data.append(contentsOf: $0) }
        return data
    }
    static func sendBytes(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                expect(n > 0, "control socket send succeeds")
                offset += n
            }
        }
    }
    static func connect(_ server: FrameServer, session: UInt64) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) {
            $0.copyBytes(from: Array(server.socketPath.utf8CString).map { UInt8(bitPattern: $0) })
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        expect(result == 0, "private control socket connects")
        let data = hello(session)
        sendBytes(data.prefix(5), to: fd)
        sendBytes(data.dropFirst(5), to: fd)
        return fd
    }
    static func surface(_ width: Int, _ height: Int) -> IOSurfaceRef {
        let properties: [String: Any] = [kIOSurfaceWidth as String: width, kIOSurfaceHeight as String: height,
            kIOSurfaceBytesPerElement as String: 4, kIOSurfacePixelFormat as String: 0x42475241]
        let surface = IOSurfaceCreate(properties as CFDictionary)!
        expect(IOSurfaceLock(surface, [], nil) == 0, "surface is writable")
        let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        memset(bytes, 255, IOSurfaceGetAllocSize(surface))
        bytes[0] = 0; bytes[1] = 0; bytes[2] = 255; bytes[3] = 255
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }
    static func send(_ surface: IOSurfaceRef?, service: mach_port_t, session: UInt64, sequence: UInt64 = 1) {
        let port = surface.map { IOSurfaceCreateMachPort($0) } ?? 0
        expect(APSendFrame(service, port, surface == nil ? 2 : 1, session, sequence, 0) == 0, "Mach frame sent")
        APReleasePort(port)
    }

    static func main() throws {
        expect(ReceiverConfiguration.width == 3840 && ReceiverConfiguration.height == 2160, "default 2160p dimensions")
        expect(ReceiverConfiguration.fps == 60, "fixed 60 FPS")
        expect(ReceiverConfiguration.arguments.contains("3840x2160@60"), "explicit display dimensions")
        expect(ReceiverConfiguration.arguments.contains("airplayerh264sink"), "direct VideoToolbox sink")
        let sync = ReceiverConfiguration.arguments.firstIndex(of: "-vsync")!
        expect(ReceiverConfiguration.arguments[sync + 1] == "no", "timestamp waiting disabled")
        expect(ReceiverConfiguration.arguments.contains("-h265"), "HEVC enabled with H264 fallback")
        let server = try FrameServer()
        var received = [SurfaceFrame?]()
        server.onFrame = { received.append($0) }
        server.start()
        let service = APLookupFrameService(server.serviceName)
        expect(service != 0, "private Mach endpoint resolves")
        let first = connect(server, session: 101)
        let landscape = surface(2, 1)
        send(landscape, service: service, session: 101)
        expect(pump { received.last.flatMap { $0 }?.width == 2 }, "shared landscape frame arrives")
        expect(IOSurfaceIsInUse(landscape), "frame right prevents producer reuse")
        if let frame = received.last.flatMap({ $0 }) {
            expect(IOSurfaceGetID(frame.surface) == IOSurfaceGetID(landscape), "same IOSurface across transport")
            IOSurfaceLock(frame.surface, .readOnly, nil)
            let pixels = IOSurfaceGetBaseAddress(frame.surface).assumingMemoryBound(to: UInt8.self)
            expect(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 255, "BGRA pixel channels preserved")
            IOSurfaceUnlock(frame.surface, .readOnly, nil)
        }
        let portrait = surface(1, 2)
        send(portrait, service: service, session: 101, sequence: 2)
        expect(pump { received.last.flatMap { $0 }?.height == 2 }, "rotation changes dimensions")
        let second = connect(server, session: 102)
        let replacement = surface(3, 1)
        send(replacement, service: service, session: 102)
        expect(pump { received.last.flatMap { $0 }?.width == 3 }, "new renderer takes over")
        let beforeClose = received.count
        Darwin.close(first)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        expect(received.count == beforeClose, "old renderer EOF cannot clear new video")
        send(nil, service: service, session: 102)
        expect(pump { received.count > beforeClose && received.last! == nil }, "clear event resets video")
        Darwin.close(second)
        let third = connect(server, session: 103)
        send(landscape, service: service, session: 103)
        expect(pump { received.last.flatMap { $0 }?.width == 2 }, "reconnection succeeds")
        Darwin.close(third)
        expect(pump { received.last! == nil }, "abrupt sender EOF clears frame")
        let countAfterEOF = received.count
        send(landscape, service: service, session: 103)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        expect(received.count == countAfterEOF, "late frame from disconnected session ignored")
        received.removeAll()
        expect(pump { !IOSurfaceIsInUse(landscape) }, "shared surface released when consumers finish")

        let mailbox = FrameMailbox()
        var deliveries = 0
        for _ in 0..<1000 { mailbox.submit(nil) { _ in deliveries += 1 } }
        expect(pump { deliveries == 1 }, "mailbox coalesces slow UI updates")
        mailbox.submit(nil) { _ in deliveries += 1 }
        mailbox.invalidate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        expect(deliveries == 1, "shutdown cancels pending UI callback")
        let leased = connect(server, session: 105)
        let replies = APCreateFrameReplies()
        expect(replies != 0, "frame-lease reply port created")
        let pixelPort = IOSurfaceCreateMachPort(landscape)
        expect(APSendFrameLeased(service, pixelPort, replies, 105, 42, 0, 1, 2, 2, 1, 1) == 0, "leased frame sent")
        APReleasePort(pixelPort)
        expect(pump { received.last.flatMap { $0 }?.sequence == 42 }, "leased frame delivered")
        var returned: UInt64 = 0
        expect(!APReceiveFrameReply(replies, &returned), "producer lease retained while consumer holds frame")
        received.removeAll()
        var didReturn = false
        expect(pump {
            if !didReturn { didReturn = APReceiveFrameReply(replies, &returned) }
            return didReturn
        }, "consumer destruction returns the buffer lease")
        expect(returned == 42, "lease return matches frame sequence")
        Darwin.close(leased)
        _ = mach_port_mod_refs(mach_task_self_, replies, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
        let idle = connect(server, session: 104)
        let path = server.socketPath
        server.stop()
        server.stop()
        expect(!FileManager.default.fileExists(atPath: path), "private socket cleaned up")
        Darwin.close(idle)
        APReleasePort(service)
        print("PASS: \(assertions) assertions (fixed configuration, IOSurface ownership, pixels, rotation, session isolation, EOF, backpressure, shutdown).")
    }
}
