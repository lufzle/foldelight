// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

// Static vector artwork, rendered at each native macOS icon resolution.
// The three planes use the same coordinates and palette as the in-app FoldMark.
let output = CommandLine.arguments.dropFirst().first ?? "dist/foldelight.iconset"
let directory = URL(fileURLWithPath: output, isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let cyan = NSColor(srgbRed: 0.48, green: 0.75, blue: 0.77, alpha: 1)
let pink = NSColor(srgbRed: 0.78, green: 0.52, blue: 0.65, alpha: 1)
let gold = NSColor(srgbRed: 0.79, green: 0.67, blue: 0.43, alpha: 1)
let planes: [([(CGFloat, CGFloat)], NSColor)] = [
    ([(2, 7), (18, 12), (17, 35), (2, 29)], cyan),
    ([(18, 12), (34, 3), (32, 26), (17, 35)], pink),
    ([(17, 35), (32, 26), (42, 32), (27, 41)], gold)
]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let cg = graphics.cgContext
        cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let base = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 190, yRadius: 190)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1).setFill()
        base.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(srgbRed: 0.21, green: 0.22, blue: 0.24, alpha: 1),
                   ending: NSColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1))!.draw(in: base, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        base.addClip()
        // Deterministic, faint grain avoids a flat digital surface.
        NSColor.white.withAlphaComponent(0.028).setFill()
        for index in 0..<3000 {
            let x = CGFloat((index * 719 + 137) % 1024)
            let y = CGFloat((index * 389 + 271) % 1024)
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.085).setStroke()
        base.lineWidth = 2
        base.stroke()
        for (vertices, color) in planes {
            let path = NSBezierPath()
            for (index, vertex) in vertices.enumerated() {
                let point = NSPoint(x: 512 + (vertex.0 - 22) * 14, y: 512 - (vertex.1 - 22) * 14)
                if index == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close()
            color.setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }
}
print(directory.path)
