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

private func render(pixels: Int) throws -> Data {
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
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tileRect = CGRect(x: 76, y: 76, width: 872, height: 872)
    let tile = CGPath(roundedRect: tileRect, cornerWidth: 196, cornerHeight: 196,
                      transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 28,
                      color: color(0x70430A, alpha: 0.28))
    context.addPath(tile)
    context.setFillColor(color(0xF2BF3E))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [color(0xFFD45D), color(0xE9A92B)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
                               end: CGPoint(x: tileRect.maxX, y: tileRect.minY),
                               options: [])
    context.restoreGState()

    let text = "tb" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 116, weight: .semibold),
        .foregroundColor: NSColor(cgColor: color(0x5D3B0B, alpha: 0.82))!,
        .kern: -5,
    ]
    text.draw(at: CGPoint(x: 172, y: 154), withAttributes: attributes)

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
    try render(pixels: pixels).write(to: iconset.appendingPathComponent(name), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Generated \(output.path)")
