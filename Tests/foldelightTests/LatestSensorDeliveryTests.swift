// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class LatestSensorDeliveryTests: XCTestCase {
    func testStalledConsumerReceivesOnlyFreshestReading() {
        let mailbox = LatestSensorDelivery<Int>()
        mailbox.reset(generation: 1)
        var notifications = 0
        for angle in 0..<10_000 {
            if mailbox.put(angle, generation: 1) { notifications += 1 }
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(mailbox.take(generation: 1), 9_999)
        XCTAssertNil(mailbox.take(generation: 1))
        XCTAssertTrue(mailbox.put(42, generation: 1))
        XCTAssertEqual(mailbox.take(generation: 1), 42)
    }

    func testOldCallbackCannotConsumeOrRearmNewGeneration() {
        let mailbox = LatestSensorDelivery<Int>()
        mailbox.reset(generation: 1)
        XCTAssertTrue(mailbox.put(11, generation: 1))
        mailbox.reset(generation: nil)
        XCTAssertFalse(mailbox.put(12, generation: 1))
        XCTAssertNil(mailbox.take(generation: 1))
        mailbox.reset(generation: 2)
        XCTAssertTrue(mailbox.put(21, generation: 2))
        XCTAssertNil(mailbox.take(generation: 1))
        XCTAssertFalse(mailbox.put(13, generation: 1))
        XCTAssertFalse(mailbox.put(22, generation: 2))
        XCTAssertEqual(mailbox.take(generation: 2), 22)
    }

    func testTerminalReadFailureSurvivesCoalescing() {
        struct Report: Equatable { var angle: Int?; var stopped: Bool }
        let mailbox = LatestSensorDelivery<Report>()
        mailbox.reset(generation: 1)
        XCTAssertTrue(mailbox.put(Report(angle: 70, stopped: false), generation: 1))
        XCTAssertFalse(mailbox.put(Report(angle: nil, stopped: true), generation: 1))
        XCTAssertEqual(mailbox.take(generation: 1), Report(angle: nil, stopped: true))
    }

    func testGeneratedInterleavingsMatchLatestValueModel() {
        let mailbox = LatestSensorDelivery<Int>()
        var seed: UInt64 = 0xF01DE11
        var generation = 1
        var expected: Int?
        var pending = false
        mailbox.reset(generation: generation)
        for value in 0..<30_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            switch (seed >> 32) % 7 {
            case 0:
                generation += 1
                mailbox.reset(generation: generation)
                expected = nil; pending = false
            case 1:
                XCTAssertEqual(mailbox.take(generation: generation), expected)
                expected = nil; pending = false
            case 2:
                XCTAssertNil(mailbox.take(generation: generation - 1))
                XCTAssertFalse(mailbox.put(value, generation: generation - 1))
            default:
                XCTAssertEqual(mailbox.put(value, generation: generation), !pending)
                expected = value; pending = true
            }
        }
        XCTAssertEqual(mailbox.take(generation: generation), expected)
    }

    func testConcurrentProducersScheduleOneNotificationUntilDrain() {
        let mailbox = LatestSensorDelivery<Int>()
        mailbox.reset(generation: 1)
        let lock = NSLock()
        var notifications = 0
        DispatchQueue.concurrentPerform(iterations: 1_000) { value in
            if mailbox.put(value, generation: 1) {
                lock.lock(); notifications += 1; lock.unlock()
            }
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertNotNil(mailbox.take(generation: 1))
        XCTAssertTrue(mailbox.put(1_001, generation: 1))
        XCTAssertEqual(mailbox.take(generation: 1), 1_001)
    }
}
