// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import QuartzCore
@testable import foldelight

/// Known continuous trajectories sampled at the measured hardware cadence.
/// Truth is evaluated at presentation time, independently of the estimator.
/// These measure temporal error, not actual motion-to-photon or native FPS.
final class SparseMotionPerformanceTests: XCTestCase {
    private struct Result {
        var errors: [Double] = []
        var holds = 0
        var movingFrames = 0
        var output: [Double] = []
        var mean: Double { errors.reduce(0, +) / Double(errors.count) }
        var p95: Double { errors.sorted()[Int(Double(errors.count - 1) * 0.95)] }
        var holdFraction: Double { Double(holds) / Double(max(1, movingFrames)) }
    }

    private func run(predicted: Bool, coarse: Bool = false, sampleRate: Double = 10,
                     jitter: Bool = false, truth: (Double) -> Double) -> Result {
        var motion = LidMotionEstimator(), smoother = AngleSmoother(truth(0))
        var result = Result(), sampled = truth(0), previous = truth(0), nextSample = 0.0, sampleCount = 0
        for frame in 0..<720 {
            let now = Double(frame) / 120, presentation = now + 5.0 / 120
            if now + 1e-9 >= nextSample {
                sampled = coarse ? truth(now).rounded() : (truth(now) * 100).rounded() / 100
                motion.observe(TimedAngle(angle: sampled, sampledAt: now))
                nextSample += 1 / sampleRate + (jitter ? sin(Double(sampleCount) * 2.1) * 0.008 : 0)
                sampleCount += 1
            }
            let target = predicted ? motion.target(at: presentation, now: now) ?? sampled : sampled
            let rendered = smoother.advance(to: target, at: presentation)
            result.output.append(rendered)
            // Exclude startup only. Stops and reversals remain in the error population.
            if now >= 0.3 {
                result.errors.append(abs(rendered - truth(presentation)))
                if abs(truth(presentation + 1 / 120) - truth(presentation)) > 0.01 {
                    result.movingFrames += 1
                    if abs(rendered - previous) < 0.01 { result.holds += 1 }
                }
            }
            previous = rendered
        }
        return result
    }

    func testSparseSmoothMotionReducesTrackingErrorAndHeldFrames() {
        for rate in [8.0, 10.0, 12.0, 60.0, 120.0] {
            for jitter in [false, true] {
                let truth: (Double) -> Double = { 80 + 35 * cos($0 * 2) }
                let old = run(predicted: false, coarse: true, sampleRate: rate, jitter: jitter, truth: truth)
                let fine = run(predicted: false, sampleRate: rate, jitter: jitter, truth: truth)
                let predicted = run(predicted: true, sampleRate: rate, jitter: jitter, truth: truth)
                print(String(format: "SPARSE_MOTION rate=%.0f jitter=%@ oldMean=%.4f fineMean=%.4f predictedMean=%.4f oldP95=%.4f predictedP95=%.4f oldHolds=%.4f predictedHolds=%.4f",
                    rate, String(jitter), old.mean, fine.mean, predicted.mean, old.p95, predicted.p95, old.holdFraction, predicted.holdFraction))
                XCTAssertLessThan(predicted.mean, old.mean * 0.55)
                XCTAssertLessThan(predicted.p95, old.p95 * 0.75)
                if rate <= 12 {
                    XCTAssertLessThan(predicted.holdFraction, 0.08)
                    XCTAssertGreaterThan(old.holdFraction, 0.35)
                }
            }
        }
    }

    func testPiecewiseMotionIncludesStopAndReversalError() {
        for speed in [3.0, 35.0, 100.0] {
            let duration = min(2, 90 / speed), end = 0.5 + duration, reopen = end + 0.5
            let truth: (Double) -> Double = { time in
                140 - speed * min(duration, max(0, time - 0.5))
                    + speed * min(duration, max(0, time - reopen))
            }
            let old = run(predicted: false, coarse: true, truth: truth)
            let predicted = run(predicted: true, truth: truth)
            print(String(format: "SPARSE_STOPS speed=%.0f oldMean=%.4f predictedMean=%.4f oldP95=%.4f predictedP95=%.4f",
                         speed, old.mean, predicted.mean, old.p95, predicted.p95))
            XCTAssertLessThan(predicted.mean, old.mean * 0.65)
            // Prediction can overshoot an unreported stop. Require recovery,
            // including the worst case where stationary reports are identical.
            let settled = Int((end + 0.22) * 120)
            XCTAssertEqual(predicted.output[settled], truth(Double(settled) / 120), accuracy: 0.16)
        }
    }

    func testCapturedLidTraceReplaysWithoutRunawayAndConfirmsReportAgreement() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/LidPrecision20260911.csv")
        let rows = try String(contentsOf: file).split(separator: "\n").dropFirst().map {
            $0.split(separator: ",").compactMap { Double($0) }
        }
        XCTAssertEqual(rows.count, 1426)
        var motion = LidMotionEstimator(), smoother = AngleSmoother(rows[0][3] / 100)
        var changedTimes: [Double] = [], previous: Double?, index = 0, final: Double = 0
        for row in rows {
            XCTAssertEqual(row.count, 5); XCTAssertEqual(row[4], 5)
            if row[3] != previous { changedTimes.append(row[1]); previous = row[3] }
        }
        XCTAssertEqual(changedTimes.count, 113)
        let intervals = zip(changedTimes, changedTimes.dropFirst()).map { $1 - $0 }.sorted()
        XCTAssertTrue((0.099...0.102).contains(intervals[intervals.count / 2]))
        for i in 0..<(rows.count - 1) {
            let fine = rows[i][3] / 100
            let error = min(abs(fine - rows[i][2]), abs(fine - rows[i + 1][2]))
            XCTAssertLessThanOrEqual(error, 0.51, "Read \(i) disagrees even after bracketing an intervening update")
        }
        for frame in 0..<1500 {
            let now = Double(frame) / 120
            while index < rows.count && rows[index][1] <= now {
                motion.observe(TimedAngle(angle: rows[index][3] / 100, sampledAt: rows[index][1]))
                index += 1
            }
            if let value = motion.target(at: now + 5 / 120, now: now) {
                final = smoother.advance(to: value, at: now + 5 / 120)
                XCTAssertTrue(final.isFinite && (0...360).contains(final))
                XCTAssertLessThanOrEqual(abs(value - motion.measuredAngle!), 24.000001)
            }
        }
        XCTAssertEqual(final, rows.last![3] / 100, accuracy: 0.16)
        XCTAssertFalse(motion.isPredicting(at: 12.5))
    }

    func testEstimatorCPUCost() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_CPU_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_CPU_BENCHMARK=1 for estimator CPU cost.")
        }
        var checksum = 0.0, motion = LidMotionEstimator()
        let start = CACurrentMediaTime()
        for frame in 0..<500_000 {
            let now = Double(frame) / 120
            if frame % 12 == 0 { motion.observe(TimedAngle(angle: 80 + 35 * cos(now * 2), sampledAt: now)) }
            checksum += motion.target(at: now + 0.04, now: now) ?? 80
        }
        let duration = CACurrentMediaTime() - start
        print(String(format: "SPARSE_CPU frames=500000 durationMs=%.3f nsPerFrame=%.3f checksum=%.6f", duration * 1000, duration * 1e9 / 500000, checksum))
        XCTAssertTrue((39_000_000...41_000_000).contains(checksum))
        XCTAssertLessThan(duration, 0.25, "The estimator exceeded 500 nanoseconds per frame")
    }
}
