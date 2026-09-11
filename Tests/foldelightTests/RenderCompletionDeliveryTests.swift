// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class RenderCompletionDeliveryTests: XCTestCase {
    func testAcceptedCallbackInvalidatesBeforeReturningPermitExactlyOnce() {
        let permit = DispatchSemaphore(value: 1)
        permit.wait()
        var pending: (() -> Void)?
        var invalidated = false
        var releases = 0
        RenderCompletionDelivery.schedule(on: { pending = $0; return true }, work: {
            XCTAssertEqual(permit.wait(timeout: .now()), .timedOut)
            invalidated = true
        }, release: {
            XCTAssertTrue(invalidated)
            releases += 1
            permit.signal()
        })
        XCTAssertEqual(releases, 0)
        pending?()
        XCTAssertEqual(releases, 1)
        pending = nil
        XCTAssertEqual(releases, 1, "Closure disposal must not return a second permit")
        XCTAssertEqual(permit.wait(timeout: .now()), .success)
        XCTAssertEqual(permit.wait(timeout: .now()), .timedOut)
        permit.signal()
    }

    func testStoppedExecutorRejectsFailureCallbackButReturnsPermit() {
        let executor = RenderExecutor()
        executor.stop()
        let permit = DispatchSemaphore(value: 1)
        permit.wait()
        RenderCompletionDelivery.schedule(on: { executor.perform($0) }, work: {
            XCTFail("Stopped renderer must not be invalidated by a rejected callback")
        }, release: { permit.signal() })
        XCTAssertEqual(permit.wait(timeout: .now()), .success)
        XCTAssertEqual(permit.wait(timeout: .now()), .timedOut)
        permit.signal()
        // The old completion path trapped in libdispatch when this unbalanced
        // semaphore was deallocated after rejection.
    }

    func testDiscardedAcceptedClosureStillReturnsPermit() {
        var pending: (() -> Void)?
        var releases = 0
        RenderCompletionDelivery.schedule(on: { pending = $0; return true }, work: {
            XCTFail("Discarded work cannot execute")
        }, release: { releases += 1 })
        XCTAssertNotNil(pending)
        XCTAssertEqual(releases, 0)
        pending = nil
        XCTAssertEqual(releases, 1)
    }

    func testInlineCallbackAndRejectionCannotDoubleRelease() {
        var releases = 0
        RenderCompletionDelivery.schedule(on: { work in work(); return false }, work: {}, release: { releases += 1 })
        XCTAssertEqual(releases, 1)
    }

    func testAcceptedOwnerWorkDrainsAndReleasesBeforeShutdown() {
        let executor = RenderExecutor()
        let completed = DispatchSemaphore(value: 0)
        var invalidatedOnOwner = false
        RenderCompletionDelivery.schedule(on: { executor.perform($0) }, work: {
            invalidatedOnOwner = executor.isCurrent
        }, release: {
            XCTAssertTrue(invalidatedOnOwner)
            completed.signal()
        })
        executor.stop()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    }
}
