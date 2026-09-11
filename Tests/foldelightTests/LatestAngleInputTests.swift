// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class LatestAngleInputTests: XCTestCase {
    func testInvalidationRejectsOlderRecoveryAndPreservesReadTiming() {
        let input = LatestAngleInput()
        XCTAssertTrue(input.put(angle: 70, sampledAt: 10, readStartedAt: 9.998))
        XCTAssertEqual(input.latest()?.readStartedAt, 9.998)
        XCTAssertTrue(input.invalidate(at: 11))
        XCTAssertEqual(input.snapshot(), SensorInputSnapshot(reading: nil, unavailable: true))
        XCTAssertFalse(input.put(angle: 75, sampledAt: 10.9, readStartedAt: 10.8))
        XCTAssertFalse(input.invalidate(at: 10.9))
        XCTAssertTrue(input.put(angle: 80, sampledAt: 12, readStartedAt: 11.999))
        XCTAssertEqual(input.snapshot(), SensorInputSnapshot(
            reading: TimedAngle(angle: 80, sampledAt: 12, readStartedAt: 11.999), unavailable: false))
        input.reset()
        XCTAssertEqual(input.snapshot(), SensorInputSnapshot(reading: nil, unavailable: false))
        XCTAssertTrue(input.put(angle: 90, sampledAt: 1, readStartedAt: 0.9))
    }

    func testReadTimingRejectsImpossibleIntervalsWithoutChangingState() {
        let input = LatestAngleInput()
        XCTAssertTrue(input.put(angle: 70, sampledAt: 10, readStartedAt: 9))
        let expected = input.snapshot()
        for invalid in [Double.nan, .infinity, -.infinity, 12] {
            XCTAssertFalse(input.put(angle: 80, sampledAt: 11, readStartedAt: invalid))
            XCTAssertEqual(input.snapshot(), expected)
        }
        XCTAssertFalse(input.invalidate(at: .nan))
        XCTAssertFalse(input.invalidate(at: .infinity))
        XCTAssertEqual(input.snapshot(), expected)
        XCTAssertTrue(input.put(angle: 80, sampledAt: 11, readStartedAt: 11))
    }

    func testObserverRunsOutsideLockAndRemovalStopsNotification() {
        let input = LatestAngleInput()
        var snapshots: [SensorInputSnapshot] = []
        input.observe { value in
            XCTAssertEqual(input.snapshot(), value, "Observer can safely reenter snapshot")
            snapshots.append(value)
        }
        input.put(angle: 70, sampledAt: 1, readStartedAt: 0.99)
        input.invalidate(at: 2)
        XCTAssertEqual(snapshots.map(\.unavailable), [false, true])
        input.observe(nil)
        input.put(angle: 80, sampledAt: 3)
        XCTAssertEqual(snapshots.count, 2)
    }

    func testGeneratedReadsInvalidationsAndResetsMatchReference() {
        let input = LatestAngleInput()
        var latestTime = -Double.infinity
        var reading: TimedAngle?
        var unavailable = false
        var seed: UInt64 = 0xBAD_F01D
        var acceptedCount = 0, rejectedCount = 0, invalidationCount = 0, resetCount = 0
        for index in 0..<30_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let action = (seed >> 32) % 6
            let time = Double(index) - Double(seed % 10)
            if action == 0 {
                input.reset(); latestTime = -.infinity; reading = nil; unavailable = false; resetCount += 1
            } else if action == 1 {
                let accepted = time >= latestTime
                XCTAssertEqual(input.invalidate(at: time), accepted)
                if accepted { latestTime = time; reading = nil; unavailable = true; invalidationCount += 1 }
            } else {
                let readStart = time + (action == 2 ? 0.01 : -0.001)
                let angle = Double(seed % 136)
                let accepted = time >= latestTime && readStart <= time
                XCTAssertEqual(input.put(angle: angle, sampledAt: time, readStartedAt: readStart), accepted)
                if accepted {
                    latestTime = time; reading = TimedAngle(angle: angle, sampledAt: time, readStartedAt: readStart)
                    unavailable = false; acceptedCount += 1
                } else { rejectedCount += 1 }
            }
            XCTAssertEqual(input.snapshot(), SensorInputSnapshot(reading: reading, unavailable: unavailable))
        }
        XCTAssertGreaterThan(acceptedCount, 5_000)
        XCTAssertGreaterThan(rejectedCount, 5_000)
        XCTAssertGreaterThan(invalidationCount, 1_000)
        XCTAssertGreaterThan(resetCount, 1_000)
    }
}
