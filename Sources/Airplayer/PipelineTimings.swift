// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Local, same-machine timestamps only. These do not measure network, sender
/// encoding or touch-to-photon latency and are deliberately labelled as such.
final class PipelineTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var decode = [Double](), ipc = [Double](), display = [Double]()
    private var presentationWait = [Double]()
    private var lastSummary = ""
    private var stream: UInt64 = 0
    private var width = 0, height = 0
    var summary: String { lock.lock(); defer { lock.unlock() }; return lastSummary }

    func record(frame: SurfaceFrame, presentedNS: UInt64) -> String? {
        guard frame.inputNS > 0, frame.decodedNS >= frame.inputNS,
              frame.receivedNS >= frame.decodedNS, presentedNS >= frame.receivedNS,
              presentedNS - frame.inputNS < 5_000_000_000 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if stream != frame.session || width != frame.width || height != frame.height {
            stream = frame.session; width = frame.width; height = frame.height
            decode.removeAll(keepingCapacity: true); ipc.removeAll(keepingCapacity: true); display.removeAll(keepingCapacity: true)
            presentationWait.removeAll(keepingCapacity: true)
            lastSummary = ""
        }
        decode.append(Double(frame.decodedNS - frame.inputNS) / 1_000_000)
        ipc.append(Double(frame.receivedNS - frame.decodedNS) / 1_000_000)
        display.append(Double(presentedNS - frame.inputNS) / 1_000_000)
        presentationWait.append(Double(presentedNS - frame.receivedNS) / 1_000_000)
        guard display.count >= 120 else { return nil }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let p95 = display.sorted()[min(display.count - 1, Int(Double(display.count) * 0.95))]
        lastSummary = String(format: "LOCAL_LATENCY decode_p50_ms=%.2f ipc_p50_ms=%.2f decode_input_to_present_p50_ms=%.2f p95_ms=%.2f received_to_present_p50_ms=%.2f samples=%d",
            median(decode), median(ipc), median(display), p95, median(presentationWait), display.count)
        decode.removeAll(keepingCapacity: true); ipc.removeAll(keepingCapacity: true); display.removeAll(keepingCapacity: true)
        presentationWait.removeAll(keepingCapacity: true)
        return lastSummary
    }
}
