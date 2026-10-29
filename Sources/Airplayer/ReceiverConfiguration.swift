// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum ReceiverConfiguration {
    // Keep the user-validated 2160p HEVC profile; allow explicit lower-resolution comparisons.
    static let height: Int = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--resolution"), index + 1 < args.count,
              let value = Int(args[index + 1]), [1080, 1440, 2160].contains(value) else { return 2160 }
        return value
    }()
    static var width: Int { height * 16 / 9 }
    static let fps = 60
    static var arguments: [String] {
        ["-vs", "airplayerh264sink", "-as", "osxaudiosink",
         "-vsync", "no", "-nc", "no", "-nofreeze",
         "-s", "\(width)x\(height)@60", "-fps", "60", "-FPSdata"] +
        (height > 1080 ? ["-h265"] : [])
    }
}
