// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import CoreVideo
import ScreenCaptureKit
@testable import foldelight

final class CapturedFrameTests: XCTestCase {
    private func buffer() throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &value), kCVReturnSuccess)
        return try XCTUnwrap(value)
    }

    func testNewestPixelsAndTimestampPreserveAllDroppedDamage() throws {
        let mailbox = CaptureMailbox(), stream = NSObject()
        let first = try buffer(), latest = try buffer()
        mailbox.activate(stream)
        XCTAssertTrue(mailbox.put(first, from: stream, displayTime: 1, damage: [CGRect(x: 1, y: 2, width: 3, height: 4)]))
        XCTAssertFalse(mailbox.put(latest, from: stream, displayTime: 2, damage: [CGRect(x: 10, y: 12, width: 4, height: 5)]))
        let sample = try XCTUnwrap(mailbox.takeSample())
        XCTAssertTrue(sample.buffer === latest)
        XCTAssertEqual(sample.displayTime, 2)
        XCTAssertEqual(sample.damage, [CGRect(x: 1, y: 2, width: 13, height: 15)])
        XCTAssertNotNil(sample.generation)
        XCTAssertNil(mailbox.takeSample())
    }

    func testUnknownDamageDominatesBothReplacementOrders() throws {
        let mailbox = CaptureMailbox(), stream = NSObject(), pixels = try buffer()
        let rects: [CGRect]? = [CGRect(x: 2, y: 3, width: 4, height: 5)]
        for (first, next) in [(nil as [CGRect]?, rects), (rects, nil), (nil, [])] {
            mailbox.activate(stream)
            _ = mailbox.put(pixels, from: stream, damage: first)
            _ = mailbox.put(pixels, from: stream, damage: next)
            XCTAssertNil(try XCTUnwrap(mailbox.takeSample()).damage)
        }
    }

    func testEmptyDamageMeansKnownUnchangedRatherThanUnknown() throws {
        XCTAssertEqual(FrameDamage.merging([], []), [])
        let rect = CGRect(x: 2, y: 3, width: 4, height: 5)
        XCTAssertEqual(FrameDamage.merging([], [rect]), [rect])
        XCTAssertEqual(FrameDamage.merging([rect], []), [rect])
        let mailbox = CaptureMailbox(), stream = NSObject(), pixels = try buffer()
        mailbox.activate(stream)
        _ = mailbox.put(pixels, from: stream, displayTime: 4, damage: [])
        _ = mailbox.put(pixels, from: stream, displayTime: 5, damage: [])
        let sample = try XCTUnwrap(mailbox.takeSample())
        XCTAssertEqual(sample.damage, [])
        XCTAssertEqual(sample.displayTime, 5)
    }

    func testRestoreRetainsLatestPixelsAndUnionsFailedFrameDamage() throws {
        let mailbox = CaptureMailbox(), stream = NSObject()
        let old = try buffer(), latest = try buffer()
        mailbox.activate(stream)
        let left = CGRect(x: 1, y: 2, width: 3, height: 4)
        let right = CGRect(x: 10, y: 12, width: 4, height: 5)
        _ = mailbox.put(old, from: stream, displayTime: 1, damage: [left])
        let failed = try XCTUnwrap(mailbox.takeSample())
        _ = mailbox.put(latest, from: stream, displayTime: 2, damage: [right])
        mailbox.restore(failed)
        let retry = try XCTUnwrap(mailbox.takeSample())
        XCTAssertTrue(retry.buffer === latest)
        XCTAssertEqual(retry.displayTime, 2)
        XCTAssertEqual(retry.damage, [left.union(right)])
        mailbox.restore(retry)
        XCTAssertTrue(try XCTUnwrap(mailbox.takeSample()).buffer === latest)
    }

    func testFailedUnknownDamageCannotBecomeKnownAfterNewCapture() throws {
        let mailbox = CaptureMailbox(), stream = NSObject(), pixels = try buffer()
        mailbox.activate(stream)
        _ = mailbox.put(pixels, from: stream, damage: nil)
        let failed = try XCTUnwrap(mailbox.takeSample())
        _ = mailbox.put(pixels, from: stream, damage: [])
        mailbox.restore(failed)
        XCTAssertNil(try XCTUnwrap(mailbox.takeSample()).damage)
    }

    func testStaleRestoreIsRejectedAcrossResetAndSameStreamReactivation() throws {
        let mailbox = CaptureMailbox(), stream = NSObject(), pixels = try buffer()
        mailbox.activate(stream)
        _ = mailbox.put(pixels, from: stream, damage: [])
        let old = try XCTUnwrap(mailbox.takeSample())
        mailbox.reset()
        mailbox.restore(old)
        XCTAssertNil(mailbox.takeSample())
        mailbox.activate(stream)
        mailbox.restore(old)
        XCTAssertNil(mailbox.takeSample())
        _ = mailbox.put(pixels, from: stream, displayTime: 2, damage: [])
        let new = try XCTUnwrap(mailbox.takeSample())
        XCTAssertNotEqual(new.generation, old.generation)
        mailbox.activate(stream)
        mailbox.restore(new)
        XCTAssertNil(mailbox.takeSample())
    }

    func testStaleStreamCannotOverwriteMetadataOrEmitNotification() throws {
        let mailbox = CaptureMailbox(), oldStream = NSObject(), newStream = NSObject(), pixels = try buffer()
        var notifications = 0
        mailbox.observe { notifications += 1 }
        mailbox.activate(oldStream)
        _ = mailbox.put(pixels, from: oldStream, displayTime: 1, damage: nil)
        let old = try XCTUnwrap(mailbox.takeSample())
        mailbox.activate(newStream)
        _ = mailbox.put(pixels, from: newStream, displayTime: 2, damage: [])
        XCTAssertFalse(mailbox.put(pixels, from: oldStream, displayTime: 9, damage: nil))
        mailbox.restore(old)
        let newest = try XCTUnwrap(mailbox.takeSample())
        XCTAssertEqual(newest.displayTime, 2)
        XCTAssertEqual(newest.damage, [])
        XCTAssertEqual(notifications, 2)
        mailbox.restore(CapturedFrame(buffer: pixels, displayTime: 10, damage: nil))
        XCTAssertNil(mailbox.takeSample(), "Unstamped synthetic frames cannot cross the mailbox lifecycle boundary")
    }

    func testCaptureMetadataPreservesBridgedRectanglesAndHostTicks() throws {
        let rectangle = CGRect(x: 4, y: 5, width: 6, height: 7)
        let nsDictionary: NSDictionary = [SCStreamFrameInfo.dirtyRects: [NSValue(rect: rectangle)],
                                        SCStreamFrameInfo.displayTime: NSNumber(value: UInt64(123456789))]
        let info = try XCTUnwrap(nsDictionary as? [SCStreamFrameInfo: Any])
        let result = CaptureMetadata.decode(info)
        XCTAssertEqual(result.damage, [rectangle])
        XCTAssertEqual(result.displayTime, HostClock.seconds(ticks: 123456789))
        XCTAssertEqual(CaptureMetadata.decode([.dirtyRects: [CGRect]()]).damage, [])
        XCTAssertEqual(CaptureMetadata.decode([.dirtyRects: [rectangle]]).damage, [rectangle])
    }

    func testMalformedCaptureMetadataDegradesToUnknown() {
        for value: Any in [NSNumber(value: -1), NSNumber(value: Double.nan), NSNumber(value: 1.5), "ticks"] {
            XCTAssertNil(CaptureMetadata.decode([.displayTime: value]).displayTime)
        }
        for value: Any in ["rectangles", [NSValue(point: CGPoint(x: 1, y: 2))],
                          [NSValue(rect: CGRect(x: 1, y: 2, width: -1, height: 5))]] {
            XCTAssertNil(CaptureMetadata.decode([.dirtyRects: value]).damage)
        }
        XCTAssertNil(CaptureMetadata.decode([:]).damage)
        XCTAssertNil(CaptureMetadata.decode([:]).displayTime)
    }

    func testNonfiniteAndOverflowingDamageAlwaysBecomesUnknown() {
        for rect in [CGRect(x: Double.infinity, y: 0, width: 1, height: 1),
                     CGRect(x: 0, y: 0, width: Double.nan, height: 1),
                     CGRect(x: Double.greatestFiniteMagnitude, y: 0, width: Double.greatestFiniteMagnitude, height: 1)] {
            XCTAssertNil(FrameDamage.merging([], [rect]))
        }
        let low = CGRect(x: -Double.greatestFiniteMagnitude, y: 0, width: 1, height: 1)
        let high = CGRect(x: Double.greatestFiniteMagnitude, y: 0, width: 1, height: 1)
        XCTAssertNil(FrameDamage.merging([low], [high]))
    }

    func testGeneratedDamageUnionMatchesIndependentBoundsAndNilDominance() {
        var state: UInt64 = 0xCA970AED
        for iteration in 0..<10_000 {
            var rects: [CGRect] = []
            for _ in 0..<3 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                rects.append(CGRect(x: Int(state % 1000), y: Int((state >> 16) % 1000),
                                    width: Int((state >> 32) % 100) + 1, height: Int((state >> 48) % 100) + 1))
            }
            let minimumX = rects.map(\.minX).min()!, minimumY = rects.map(\.minY).min()!
            let maximumX = rects.map(\.maxX).max()!, maximumY = rects.map(\.maxY).max()!
            let expected = [CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)]
            let pair = FrameDamage.merging([rects[0]], [rects[1]])
            XCTAssertEqual(FrameDamage.merging(pair, [rects[2]]), expected, "Case \(iteration)")
            XCTAssertEqual(FrameDamage.merging([rects[2]], pair), expected)
            XCTAssertNil(FrameDamage.merging(pair, nil))
            XCTAssertNil(FrameDamage.merging(nil, pair))
        }
    }
}
