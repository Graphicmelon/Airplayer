// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import IOSurface

/// The send right keeps this surface marked in-use in the producer until every
/// UI/GPU reference to the frame has gone away. The producer cannot overwrite it.
final class SurfaceFrame: @unchecked Sendable {
    let surface: IOSurfaceRef
    let session: UInt64
    let sequence: UInt64
    let producerDropped: UInt64
    let inputNS: UInt64
    let decodedNS: UInt64
    let colorInfo: UInt32
    let receivedNS = APMonotonicTimeNS()
    let width: Int
    let height: Int
    var isNV12: Bool { IOSurfaceGetPlaneCount(surface) == 2 }
    var isFullRange: Bool { IOSurfaceGetPixelFormat(surface) == 0x34323066 }
    private let port: mach_port_t
    private let replyPort: mach_port_t

    init?(event: APFrameEvent) {
        guard event.surface_port != 0 else { return nil }
        guard let surface = IOSurfaceLookupFromMachPort(event.surface_port),
              (1...8192).contains(IOSurfaceGetWidth(surface)),
              (1...8192).contains(IOSurfaceGetHeight(surface)),
              Self.validFormat(surface),
              (event.width == 0 || Int(event.width) <= IOSurfaceGetWidth(surface)),
              (event.height == 0 || Int(event.height) <= IOSurfaceGetHeight(surface)) else {
            APReleasePort(event.surface_port)
            APReturnFrame(event.reply_port, event.sequence)
            return nil
        }
        self.surface = surface
        port = event.surface_port
        replyPort = event.reply_port
        session = event.session
        sequence = event.sequence
        producerDropped = event.dropped
        inputNS = event.input_ns
        decodedNS = event.decoded_ns
        colorInfo = event.color_info
        width = event.width == 0 ? IOSurfaceGetWidth(surface) : Int(event.width)
        height = event.height == 0 ? IOSurfaceGetHeight(surface) : Int(event.height)
    }

    private static func validFormat(_ surface: IOSurfaceRef) -> Bool {
        if IOSurfaceGetPixelFormat(surface) == 0x42475241 {
            return IOSurfaceGetBytesPerRow(surface) >= IOSurfaceGetWidth(surface) * 4
        }
        return [UInt32(0x34323076), UInt32(0x34323066)].contains(IOSurfaceGetPixelFormat(surface)) &&
            IOSurfaceGetPlaneCount(surface) == 2 &&
            IOSurfaceGetWidthOfPlane(surface, 0) >= IOSurfaceGetWidth(surface) &&
            IOSurfaceGetHeightOfPlane(surface, 0) >= IOSurfaceGetHeight(surface) &&
            IOSurfaceGetWidthOfPlane(surface, 1) >= (IOSurfaceGetWidth(surface) + 1) / 2 &&
            IOSurfaceGetHeightOfPlane(surface, 1) >= (IOSurfaceGetHeight(surface) + 1) / 2
    }

    deinit {
        APReleasePort(port)
        APReturnFrame(replyPort, sequence)
    }

}

final class FrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: SurfaceFrame?
    private var pending = false
    private var generation: UInt64 = 0
    private var supersededCount: UInt64 = 0
    var superseded: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return supersededCount
    }

    func submit(_ frame: SurfaceFrame?, deliver: @escaping (SurfaceFrame?) -> Void) {
        lock.lock()
        if pending, self.frame != nil { supersededCount &+= 1 }
        self.frame = frame
        let needsDelivery = !pending
        pending = true
        let token = generation
        lock.unlock()
        guard needsDelivery else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard token == self.generation else { self.lock.unlock(); return }
            let newest = self.frame
            self.frame = nil
            self.pending = false
            self.lock.unlock()
            deliver(newest)
        }
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        pending = false
        frame = nil
        lock.unlock()
    }
}
