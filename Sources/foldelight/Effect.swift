// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct EffectSettings: Codable, Equatable {
    static let maximumTiltDegrees = 68.0
    static let defaultClearAngle = 90.0
    static let defaultBlur = 0.9
    static let defaultVignette = 0.5
    static let clearAngleRange = 45.0...132.0
    var blur: Double = Self.defaultBlur
    var shadow: Double = Self.defaultVignette
    var clearAngle: Double = Self.defaultClearAngle

    static func progress(angle: Double, clearAngle: Double) -> Double {
        guard angle.isFinite, clearAngle.isFinite, clearAngle > 0 else { return 0 }
        let linear = min(1, max(0, 1 - angle / clearAngle))
        return linear * linear * (3 - 2 * linear)
    }

    /// Rotation from the reference open plane, independent of eased effect strength.
    /// Stop before the assumed viewer becomes coplanar with the moving glass.
    static func tiltRadians(angle: Double, clearAngle: Double) -> Double {
        guard angle.isFinite, clearAngle.isFinite, clearAngle > 0 else { return 0 }
        return min(maximumTiltDegrees, max(0, clearAngle - angle)) * .pi / 180
    }

    mutating func sanitize() {
        blur = Self.clamp(blur, 0...1, fallback: Self.defaultBlur)
        shadow = Self.clamp(shadow, 0...1, fallback: Self.defaultVignette)
        clearAngle = Self.clamp(clearAngle, Self.clearAngleRange, fallback: Self.defaultClearAngle)
    }
    private static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
