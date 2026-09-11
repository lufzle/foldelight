// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import CoreGraphics

/// Damage belongs to the last successful blur rebuild, not the last sharp draw.
/// Unknown damage or an unsubmitted/failed rebuild requires the complete source.
struct PyramidUpdateState {
    private(set) var needsRefresh = true
    private(set) var damage: [CGRect]? = nil

    mutating func accept(_ incoming: [CGRect]?) {
        damage = needsRefresh ? FrameDamage.merging(damage, incoming) : incoming
        needsRefresh = true
    }

    mutating func didSubmit(usedPyramid: Bool) {
        guard usedPyramid else { return }
        needsRefresh = false
        damage = []
    }

    mutating func invalidate() {
        needsRefresh = true
        damage = nil
    }
}
