// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

/// Fixed seeds make every generated failure reproducible without a third-party runtime.
final class CorePropertyTests: XCTestCase {
    private struct Samples {
        var state: UInt64 = 0xF01DE119_20260910
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / 9007199254740992
        }
        mutating func value(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + unit() * (range.upperBound - range.lowerBound)
        }
    }

    func testGeneratedProgressBoundsOrderingSymmetryAndScaleInvariance() {
        var samples = Samples()
        for index in 0..<10_000 {
            let threshold = samples.value(45...135)
            let fraction = samples.unit()
            let angle = threshold * fraction
            let progress = EffectSettings.progress(angle: angle, clearAngle: threshold)
            XCTAssertTrue(progress.isFinite && (0...1).contains(progress), "sample \(index)")
            XCTAssertEqual(progress + EffectSettings.progress(angle: threshold - angle, clearAngle: threshold), 1, accuracy: 1e-12)
            let scale = samples.value(0.01...100)
            XCTAssertEqual(progress, EffectSettings.progress(angle: angle * scale, clearAngle: threshold * scale), accuracy: 1e-12)
            let laterAngle = samples.value(angle...threshold)
            XCTAssertGreaterThanOrEqual(progress, EffectSettings.progress(angle: laterAngle, clearAngle: threshold))
            XCTAssertEqual(EffectSettings.progress(angle: threshold + samples.value(0...10_000), clearAngle: threshold), 0)
            XCTAssertEqual(EffectSettings.progress(angle: -samples.value(0...10_000), clearAngle: threshold), 1)
        }
    }

    func testProgressInvalidInputsAndKnownCurveAnchors() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(EffectSettings.progress(angle: invalid, clearAngle: 105), 0)
            XCTAssertEqual(EffectSettings.progress(angle: 50, clearAngle: invalid), 0)
        }
        for threshold in [-100.0, -Double.leastNonzeroMagnitude, 0] {
            XCTAssertEqual(EffectSettings.progress(angle: 0, clearAngle: threshold), 0)
        }
        for (angle, expected) in [(0.0, 1.0), (25, 0.84375), (50, 0.5), (75, 0.15625), (100, 0)] {
            XCTAssertEqual(EffectSettings.progress(angle: angle, clearAngle: 100), expected, accuracy: 1e-12)
        }
        // A smooth landing: the slope approaches zero at each endpoint.
        XCTAssertLessThan(EffectSettings.progress(angle: 99.99, clearAngle: 100), 0.000001)
        XCTAssertLessThan(1 - EffectSettings.progress(angle: 0.01, clearAngle: 100), 0.000001)
    }

    func testGeneratedSanitizationProjectionIdempotenceAndCodable() throws {
        var samples = Samples()
        for _ in 0..<3_000 {
            let original = EffectSettings(blur: samples.value(-10...10), shadow: samples.value(-10...10), clearAngle: samples.value(-500...500))
            var settings = original
            settings.sanitize()
            XCTAssertTrue((0...1).contains(settings.blur))
            XCTAssertTrue((0...1).contains(settings.shadow))
            XCTAssertTrue((45...132).contains(settings.clearAngle))
            if (0...1).contains(original.blur) { XCTAssertEqual(settings.blur, original.blur) }
            if (0...1).contains(original.shadow) { XCTAssertEqual(settings.shadow, original.shadow) }
            if (45...132).contains(original.clearAngle) { XCTAssertEqual(settings.clearAngle, original.clearAngle) }
            let once = settings
            settings.sanitize()
            XCTAssertEqual(settings, once)
            XCTAssertEqual(try JSONDecoder().decode(EffectSettings.self, from: JSONEncoder().encode(settings)), settings)
        }
    }

    func testSanitizationExactBoundsAndNonFiniteDefaults() {
        for value in [Double.nan, .infinity, -.infinity] {
            var settings = EffectSettings(blur: value, shadow: value, clearAngle: value)
            settings.sanitize()
            XCTAssertEqual(settings, EffectSettings())
        }
        var low = EffectSettings(blur: -1, shadow: -1, clearAngle: 44)
        var high = EffectSettings(blur: 2, shadow: 2, clearAngle: 136)
        low.sanitize(); high.sanitize()
        XCTAssertEqual(low, EffectSettings(blur: 0, shadow: 0, clearAngle: 45))
        XCTAssertEqual(high, EffectSettings(blur: 1, shadow: 1, clearAngle: 132))
    }

    func testGeneratedSmoothingNeverOvershootsAndSettlesExactly() {
        var samples = Samples()
        for _ in 0..<2_000 {
            let start = samples.value(0...180), target = samples.value(0...180)
            var smoother = AngleSmoother(start)
            var time = 0.0, previous = start
            for _ in 0..<50 {
                time += samples.value(0.001...0.04)
                let value = smoother.advance(to: target, at: time)
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, min(previous, target))
                XCTAssertLessThanOrEqual(value, max(previous, target))
                XCTAssertLessThanOrEqual(abs(target - value), abs(target - previous))
                previous = value
            }
            XCTAssertEqual(smoother.value, target)
        }
    }

    func testGeneratedTimePartitionsAgreeBeforeSnapThreshold() {
        var samples = Samples()
        for _ in 0..<2_000 {
            let start = samples.value(100...180), target = samples.value(0...50)
            let duration = samples.value(0.005...0.08), split = samples.value(0.1...0.9)
            var whole = AngleSmoother(start), partitioned = AngleSmoother(start)
            _ = whole.advance(to: start, at: 0)
            _ = partitioned.advance(to: start, at: 0)
            _ = whole.advance(to: target, at: duration)
            _ = partitioned.advance(to: target, at: duration * split)
            _ = partitioned.advance(to: target, at: duration)
            XCTAssertEqual(whole.value, partitioned.value, accuracy: 1e-10)
        }
    }

    func testSmoothingSnapsSmallResidualButKeepsLargerResidual() {
        var close = AngleSmoother(60.005), far = AngleSmoother(60.05)
        XCTAssertEqual(close.advance(to: 60, at: 0), 60)
        XCTAssertGreaterThan(far.advance(to: 60, at: 0), 60)
    }

    func testSmoothingDuplicateBackwardTimestampsAndLongGapCap() {
        var smoother = AngleSmoother(120)
        _ = smoother.advance(to: 120, at: 1)
        XCTAssertEqual(smoother.advance(to: 30, at: 1), 120)
        XCTAssertEqual(smoother.advance(to: 30, at: 0.5), 120)
        var capped = AngleSmoother(120), normal = AngleSmoother(120)
        _ = capped.advance(to: 120, at: 0)
        _ = normal.advance(to: 120, at: 0)
        XCTAssertEqual(capped.advance(to: 30, at: 100), normal.advance(to: 30, at: 0.1), accuracy: 1e-12)
        XCTAssertEqual(capped.value, 30)
    }
}
