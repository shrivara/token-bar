#!/usr/bin/env swift

import AppKit
import Foundation

private let canvas: CGFloat = 1024

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

private func gradient(_ colors: [CGColor], locations: [CGFloat] = [0, 1]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: colors as CFArray,
               locations: locations)!
}

private func renderIcon(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels,
                                     pixelsHigh: pixels,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { throw CocoaError(.fileWriteUnknown) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
    let scale = CGFloat(pixels) / canvas
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tileRect = CGRect(x: 80, y: 80, width: 864, height: 864)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 205, cornerHeight: 205,
                      transform: nil)

    // Soft macOS-style shadow around the rounded app tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -24), blur: 42,
                      color: color(0x020617, alpha: 0.48))
    context.addPath(tile)
    context.setFillColor(color(0x101B35))
    context.fillPath()
    context.restoreGState()

    // Deep indigo tile with cyan and violet ambient glows.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0x101827), color(0x263A73), color(0x34235F)],
                 locations: [0, 0.58, 1]),
        start: CGPoint(x: 145, y: 140), end: CGPoint(x: 890, y: 910), options: [])
    context.drawRadialGradient(
        gradient([color(0x2DD4BF, alpha: 0.34), color(0x2DD4BF, alpha: 0)]),
        startCenter: CGPoint(x: 260, y: 820), startRadius: 0,
        endCenter: CGPoint(x: 260, y: 820), endRadius: 570, options: [])
    context.drawRadialGradient(
        gradient([color(0xA855F7, alpha: 0.22), color(0xA855F7, alpha: 0)]),
        startCenter: CGPoint(x: 850, y: 220), startRadius: 0,
        endCenter: CGPoint(x: 850, y: 220), endRadius: 520, options: [])
    context.restoreGState()

    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.13))
    context.setLineWidth(7)
    context.strokePath()

    // A token ring gives the mark a clear silhouette at small icon sizes.
    let outerToken = CGRect(x: 218, y: 218, width: 588, height: 588)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                      color: color(0x020617, alpha: 0.42))
    context.addEllipse(in: outerToken)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0x99F6E4), color(0x2DD4BF), color(0x38BDF8)]),
        start: CGPoint(x: 280, y: 780), end: CGPoint(x: 760, y: 245), options: [])
    context.restoreGState()

    let innerToken = CGRect(x: 257, y: 257, width: 510, height: 510)
    context.addEllipse(in: innerToken)
    context.setFillColor(color(0x101A34, alpha: 0.94))
    context.fillPath()
    context.addEllipse(in: innerToken.insetBy(dx: 3.5, dy: 3.5))
    context.setStrokeColor(color(0xFFFFFF, alpha: 0.10))
    context.setLineWidth(7)
    context.strokePath()

    // Three rounded usage bars form the Token Bar monogram.
    let bars = [
        CGRect(x: 337, y: 344, width: 82, height: 190),
        CGRect(x: 471, y: 344, width: 82, height: 292),
        CGRect(x: 605, y: 344, width: 82, height: 390),
    ]
    for bar in bars {
        let path = CGPath(roundedRect: bar, cornerWidth: 41, cornerHeight: 41,
                          transform: nil)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -7), blur: 13,
                          color: color(0x020617, alpha: 0.40))
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(
            gradient([color(0xF0FDFA), color(0x99F6E4)]),
            start: CGPoint(x: bar.midX, y: bar.maxY),
            end: CGPoint(x: bar.midX, y: bar.minY), options: [])
        context.restoreGState()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return png
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift OUTPUT.icns\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let manager = FileManager.default
try manager.createDirectory(at: output.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
let iconset = manager.temporaryDirectory
    .appendingPathComponent("TokenBar-\(UUID().uuidString).iconset", isDirectory: true)
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: iconset) }

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, pixels) in variants {
    try renderIcon(pixels: pixels).write(to: iconset.appendingPathComponent(name), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Generated \(output.path)")
