// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class FramePacingTests: XCTestCase {
    func testSmoothingIsIndependentOfRefreshRate() {
        func run(_ rate: Int) -> Double {
            var smoother = AngleSmoother(120)
            _ = smoother.advance(to: 120, at: 0)
            for frame in 1...rate / 10 { _ = smoother.advance(to: 60, at: Double(frame) / Double(rate)) }
            return smoother.value
        }
        XCTAssertEqual(run(60), run(120), accuracy: 0.000001)
        XCTAssertLessThan(abs(run(120) - 60), 1.2)
    }
    func testOpeningSettlesWithoutOvershoot() {
        var smoother = AngleSmoother(35)
        for frame in 0...120 {
            let value = smoother.advance(to: 120, at: Double(frame) / 120)
            XCTAssertGreaterThanOrEqual(value, 35)
            XCTAssertLessThanOrEqual(value, 120)
        }
        XCTAssertEqual(smoother.value, 120)
        XCTAssertEqual(EffectSettings.progress(angle: smoother.value, clearAngle: 105), 0)
    }
}
