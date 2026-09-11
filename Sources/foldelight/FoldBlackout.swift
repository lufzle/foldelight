// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Blackout follows the same rendered angle as the glass. The final fifth of
/// available rotation fades to black; reopening retraces exactly the same curve.
enum FoldBlackout {
    static let fadeFraction = 0.20

    static func opacity(angle: Double, clearAngle: Double) -> Double {
        guard angle.isFinite, clearAngle.isFinite, clearAngle > 0 else { return 0 }
        let travel = min(EffectSettings.maximumTiltDegrees, clearAngle)
        let stop = max(0, clearAngle - travel)
        let span = travel * fadeFraction
        let phase = min(1, max(0, (stop + span - angle) / span))
        return phase * phase * (3 - 2 * phase)
    }
}
