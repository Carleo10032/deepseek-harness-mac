import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: swift make_icon.swift <official-favicon.svg> <output-1024.png>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let source = try String(contentsOf: sourceURL, encoding: .utf8)
let blackOnlySource = source.replacingOccurrences(
    of: #"\s*<style>[\s\S]*?</style>\s*"#,
    with: "",
    options: .regularExpression
)

guard let svgData = blackOnlySource.data(using: .utf8),
      let logo = NSImage(data: svgData)
else {
    fputs("Unable to load the official SVG\n", stderr)
    exit(1)
}

let pixelSize = 1024
let size = NSSize(width: pixelSize, height: pixelSize)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create bitmap context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill(using: .copy)

let backgroundRect = NSRect(x: 64, y: 64, width: 896, height: 896)
NSColor.white.setFill()
NSBezierPath(roundedRect: backgroundRect, xRadius: 196, yRadius: 196).fill()

let markSize: CGFloat = 620
let markRect = NSRect(
    x: (size.width - markSize) / 2,
    y: (size.height - markSize) / 2,
    width: markSize,
    height: markSize
)
logo.draw(in: markRect, from: .zero, operation: .sourceOver, fraction: 1)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Unable to render PNG\n", stderr)
    exit(1)
}

try png.write(to: outputURL, options: .atomic)
