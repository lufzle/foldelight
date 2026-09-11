// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class PreciseLidReportTests: XCTestCase {
    func testEveryHundredthRoundTripsAndMalformedReportsFail() {
        for value in 0...36000 {
            let bytes: [UInt8] = [7, UInt8(value & 255), UInt8(value >> 8), 0, 0]
            XCTAssertEqual(LidReportDecoder.preciseAngle(from: bytes), Double(value) / 100)
        }
        XCTAssertEqual(LidReportDecoder.preciseAngle(from: [7, 0x70, 0x2d, 0, 0]), 116.32)
        for bytes: [UInt8] in [[], [7], [7, 0, 0, 0], [7, 0, 0, 0, 0, 0],
                              [1, 0, 0, 0, 0], [7, 0xa1, 0x8c, 0, 0], [7, 0, 0, 1, 0], [7, 0, 0, 0, 1]] {
            XCTAssertNil(LidReportDecoder.preciseAngle(from: bytes), "\(bytes)")
        }
        XCTAssertNil(LidReportDecoder.preciseAngle(from: [7, 0, 0], count: 5))
        XCTAssertNil(LidReportDecoder.preciseAngle(from: [7, 0, 0, 0, 0], count: 4))
        XCTAssertNil(LidReportDecoder.angle(from: [7, 100, 0]))
        XCTAssertNil(LidReportDecoder.angle(from: [1, 100, 0], count: 4))
    }

    func testPrivateFormatRequiresEveryVerifiedCapabilityField() {
        let signature = [0x05ac, 0x8104, 7, 0x20, 0x0545, 0, 36000, 14]
        func supports(_ v: [Int]) -> Bool {
            PreciseLidCapability.supports(vendor: v[0], product: v[1], report: v[2], usagePage: v[3],
                usage: v[4], minimum: v[5], maximum: v[6], exponent: v[7])
        }
        XCTAssertTrue(supports(signature))
        for index in signature.indices {
            var mismatch = signature; mismatch[index] += 1
            XCTAssertFalse(supports(mismatch), "Capability field \(index) must agree")
        }
    }

    func testOpenBracketsMovingSensorAndUsesOneFineReadThereafter() {
        for bracket in [(56.0, 60.0), (60.0, 56.0)] {
            var selection = LidReportSelection()
            var sequence = [(1, bracket.0), (7, 60.42), (1, bracket.1)]
            XCTAssertEqual(selection.open(supportsPrecision: true) { id in
                let next = sequence.removeFirst(); XCTAssertEqual(id, next.0); return next.1
            }, 60.42)
            XCTAssertTrue(selection.usesPrecision)
            var calls: [Int] = []
            XCTAssertEqual(selection.next { id in calls.append(id); return 60.43 }, 60.43)
            XCTAssertEqual(calls, [7])
        }
    }

    func testUnsupportedOrDisagreeingFineReportUsesCoarse() {
        var selection = LidReportSelection()
        var calls: [Int] = []
        XCTAssertEqual(selection.open(supportsPrecision: false) { calls.append($0); return 90 }, 90)
        XCTAssertEqual(calls, [1])
        XCTAssertFalse(selection.usesPrecision)
        for fine: Double? in [nil, 88, 92] {
            XCTAssertEqual(selection.open(supportsPrecision: true) { $0 == 7 ? fine : 90 }, 90)
            XCTAssertFalse(selection.usesPrecision)
        }
        XCTAssertNil(selection.open(supportsPrecision: true) { _ in nil })
        XCTAssertFalse(selection.usesPrecision)
    }

    func testFailedFineReadFallsBackInSameCallAndStaysCoarseUntilReconnect() {
        var selection = LidReportSelection()
        XCTAssertEqual(selection.open(supportsPrecision: true) { $0 == 7 ? 90.25 : 90 }, 90.25)
        var calls: [Int] = []
        XCTAssertEqual(selection.next { id in calls.append(id); return id == 7 ? nil : 89 }, 89)
        XCTAssertEqual(calls, [7, 1])
        XCTAssertFalse(selection.usesPrecision)
        calls = []
        XCTAssertNil(selection.next { id in calls.append(id); return nil })
        XCTAssertEqual(calls, [1])
        XCTAssertEqual(selection.open(supportsPrecision: true) { $0 == 7 ? 89.1 : 89 }, 89.1)
        XCTAssertTrue(selection.usesPrecision)
    }
}
