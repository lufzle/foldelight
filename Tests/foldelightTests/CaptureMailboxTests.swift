// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import CoreVideo
import Foundation
import XCTest
@testable import foldelight

final class CaptureMailboxTests: XCTestCase {
    private func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
                                        kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testInactiveMailboxRejectsFrames() throws {
        let mailbox = CaptureMailbox(), stream = NSObject()
        XCTAssertNil(mailbox.take())
        XCTAssertFalse(mailbox.put(try frame(), from: stream))
        XCTAssertNil(mailbox.take())
    }

    func testLatestFrameWinsAndTakeConsumesIt() throws {
        let mailbox = CaptureMailbox(), stream = NSObject()
        let old = try frame(), latest = try frame()
        mailbox.activate(stream)
        XCTAssertTrue(mailbox.put(old, from: stream))
        XCTAssertFalse(mailbox.put(latest, from: stream))
        XCTAssertTrue(try XCTUnwrap(mailbox.take()) === latest)
        XCTAssertNil(mailbox.take())
        XCTAssertFalse(mailbox.put(old, from: stream), "Taking a frame must not request another first-frame notification")
        XCTAssertTrue(try XCTUnwrap(mailbox.take()) === old)
    }

    func testReplacingStreamClearsPendingFrameAndRejectsStaleStream() throws {
        let mailbox = CaptureMailbox(), old = NSObject(), current = NSObject()
        let staleFrame = try frame(), currentFrame = try frame()
        mailbox.activate(old)
        XCTAssertTrue(mailbox.put(staleFrame, from: old))
        mailbox.activate(current)
        XCTAssertNil(mailbox.take())
        XCTAssertFalse(mailbox.put(staleFrame, from: old))
        XCTAssertNil(mailbox.take())
        XCTAssertTrue(mailbox.put(currentFrame, from: current))
        XCTAssertFalse(mailbox.put(staleFrame, from: old))
        XCTAssertTrue(try XCTUnwrap(mailbox.take()) === currentFrame)
    }

    func testResetClearsFrameAndReactivationRestoresFirstNotification() throws {
        let mailbox = CaptureMailbox(), stream = NSObject(), buffer = try frame()
        mailbox.activate(stream)
        XCTAssertTrue(mailbox.put(buffer, from: stream))
        mailbox.reset()
        XCTAssertNil(mailbox.take())
        XCTAssertFalse(mailbox.put(buffer, from: stream))
        XCTAssertNil(mailbox.take())
        mailbox.activate(stream)
        XCTAssertTrue(mailbox.put(buffer, from: stream))
        mailbox.activate(stream)
        XCTAssertNil(mailbox.take())
        XCTAssertTrue(mailbox.put(buffer, from: stream))
    }

    func testGeneratedOperationsMatchSingleSlotReferenceModel() throws {
        let streams = [NSObject(), NSObject(), NSObject()]
        let frames = try (0..<5).map { _ in try frame() }
        for seed in 1...32 {
            let mailbox = CaptureMailbox()
            var random = UInt64(seed), active: Int?, pending: Int?, notified = false
            for step in 0..<500 {
                random = random &* 6364136223846793005 &+ 1442695040888963407
                let operation = Int((random >> 32) % 4)
                let stream = Int((random >> 16) % 3), value = Int(random % 5)
                let context = "seed=\(seed), step=\(step)"
                switch operation {
                case 0:
                    mailbox.activate(streams[stream])
                    active = stream; pending = nil; notified = false
                case 1:
                    mailbox.reset()
                    active = nil; pending = nil; notified = false
                case 2:
                    let accepted = active == stream
                    XCTAssertEqual(mailbox.put(frames[value], from: streams[stream]), accepted && !notified, context)
                    if accepted { pending = value; notified = true }
                default:
                    let received = mailbox.take()
                    if let pending { XCTAssertTrue(received === frames[pending], context) }
                    else { XCTAssertNil(received, context) }
                    pending = nil
                }
            }
        }
    }

    func testConcurrentProducersNotifyExactlyOnce() throws {
        let mailbox = CaptureMailbox(), stream = NSObject(), stale = NSObject(), buffer = try frame()
        let countLock = NSLock()
        var notifications = 0
        mailbox.activate(stream)
        DispatchQueue.concurrentPerform(iterations: 1000) { iteration in
            let notify = mailbox.put(buffer, from: iteration.isMultiple(of: 3) ? stale : stream)
            if notify { countLock.lock(); notifications += 1; countLock.unlock() }
        }
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(try XCTUnwrap(mailbox.take()) === buffer)
        XCTAssertNil(mailbox.take())
    }

    func testDiagnosticsReflectActiveStreamAndResetWithLifecycle() throws {
        let mailbox = CaptureMailbox(), active = NSObject(), stale = NSObject()
        XCTAssertEqual(mailbox.sampleStatus, "No samples received")
        mailbox.recordStatus("Inactive callback", from: active)
        XCTAssertEqual(mailbox.sampleStatus, "No samples received")
        mailbox.activate(active)
        mailbox.recordStatus("Screen sample status 1 (not complete)", from: active)
        XCTAssertEqual(mailbox.sampleStatus, "Screen sample status 1 (not complete)")
        mailbox.recordStatus("Stale callback", from: stale)
        XCTAssertEqual(mailbox.sampleStatus, "Screen sample status 1 (not complete)")
        XCTAssertTrue(mailbox.put(try frame(), from: active))
        XCTAssertEqual(mailbox.sampleStatus, "Complete screen sample received")
        mailbox.activate(stale)
        XCTAssertEqual(mailbox.sampleStatus, "No samples received")
        mailbox.recordStatus("Late callback", from: active)
        XCTAssertEqual(mailbox.sampleStatus, "No samples received")
        mailbox.recordStatus("Missing status", from: stale)
        mailbox.reset()
        XCTAssertEqual(mailbox.sampleStatus, "No samples received")
        mailbox.recordStatus("Callback after reset", from: stale)
        XCTAssertEqual(mailbox.sampleStatus, "No samples received")
    }

    func testConcurrentLifecycleOperationsLeaveResetMailboxEmpty() throws {
        let mailbox = CaptureMailbox(), stream = NSObject(), buffer = try frame()
        DispatchQueue.concurrentPerform(iterations: 1000) { iteration in
            switch iteration % 4 {
            case 0: mailbox.activate(stream)
            case 1: _ = mailbox.put(buffer, from: stream)
            case 2: _ = mailbox.take()
            default: mailbox.reset()
            }
        }
        mailbox.reset()
        XCTAssertNil(mailbox.take())
        XCTAssertFalse(mailbox.put(buffer, from: stream))
        XCTAssertNil(mailbox.take())
    }
}
