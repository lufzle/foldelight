// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit

/// Two connected paper planes. Template rendering follows the menu bar's appearance.
enum FoldingIcon {
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: 2, y: 5))
            outline.line(to: NSPoint(x: 2, y: 13.5))
            outline.line(to: NSPoint(x: 8.5, y: 10.5))
            outline.line(to: NSPoint(x: 16, y: 14.5))
            outline.line(to: NSPoint(x: 16, y: 6))
            outline.line(to: NSPoint(x: 8.5, y: 2))
            outline.close()
            outline.lineWidth = 1.25
            outline.lineJoinStyle = .round
            NSColor.labelColor.setStroke()
            outline.stroke()

            let crease = NSBezierPath()
            crease.move(to: NSPoint(x: 8.5, y: 2.5))
            crease.line(to: NSPoint(x: 8.5, y: 10.5))
            crease.lineWidth = 1.15
            crease.lineCapStyle = .round
            crease.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "foldelight"
        return image
    }
}
