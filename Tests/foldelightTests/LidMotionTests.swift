// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class LidMotionTests: XCTestCase {
    func testConstantSpeedPredictsAtPresentationWithoutQuantizedHolds() throws {
        var motion = LidMotionEstimator()
        motion.observe(TimedAngle(angle: 90, sampledAt: 1))
        motion.observe(TimedAngle(angle: 86, sampledAt: 1.1))
        XCTAssertEqual(motion.velocity, -40, accuracy: 0.000001)
        for frame in 0..<12 {
            let now = 1.1 + Double(frame) / 120, present = now + 1.0 / 24
            XCTAssertEqual(try XCTUnwrap(motion.target(at: present, now: now)), 86 - 40 * (present - 1.1), accuracy: 0.000001)
        }
    }

    func testDuplicatePollingDoesNotEraseVelocityOrExtendPrediction() throws {
        var motion = LidMotionEstimator()
        motion.observe(TimedAngle(angle: 90, sampledAt: 1))
        motion.observe(TimedAngle(angle: 86, sampledAt: 1.1))
        for frame in 1...60 { motion.observe(TimedAngle(angle: 86, sampledAt: 1.1 + Double(frame) / 120)) }
        XCTAssertEqual(motion.velocity, -40, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(motion.target(at: 1.7, now: 1.6)), 86)
        XCTAssertFalse(motion.isPredicting(at: 1.6))
    }

    func testStationaryNoiseCannotCreateAnAnimation() throws {
        var motion = LidMotionEstimator()
        motion.observe(TimedAngle(angle: 80, sampledAt: 0))
        for step in 1...1000 {
            let time = Double(step) / 10
            motion.observe(TimedAngle(angle: 80 + sin(Double(step) * 2.3) * 0.09, sampledAt: time))
            XCTAssertEqual(try XCTUnwrap(motion.target(at: time + 0.04, now: time)), 80)
            XCTAssertFalse(motion.isPredicting(at: time))
        }
    }

    func testNoiseDeadbandCannotSuppressActivationOrFinalOpening() {
        var motion = LidMotionEstimator()
        motion.observe(TimedAngle(angle: 100.02, sampledAt: 0), activationAngle: 100)
        motion.observe(TimedAngle(angle: 99.98, sampledAt: 0.1), activationAngle: 100)
        XCTAssertEqual(motion.measuredAngle, 99.98)
        motion.observe(TimedAngle(angle: 100.01, sampledAt: 0.2), activationAngle: 100)
        XCTAssertEqual(motion.measuredAngle, 100.01)
    }

    func testNoiseDeadbandPreservesBothDirectionsAcrossEveryConfiguredFoldStop() {
        for clear in stride(from: 45.0, through: 135.0, by: 0.5) {
            let stop = max(0, clear - 68)
            var motion = LidMotionEstimator()
            let closed = max(0, stop - 0.05), open = stop + 0.05
            motion.observe(TimedAngle(angle: open, sampledAt: 0), activationAngle: clear)
            motion.observe(TimedAngle(angle: closed, sampledAt: 0.1), activationAngle: clear)
            XCTAssertEqual(motion.measuredAngle, closed)
            motion.observe(TimedAngle(angle: open, sampledAt: 0.2), activationAngle: clear)
            XCTAssertEqual(motion.measuredAngle, open)
            motion.observe(TimedAngle(angle: stop, sampledAt: 0.3), activationAngle: clear)
            XCTAssertEqual(motion.measuredAngle, stop, "The exact maximum fold is included")
            XCTAssertEqual(motion.velocity, 0, "A boundary crossing need not create a noise forecast")
        }
    }

    func testStopReversalGapAndResetDiscardOldDirection() throws {
        var motion = LidMotionEstimator()
        motion.observe(TimedAngle(angle: 90, sampledAt: 1))
        motion.observe(TimedAngle(angle: 86, sampledAt: 1.1))
        motion.observe(TimedAngle(angle: 88, sampledAt: 1.2))
        XCTAssertGreaterThan(try XCTUnwrap(motion.target(at: 1.24, now: 1.2)), 88)
        motion.observe(TimedAngle(angle: 88.02, sampledAt: 1.3))
        XCTAssertEqual(motion.velocity, 0)
        XCTAssertEqual(motion.target(at: 1.35, now: 1.3), 88)
        motion.observe(TimedAngle(angle: 60, sampledAt: 5))
        XCTAssertEqual(motion.target(at: 5.04, now: 5), 60)
        motion.reset()
        XCTAssertNil(motion.target(at: 5.2, now: 5.2))
    }

    func testInvalidAndReorderedReportsCannotPoisonMotion() {
        var motion = LidMotionEstimator()
        motion.observe(TimedAngle(angle: 90, sampledAt: 1))
        motion.observe(TimedAngle(angle: 85, sampledAt: 1.1))
        let expected = motion.target(at: 1.15, now: 1.11)
        for sample in [TimedAngle(angle: 70, sampledAt: 1), TimedAngle(angle: 70, sampledAt: 1.1),
                       TimedAngle(angle: .nan, sampledAt: 1.2), TimedAngle(angle: 40, sampledAt: .infinity),
                       TimedAngle(angle: -1, sampledAt: 1.2), TimedAngle(angle: 361, sampledAt: 1.2)] {
            motion.observe(sample)
            XCTAssertEqual(motion.target(at: 1.15, now: 1.11), expected)
        }
        XCTAssertEqual(motion.target(at: .nan, now: 1.11), 85)
        XCTAssertEqual(motion.target(at: 1.15, now: .infinity), 85)
        XCTAssertEqual(motion.target(at: 1, now: 1), 85)
    }

    func testSeededStreamsStayFiniteBoundedAndExpire() throws {
        var seed: UInt64 = 0x51d20260911
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        for _ in 0..<200 {
            var motion = LidMotionEstimator(), time = 0.0
            for _ in 0..<100 {
                time += 0.002 + random() * 0.35
                motion.observe(TimedAngle(angle: random() * 360, sampledAt: time))
                let base = try XCTUnwrap(motion.measuredAngle)
                let value = try XCTUnwrap(motion.target(at: time + random(), now: time + random() * 0.12))
                XCTAssertTrue(value.isFinite && (0...360).contains(value))
                XCTAssertLessThanOrEqual(abs(value - base), 24.000001)
                XCTAssertLessThanOrEqual(abs(motion.velocity), 180)
                XCTAssertEqual(motion.target(at: time + 1, now: time + 0.3), base)
                XCTAssertFalse(motion.isPredicting(at: time + 0.3))
            }
        }
    }

    func testPresentationLeadAndUndersampledIntervalsAreBounded() {
        var motion = LidMotionEstimator()
        motion.observe(TimedAngle(angle: 90, sampledAt: 1))
        motion.observe(TimedAngle(angle: 88, sampledAt: 1.1))
        XCTAssertEqual(motion.target(at: 20, now: 1.15)!, 86, accuracy: 0.00001)
        XCTAssertEqual(motion.target(at: 2, now: 1.3), 88, "A future presentation cannot refresh a stale reading")
        motion.observe(TimedAngle(angle: 60, sampledAt: 1.101))
        XCTAssertEqual(motion.velocity, 0, "A 1 ms jump is not a reliable velocity sample")
    }
}
