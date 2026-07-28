#!/usr/bin/env swift

import AppKit
import Foundation

struct IconVariant {
    let filename: String
    let pixels: Int
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fputs("Usage: render-app-iconset.swift <source.png> <output.iconset>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
guard let image = NSImage(contentsOf: sourceURL) else {
    fputs("Unable to decode icon source at \(sourceURL.path)\n", stderr)
    exit(1)
}

let variants = [
    IconVariant(filename: "icon_16x16.png", pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", pixels: 32),
    IconVariant(filename: "icon_32x32.png", pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", pixels: 64),
    IconVariant(filename: "icon_128x128.png", pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", pixels: 256),
    IconVariant(filename: "icon_256x256.png", pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", pixels: 512),
    IconVariant(filename: "icon_512x512.png", pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", pixels: 1_024),
]

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
for variant in variants {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: variant.pixels,
        pixelsHigh: variant.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fputs("Unable to allocate \(variant.filename)\n", stderr)
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: variant.pixels, height: variant.pixels).fill()
    image.draw(
        in: NSRect(x: 0, y: 0, width: variant.pixels, height: variant.pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = representation.representation(using: .png, properties: [:]) else {
        fputs("Unable to encode \(variant.filename)\n", stderr)
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent(variant.filename), options: .atomic)
}
