import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("Usage: swift make_icon.swift <official-favicon.svg> <output-1024.png> black|blue\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let style = CommandLine.arguments[3]
guard style == "black" || style == "blue" else {
    fputs("Style must be 'black' or 'blue'\n", stderr)
    exit(2)
}
let isBlue = style == "blue"

let source = try String(contentsOf: sourceURL, encoding: .utf8)

// Strip the dark-mode <style>; the whale path then falls back to its
// light-mode (default black) fill.
var markSource = source.replacingOccurrences(
    of: #"\s*<style>[\s\S]*?</style>\s*"#,
    with: "",
    options: .regularExpression
)
if isBlue {
    // Blue whale variant: recolor the mark to DeepSeek blue (#4D6BFE) on the
    // same white plate as the black icon. The color is applied through a style
    // attribute because NSImage's SVG renderer rejects a plain fill="#…"
    // attribute on the whale path.
    markSource = markSource.replacingOccurrences(
        of: #"<path id="path""#,
        with: #"<path id="path" style="fill:#4D6BFE""#
    )
}

guard let svgData = markSource.data(using: .utf8),
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

// Same white plate geometry for both styles (matches the existing black
// icon): rounded square inset 64pt with 196pt corner radius.
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
