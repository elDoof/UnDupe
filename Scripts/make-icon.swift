#!/usr/bin/env swift
//
// Renders UnDupe's app icon with CoreGraphics and emits a full .iconset, then
// hands off to `iconutil` to produce Resources/UnDupe.icns.
//
// The mark is a two-ring radial "sunburst" — the same motif the app draws for
// disk maps — over a dark squircle with a cool blue→violet→magenta sweep.
//
// Usage:  swift Scripts/make-icon.swift            (writes Resources/UnDupe.icns)
//
import AppKit
import CoreGraphics

// MARK: - Geometry helpers

/// Apple's icon grid: the rounded body is inset from the tile, and its corner
/// radius is ~0.2245 of the body side (the "squircle" look).
private let bodyInsetRatio: CGFloat = 0.0977
private let cornerRatio: CGFloat = 0.2245

private func bodyRect(in size: CGFloat) -> CGRect {
    let inset = (size * bodyInsetRatio).rounded()
    return CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
}

// MARK: - Drawing

/// Draws the full icon into `ctx` for a square canvas of `size` pixels.
private func drawIcon(in ctx: CGContext, size: CGFloat) {
    let body = bodyRect(in: size)
    let radius = body.width * cornerRatio
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow grounding the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip everything that follows to the squircle.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    drawBackground(in: ctx, body: body)
    drawCenterGlow(in: ctx, body: body)
    drawSunburst(in: ctx, body: body)

    ctx.restoreGState()

    drawRim(in: ctx, squircle: squircle, size: size)
}

/// Vertical gradient backdrop matching the app's window colors.
private func drawBackground(in ctx: CGContext, body: CGRect) {
    let top = NSColor(srgbRed: 0.16, green: 0.19, blue: 0.30, alpha: 1).cgColor
    let bottom = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) else { return }
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY),
                           options: [])
}

/// Accent bloom behind the sunburst so the rings feel lit from within.
private func drawCenterGlow(in ctx: CGContext, body: CGRect) {
    let center = CGPoint(x: body.midX, y: body.midY)
    let inner = NSColor(srgbRed: 0.36, green: 0.78, blue: 1.0, alpha: 0.45).cgColor
    let outer = NSColor(srgbRed: 0.36, green: 0.78, blue: 1.0, alpha: 0.0).cgColor
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(colorsSpace: space, colors: [inner, outer] as CFArray, locations: [0, 1]) else { return }
    ctx.drawRadialGradient(gradient,
                           startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: body.width * 0.46,
                           options: [])
}

/// The two-ring sunburst. Hue sweeps cyan→blue→violet→magenta around the dial so
/// the mark reads as cohesive rather than a full rainbow.
private func drawSunburst(in ctx: CGContext, body: CGRect) {
    let center = CGPoint(x: body.midX, y: body.midY)
    let unit = body.width

    // Inner ring: bold wedges.
    drawRing(in: ctx, center: center,
             innerRadius: unit * 0.155, outerRadius: unit * 0.300,
             segments: 12, gapFraction: 0.10, brightness: 0.98, alpha: 1.0)

    // Outer ring: thinner, alternating-length wedges for the "fanned map" look.
    drawRing(in: ctx, center: center,
             innerRadius: unit * 0.320, outerRadius: unit * 0.395,
             segments: 24, gapFraction: 0.18, brightness: 0.92, alpha: 0.95,
             alternating: true)

    // Dark hub with a thin accent rim — the focal point of the dial.
    let hubR = unit * 0.118
    ctx.addArc(center: center, radius: hubR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setFillColor(NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.addArc(center: center, radius: hubR, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.setStrokeColor(NSColor(srgbRed: 0.36, green: 0.78, blue: 1.0, alpha: 0.9).cgColor)
    ctx.setLineWidth(unit * 0.012)
    ctx.strokePath()
}

private func hue(forSegment i: Int, of total: Int) -> CGFloat {
    // Sweep across the cool half of the wheel: cyan(0.50) → magenta(0.92).
    let t = CGFloat(i) / CGFloat(total)
    return 0.50 + t * 0.42
}

/// Fills `segments` annular wedges between the two radii, leaving angular gaps.
private func drawRing(in ctx: CGContext, center: CGPoint,
                      innerRadius: CGFloat, outerRadius: CGFloat,
                      segments: Int, gapFraction: CGFloat,
                      brightness: CGFloat, alpha: CGFloat,
                      alternating: Bool = false) {
    let step = (CGFloat.pi * 2) / CGFloat(segments)
    let gap = step * gapFraction
    let start = -CGFloat.pi / 2          // first wedge points up

    for i in 0..<segments {
        let a0 = start + CGFloat(i) * step + gap / 2
        let a1 = start + CGFloat(i) * step + step - gap / 2
        let outer = alternating && i % 2 == 1 ? innerRadius + (outerRadius - innerRadius) * 0.55 : outerRadius

        let path = CGMutablePath()
        path.addArc(center: center, radius: innerRadius, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: outer, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()

        let h = hue(forSegment: i, of: segments)
        let color = NSColor(hue: h, saturation: 0.68, brightness: brightness, alpha: alpha)
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
}

/// Crisp outer hairline on the squircle edge.
private func drawRim(in ctx: CGContext, squircle: CGPath, size: CGFloat) {
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(size * 0.004)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Rasterization

private func renderPNG(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Main

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? FileManager.default.currentDirectoryPath)

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("UnDupe.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// (pixel size, filename) for every entry iconutil expects.
let entries: [(Int, String)] = [
    (16, "icon_16x16.png"),     (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),     (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),  (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),  (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),  (1024, "icon_512x512@2x.png"),
]

for (px, name) in entries {
    let data = renderPNG(size: px)
    try data.write(to: iconset.appendingPathComponent(name))
}

let icnsPath = root.appendingPathComponent("Resources/UnDupe.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icnsPath.path]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)

if task.terminationStatus == 0 {
    print("✓ Wrote \(icnsPath.path)")
} else {
    FileHandle.standardError.write("✗ iconutil failed (\(task.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
