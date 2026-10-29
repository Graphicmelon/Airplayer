// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
let outline = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 204, yRadius: 204)
NSGradient(starting: NSColor(red: 0.16, green: 0.23, blue: 0.36, alpha: 1),
    ending: NSColor(red: 0.055, green: 0.075, blue: 0.12, alpha: 1))!.draw(in: outline, angle: -90)
NSColor(white: 1, alpha: 0.12).setStroke()
outline.lineWidth = 3
outline.stroke()
let symbol = NSImage(systemSymbolName: "airplay.video", accessibilityDescription: nil)!
    .withSymbolConfiguration(.init(pointSize: 500, weight: .light))!
    .withSymbolConfiguration(.init(paletteColors: [NSColor(red: 0.77, green: 0.85, blue: 1, alpha: 1)]))!
symbol.draw(in: NSRect(x: 242, y: 287, width: 540, height: 450))
NSGraphicsContext.restoreGraphicsState()
let source = context.makeImage()!
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        let small = NSGraphicsContext(bitmapImageRep: image)!
        small.cgContext.interpolationQuality = .high
        small.cgContext.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
