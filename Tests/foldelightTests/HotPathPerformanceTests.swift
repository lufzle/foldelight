// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import QuartzCore
@testable import foldelight

final class HotPathPerformanceTests: XCTestCase {
    private func requireBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_CPU_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_CPU_BENCHMARK=1 to run CPU hot-path measurements.")
        }
    }

    func testLatestAngleHandoffPerformance() throws {
        try requireBenchmark()
        let options = XCTMeasureOptions.default
        options.iterationCount = 5
        var slowest = 0.0
        let expectedChecksum = (0..<100_000).reduce(0.0) { $0 + Double($1 % 136 + $1) }
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let started = CACurrentMediaTime()
            let input = LatestAngleInput()
            var checksum = 0.0
            for index in 0..<100_000 {
                _ = input.put(angle: Double(index % 136), sampledAt: Double(index))
                if let latest = input.latest() { checksum += latest.angle + latest.sampledAt }
            }
            XCTAssertEqual(input.latest()?.sampledAt, 99_999)
            XCTAssertEqual(checksum, expectedChecksum, "Consume every handoff so release optimization cannot discard its values")
            slowest = max(slowest, CACurrentMediaTime() - started)
        }
        XCTAssertLessThan(slowest, 0.25, "The sensor-to-render handoff exceeded 2.5 microseconds per exchange")
    }

    func testDirtyFrameAndSmoothingPerformance() throws {
        try requireBenchmark()
        let options = XCTMeasureOptions.default
        options.iterationCount = 5
        var slowest = 0.0
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            let started = CACurrentMediaTime()
            var gate = DirtyFrameGate()
            var smoother = AngleSmoother(100)
            var checksum = 0.0
            for index in 0..<500_000 {
                let target = Double(index % 100)
                let angle = smoother.advance(to: target, at: Double(index) / 120)
                let inputs = RenderInputs(angle: angle, settings: EffectSettings(),
                                          sourceRevision: UInt64(index / 120))
                if gate.needsFrame(inputs) { gate.didSubmit(inputs) }
                checksum += angle
            }
            XCTAssertNotNil(gate.submitted)
            // The sum observes every smoothed output, rather than merely
            // checking that the final optional gate is populated.
            XCTAssertGreaterThan(checksum, 24_000_000)
            XCTAssertLessThan(checksum, 25_500_000)
            slowest = max(slowest, CACurrentMediaTime() - started)
        }
        XCTAssertLessThan(slowest, 1.5, "Frame planning exceeded 3 microseconds per frame")
    }
}
