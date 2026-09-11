// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only

/// One pointer gesture, measured in the preview's stationary hit region.
struct PreviewLidDrag {
    static let angleRange = 0.0...132.0
    private(set) var angle: Double
    private var previousTranslation = 0.0

    init(angle: Double) { self.angle = Self.clamped(angle) }

    static func clamped(_ angle: Double) -> Double {
        guard angle.isFinite else { return angleRange.upperBound }
        return min(angleRange.upperBound, max(angleRange.lowerBound, angle))
    }

    /// In SwiftUI's +X rotation, a negative angle brings the top edge toward
    /// the viewer. A closed lid is horizontal; 90 degrees is upright.
    static func hingeRotation(angle: Double) -> Double { clamped(angle) - 90 }

    @discardableResult
    mutating func update(translation: Double, travel: Double) -> Double {
        guard translation.isFinite, travel.isFinite, travel > 0 else { return angle }
        let delta = translation - previousTranslation
        previousTranslation = translation
        // Rebase even at a limit: reversing the pointer must immediately move
        // the lid, without first undoing any distance dragged past the limit.
        angle = Self.clamped(angle - delta * (Self.angleRange.upperBound / travel))
        return angle
    }

    @discardableResult
    mutating func adjust(by degrees: Double) -> Double {
        guard degrees.isFinite else { return angle }
        // Keyboard adjustments during a drag retain its pointer baseline.
        angle = Self.clamped(angle + degrees)
        return angle
    }
}
