#!/usr/bin/env swift
// Generates the Vibe Island app icon iconset (dist/icon.iconset) by drawing
// offscreen with AppKit/CoreGraphics. Run: swift scripts/make-icon.swift
import AppKit

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
        green: CGFloat((hex >> 8) & 0xFF) / 255.0,
        blue: CGFloat(hex & 0xFF) / 255.0,
        alpha: alpha
    )
}

/// Draws the icon into the current graphics context at `size` px.
/// All geometry is defined on a 1024pt canvas and scaled.
func drawIcon(size: CGFloat) {
    let s = size / 1024.0

    // Rounded-square background, inset like modern macOS icons.
    let inset: CGFloat = 64 * s
    let bgRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 230 * s, yRadius: 230 * s)
    let gradient = NSGradient(starting: color(0x1c1c22), ending: color(0x111114))!
    gradient.draw(in: bgPath, angle: -90) // subtle vertical gradient, lighter at top

    // Island pill, centered horizontally near the top third.
    // (AppKit's origin is bottom-left, so "top third" means high y.)
    let pillW: CGFloat = 460 * s, pillH: CGFloat = 120 * s
    let pillX = (size - pillW) / 2
    let pillY = size - 270 * s - pillH // pill top ~270pt from icon top
    let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
    color(0xF5F5F7, alpha: 0.92).setFill()
    NSBezierPath(roundedRect: pillRect, xRadius: 60 * s, yRadius: 60 * s).fill()

    // Gradient dot on the pill's right portion.
    let dotD: CGFloat = 56 * s
    let dotRect = CGRect(
        x: pillRect.maxX - dotD - 44 * s,
        y: pillRect.midY - dotD / 2,
        width: dotD, height: dotD
    )
    let dotGradient = NSGradient(starting: color(0xFF7A3D), ending: color(0xA06BFF))!
    dotGradient.draw(in: NSBezierPath(ovalIn: dotRect), angle: 45)

    // Three thin rounded bars below the pill — a subtle "session list" motif.
    let barH: CGFloat = 44 * s
    let spacing: CGFloat = 36 * s
    let widths: [CGFloat] = [460, 380, 300]
    color(0x2A2A32).setFill()
    var y = pillY - 80 * s - barH
    for w in widths {
        let bw = w * s
        let rect = CGRect(x: (size - bw) / 2, y: y, width: bw, height: barH)
        NSBezierPath(roundedRect: rect, xRadius: barH / 2, yRadius: barH / 2).fill()
        y -= barH + spacing
    }
}

func renderPNG(px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    drawIcon(size: CGFloat(px))
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let outDir = URL(fileURLWithPath: "dist/icon.iconset")
try! fm.createDirectory(at: outDir, withIntermediateDirectories: true)

// iconutil naming: base size + @2x pairs.
let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

var cache: [Int: Data] = [:]
for (name, px) in entries {
    let data = cache[px] ?? renderPNG(px: px)
    cache[px] = data
    try! data.write(to: outDir.appendingPathComponent(name))
}
print("Wrote \(entries.count) PNGs to \(outDir.path)")
