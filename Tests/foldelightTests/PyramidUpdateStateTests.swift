// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class PyramidUpdateStateTests: XCTestCase {
    func testSharpSubmissionPreservesChangesUntilBlurReturns() {
        var state = PyramidUpdateState()
        state.didSubmit(usedPyramid: true)
        state.accept([CGRect(x: 1, y: 2, width: 3, height: 4)])
        state.didSubmit(usedPyramid: false)
        state.accept([CGRect(x: 10, y: 12, width: 3, height: 4)])
        XCTAssertTrue(state.needsRefresh)
        XCTAssertEqual(state.damage, [CGRect(x: 1, y: 2, width: 12, height: 14)])
        state.invalidate()
        XCTAssertNil(state.damage)
        state.accept([])
        XCTAssertNil(state.damage, "A late failure must force a full rebuild of even a newer capture")
    }

    func testFiftyThousandCaptureAndSubmissionEventsRetainRequiredPixels() {
        var random: UInt64 = 0xaf82_4981
        func next(_ limit: Int) -> Int {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Int((random >> 32) % UInt64(limit))
        }
        var state = PyramidUpdateState()
        var unknown = true, pending = true
        var required = Set<Int>()
        var visits = [Int](repeating: 0, count: 8)
        var sharpWithPending = 0, accumulated = 0
        for _ in 0..<50_000 {
            let event = next(visits.count)
            visits[event] += 1
            switch event {
            case 0, 1:
                if pending { accumulated += 1 }
                let x = next(32), y = next(24)
                let width = 1 + next(32 - x), height = 1 + next(24 - y)
                state.accept([CGRect(x: x, y: y, width: width, height: height)])
                for row in y..<(y + height) {
                    for column in x..<(x + width) { required.insert(row * 32 + column) }
                }
                pending = true
            case 2:
                state.accept(nil)
                unknown = true; pending = true
            case 3:
                if pending { sharpWithPending += 1 }
                state.didSubmit(usedPyramid: false)
            case 4:
                state.didSubmit(usedPyramid: true)
                unknown = false; pending = false; required.removeAll(keepingCapacity: true)
            case 5, 7:
                // Encoder/GPU failure and renderer reset invalidate the cache.
                state.invalidate()
                unknown = true; pending = true
            default:
                // Rejected mapping or busy submission cannot consume damage.
                break
            }
            XCTAssertEqual(state.needsRefresh, pending)
            if unknown {
                XCTAssertNil(state.damage)
            } else if required.isEmpty {
                XCTAssertEqual(state.damage, [])
            } else {
                // Independent pixel-set oracle, without CGRect.union or the
                // production FrameDamage merger.
                let xs = required.map { $0 % 32 }, ys = required.map { $0 / 32 }
                let left = xs.min()!, top = ys.min()!
                let expected = CGRect(x: left, y: top,
                    width: xs.max()! - left + 1, height: ys.max()! - top + 1)
                XCTAssertEqual(state.damage, [expected])
            }
        }
        XCTAssertTrue(visits.allSatisfy { $0 > 5_000 })
        XCTAssertGreaterThan(sharpWithPending, 3_000)
        XCTAssertGreaterThan(accumulated, 8_000)
    }
}
