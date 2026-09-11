// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class FoldBlackoutTests: XCTestCase {
    func testDefaultFadeStartsBeforeTheStopAndIsBlackAtTheStop() {
        XCTAssertEqual(FoldBlackout.opacity(angle: 100, clearAngle: 100), 0)
        XCTAssertEqual(FoldBlackout.opacity(angle: 50, clearAngle: 100), 0)
        XCTAssertEqual(FoldBlackout.opacity(angle: 45.6, clearAngle: 100), 0, accuracy: 1e-12)
        XCTAssertEqual(FoldBlackout.opacity(angle: 38.8, clearAngle: 100), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FoldBlackout.opacity(angle: 42.2, clearAngle: 100), 0.15625, accuracy: 1e-12)
        XCTAssertEqual(FoldBlackout.opacity(angle: 35.4, clearAngle: 100), 0.84375, accuracy: 1e-12)
        XCTAssertEqual(FoldBlackout.opacity(angle: 32, clearAngle: 100), 1)
        XCTAssertEqual(FoldBlackout.opacity(angle: 0, clearAngle: 100), 1)
    }

    func testGeneratedAnglesAreMonotoneAndRetraceExactlyWhenReopened() {
        for clear in stride(from: 45.0, through: 135.0, by: 0.5) {
            let travel = min(68, clear), stop = clear - travel
            let start = stop + travel * 0.2
            XCTAssertEqual(FoldBlackout.opacity(angle: start, clearAngle: clear), 0, accuracy: 1e-12)
            XCTAssertEqual(FoldBlackout.opacity(angle: stop, clearAngle: clear), 1)
            var closing: [Double] = []
            for sample in 0...200 {
                let angle = clear * (1 - Double(sample) / 200)
                let opacity = FoldBlackout.opacity(angle: angle, clearAngle: clear)
                XCTAssertTrue(opacity.isFinite && (0...1).contains(opacity))
                if let previous = closing.last { XCTAssertGreaterThanOrEqual(opacity, previous) }
                if angle >= start { XCTAssertEqual(opacity, 0, accuracy: 1e-12) }
                if angle <= stop { XCTAssertEqual(opacity, 1) }
                closing.append(opacity)
            }
            for sample in (0...200).reversed() {
                let angle = clear * (1 - Double(sample) / 200)
                XCTAssertEqual(FoldBlackout.opacity(angle: angle, clearAngle: clear), closing[sample])
            }
        }
    }

    func testHoldingTheLidCannotContinueFadingAndCadenceCannotChangeOpacity() {
        let held = FoldBlackout.opacity(angle: 40, clearAngle: 100)
        XCTAssertGreaterThan(held, 0)
        XCTAssertLessThan(held, 1)
        for _ in 0..<10_000 { XCTAssertEqual(FoldBlackout.opacity(angle: 40, clearAngle: 100), held) }
        for rate in [24, 30, 60, 120, 144, 240] {
            for frame in 0...rate {
                let fraction = Double(frame) / Double(rate)
                let angle = 45.6 - 13.6 * fraction
                let expected = fraction * fraction * (3 - 2 * fraction)
                XCTAssertEqual(FoldBlackout.opacity(angle: angle, clearAngle: 100), expected, accuracy: 1e-12)
            }
        }
    }

    func testFadeHasNoBrightnessJumpOrSlopeJumpAtEitherBoundary() {
        let step = 0.001
        for boundary in [45.6, 32] {
            let left = FoldBlackout.opacity(angle: boundary - step, clearAngle: 100)
            let right = FoldBlackout.opacity(angle: boundary + step, clearAngle: 100)
            XCTAssertLessThan(abs(left - right) / (2 * step), 0.0001)
        }
    }

    func testInvalidInputFailsClear() {
        for angle in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(FoldBlackout.opacity(angle: angle, clearAngle: 100), 0)
        }
        for clear in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertEqual(FoldBlackout.opacity(angle: 30, clearAngle: clear), 0)
        }
    }

    func testFadeInvalidatesFramesButOpaqueBlackSleepsUntilReopening() {
        var gate = DirtyFrameGate()
        var frame = RenderInputs(angle: 30, settings: EffectSettings(), sourceRevision: 1)
        gate.didSubmit(frame)
        for opacity in [0.1, 0.3, 0.6, 1] {
            frame.blackout = opacity
            XCTAssertTrue(gate.needsFrame(frame))
            gate.didSubmit(frame)
            XCTAssertFalse(gate.needsFrame(frame))
        }
        for revision in 2...10_000 {
            frame.sourceRevision = UInt64(revision)
            frame.angle = Double(revision % 30)
            XCTAssertFalse(gate.needsFrame(frame))
        }
        frame.blackout = 0.999
        XCTAssertTrue(gate.needsFrame(frame))
        frame.blackout = 1
        gate.reset()
        XCTAssertTrue(gate.needsFrame(frame), "A failed black submission must retry")
    }
}
