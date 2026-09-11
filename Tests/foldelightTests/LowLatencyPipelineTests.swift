// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
import QuartzCore
@testable import foldelight

final class LowLatencyPipelineTests: XCTestCase {
    @MainActor
    func testMetalClockConfiguresRealLinkAndControlsItsLifecycle() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let clock = MetalFrameClock()
        XCTAssertNil(clock.configuration)
        clock.configure(layer: CAMetalLayer(), screen: screen)
        let configuration = try XCTUnwrap(clock.configuration)
        XCTAssertEqual(configuration.latency, 1)
        XCTAssertEqual(configuration.minimumRate, Float(screen.maximumFramesPerSecond))
        XCTAssertEqual(configuration.maximumRate, Float(screen.maximumFramesPerSecond))
        XCTAssertEqual(configuration.preferredRate, Float(screen.maximumFramesPerSecond))
        XCTAssertTrue(configuration.paused)
        clock.start()
        XCTAssertEqual(clock.configuration?.paused, false)
        clock.stop()
        XCTAssertEqual(clock.configuration?.paused, true)
        clock.invalidate()
        XCTAssertNil(clock.configuration)
        XCTAssertFalse(clock.configured)
    }

    func testLatestAngleInputKeepsNewestValidReading() {
        let input = LatestAngleInput()
        XCTAssertTrue(input.put(angle: 90, sampledAt: 10))
        XCTAssertTrue(input.put(angle: 80, sampledAt: 11))
        XCTAssertFalse(input.put(angle: 70, sampledAt: 10.5))
        XCTAssertFalse(input.put(angle: .nan, sampledAt: 12))
        XCTAssertFalse(input.put(angle: 60, sampledAt: .infinity))
        XCTAssertEqual(input.latest(), TimedAngle(angle: 80, sampledAt: 11))
        input.reset()
        XCTAssertNil(input.latest())
    }

    func testLatestAngleInputIsLatestWinsUnderConcurrentWriters() {
        let input = LatestAngleInput()
        DispatchQueue.concurrentPerform(iterations: 10_000) { index in
            _ = input.put(angle: Double(index), sampledAt: Double(index))
        }
        XCTAssertEqual(input.latest(), TimedAngle(angle: 9_999, sampledAt: 9_999))
    }

    func testDirtyFrameGateSubmitsOnlyChangedInputs() {
        var gate = DirtyFrameGate()
        let base = RenderInputs(angle: 72, settings: EffectSettings(), sourceRevision: 4)
        XCTAssertTrue(gate.needsFrame(base))
        XCTAssertTrue(gate.needsFrame(base), "A skipped submission must remain dirty")
        gate.didSubmit(base)
        XCTAssertFalse(gate.needsFrame(base))

        var changedAngle = base
        changedAngle.angle = changedAngle.angle.nextUp
        XCTAssertTrue(gate.needsFrame(changedAngle))

        var changedSettings = base
        changedSettings.settings.blur = 0.75
        XCTAssertTrue(gate.needsFrame(changedSettings))

        var changedSource = base
        changedSource.sourceRevision &+= 1
        XCTAssertTrue(gate.needsFrame(changedSource))
        gate.reset()
        XCTAssertTrue(gate.needsFrame(base))
    }

    func testDirtyFrameGateMatchesReferenceModelAcrossGeneratedInputs() {
        var gate = DirtyFrameGate()
        var candidate = RenderInputs(angle: 72, settings: EffectSettings(), sourceRevision: 4)
        // Independent reference stores scalar successful-submission values.
        var accepted: [Double]?
        func scalars(_ input: RenderInputs) -> [Double] {
            [input.angle, input.settings.blur, input.settings.shadow,
             input.settings.clearAngle, Double(input.sourceRevision)]
        }
        var random: UInt64 = 0xF01D_E11A_9E37_79B9
        var unchanged = 0, dirty = 0, skipped = 0, failures = 0, resets = 0
        var changedFields = Set<Int>()
        for iteration in 0..<50_000 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let action = Int((random >> 32) % 11)
            switch action {
            case 0...4:
                // One field changes; the other fields remain exactly equal.
                changedFields.insert(action)
                switch action {
                case 0: candidate.angle = candidate.angle == 72 ? 71 : 72
                case 1: candidate.settings.blur = candidate.settings.blur == 0.5 ? 0.6 : 0.5
                case 2: candidate.settings.shadow = candidate.settings.shadow == 0.3 ? 0.4 : 0.3
                case 3: candidate.settings.clearAngle = candidate.settings.clearAngle == 100 ? 101 : 100
                default: candidate.sourceRevision &+= 1
                }
            case 5: // Explicit reset, then retry the same candidate.
                gate.reset(); accepted = nil; resets += 1
            case 6: // Asynchronous failure invalidates a previously accepted frame.
                gate.didSubmit(candidate); accepted = scalars(candidate)
                gate.reset(); accepted = nil; failures += 1
            default: break // Exact repeats are essential to exercise suppression.
            }
            let expectedDirty = accepted != scalars(candidate)
            XCTAssertEqual(gate.needsFrame(candidate), expectedDirty, "Generated event \(iteration)")
            if expectedDirty { dirty += 1 } else { unchanged += 1 }
            if action == 7 {
                skipped += 1
                XCTAssertEqual(gate.needsFrame(candidate), expectedDirty)
            } else if expectedDirty {
                gate.didSubmit(candidate); accepted = scalars(candidate)
                XCTAssertFalse(gate.needsFrame(candidate), "Immediate exact repeat must be suppressed")
            }
        }
        XCTAssertGreaterThan(unchanged, 5_000)
        XCTAssertGreaterThan(dirty, 20_000)
        XCTAssertGreaterThan(skipped, 1_000)
        XCTAssertGreaterThan(failures, 1_000)
        XCTAssertGreaterThan(resets, 1_000)
        XCTAssertEqual(changedFields, Set(0...4))
    }

    func testSmootherReachesNinetyFivePercentWithinThree120HzIntervals() {
        var smoother = AngleSmoother(100)
        for frame in 0..<3 {
            _ = smoother.advance(to: 0, at: Double(frame) / 120)
        }
        XCTAssertLessThanOrEqual(smoother.value, 5)
        XCTAssertEqual(AngleSmoother.responseTime, 0.008, accuracy: 0.000_001)
    }

    func testGeneratedSmoothingNeverOvershootsOrMovesAwayFromTarget() {
        var state: UInt64 = 0x51_00_7A_9E_37_79_B9
        for example in 0..<10_000 {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let initial = Double(Int(state % 361) - 180)
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let target = Double(Int(state % 361) - 180)
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            let dt = Double(state % 100_001) / 1_000_000
            var smoother = AngleSmoother(initial)
            _ = smoother.advance(to: initial, at: 1)
            let result = smoother.advance(to: target, at: 1 + dt)
            XCTAssertGreaterThanOrEqual(result, min(initial, target), "Generated case \(example)")
            XCTAssertLessThanOrEqual(result, max(initial, target), "Generated case \(example)")
            XCTAssertLessThanOrEqual(abs(target - result), abs(target - initial), "Generated case \(example)")
        }
    }

    func testSmootherIgnoresReversedTimeAndBoundsLongPauses() {
        var reversed = AngleSmoother(100)
        _ = reversed.advance(to: 100, at: 10)
        XCTAssertEqual(reversed.advance(to: 0, at: 9), 100)

        var capped = AngleSmoother(100)
        _ = capped.advance(to: 100, at: 0)
        let afterLongPause = capped.advance(to: 0, at: 60)
        var expected = AngleSmoother(100)
        _ = expected.advance(to: 100, at: 0)
        let afterTenthSecond = expected.advance(to: 0, at: 0.1)
        XCTAssertEqual(afterLongPause, afterTenthSecond, accuracy: 0.000_001)
    }
}
