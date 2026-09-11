// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import CoreFoundation
@testable import foldelight

final class RenderExecutorTests: XCTestCase {
    @MainActor
    func testWorkerProgressesWhileMainThreadCannotProcessEvents() {
        XCTAssertTrue(Thread.isMainThread)
        let executor = RenderExecutor()
        defer { executor.stop() }
        let completed = DispatchSemaphore(value: 0)
        var ranOnWorker = false
        XCTAssertTrue(executor.perform {
            ranOnWorker = executor.isCurrent && !Thread.isMainThread
            completed.signal()
        })
        // A semaphore wait blocks main; it does not pump an XCTest run loop.
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(ranOnWorker)
    }

    func testCommonMainDeliveryRunsInsideNestedMainDispatchTrackingLoop() {
        let finished = expectation(description: "nested main callback")
        DispatchQueue.main.async {
            let loop = CFRunLoopGetCurrent()!
            let tracking = CFRunLoopMode(rawValue: "NSEventTrackingRunLoopMode" as CFString)
            CFRunLoopAddCommonMode(loop, tracking)
            var commonDelivered = false
            var dispatchDelivered = false
            MainRunLoop.perform { commonDelivered = true }
            DispatchQueue.main.async { dispatchDelivered = true }
            CFRunLoopRunInMode(tracking, 0.05, false)
            XCTAssertTrue(commonDelivered, "Visibility/failure handling must reach the nested AppKit run loop")
            XCTAssertFalse(dispatchDelivered, "The fixture must actually withhold queued main-dispatch work")
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    func testWakeBurstIsBoundedAndCanRearmAfterDrain() {
        let executor = RenderExecutor()
        defer { executor.stop() }
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        executor.perform { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        var calls = 0
        let wake = RenderWakeSignal(executor: executor) { calls += 1 }
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in wake.signal() }
        release.signal()
        executor.sync { XCTAssertEqual(calls, 1) }
        wake.signal()
        executor.sync { XCTAssertEqual(calls, 2) }
    }

    func testDeallocatedWakeDoesNotRunAndStoppedExecutorRejectsWork() {
        let executor = RenderExecutor()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        executor.perform { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        var calls = 0
        var wake: RenderWakeSignal? = RenderWakeSignal(executor: executor) { calls += 1 }
        weak var weakWake = wake
        wake?.signal()
        wake = nil
        XCTAssertNil(weakWake)
        release.signal()
        executor.sync { XCTAssertEqual(calls, 0) }
        executor.stop()
        XCTAssertFalse(executor.perform { XCTFail("Rejected work ran") })
        executor.stop()
    }

    func testAcceptedOperationsDrainBeforeStopAndSyncIsReentrant() {
        let executor = RenderExecutor()
        let completed = DispatchSemaphore(value: 0)
        var operations = 0
        for _ in 0..<100 { XCTAssertTrue(executor.perform { operations += 1 }) }
        XCTAssertTrue(executor.perform {
            executor.sync { operations += 1 }
            completed.signal()
        })
        executor.stop()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(operations, 101)
    }
}
