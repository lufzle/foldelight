// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class LidReportTests: XCTestCase {
    func testDecoderUsesLittleEndianWholeDegrees() {
        XCTAssertEqual(LidReportDecoder.angle(from: [1, 100, 0]), 100)
        XCTAssertEqual(LidReportDecoder.angle(from: [1, 0, 1]), 256)
        XCTAssertEqual(LidReportDecoder.angle(from: [1, 104, 1]), 360)
        XCTAssertNil(LidReportDecoder.angle(from: [1, 105, 1]))
        XCTAssertNil(LidReportDecoder.angle(from: [1, 100, 0], count: 2))
        XCTAssertNil(LidReportDecoder.angle(from: []))
    }

    func testDecoderAcceptsEverySupportedAngle() {
        for degrees in 0...360 {
            let report: [UInt8] = [1, UInt8(degrees & 255), UInt8(degrees >> 8), 0, 0, 0, 0, 0]
            XCTAssertEqual(LidReportDecoder.angle(from: report), Double(degrees), "Angle \(degrees)")
        }
    }

    func testSamplingPolicyBoundsRatesAndRequestsStrictZeroLeeway() {
        XCTAssertEqual(SensorSamplingPolicy.rate(requested: 1), 30)
        XCTAssertEqual(SensorSamplingPolicy.rate(requested: 60), 60)
        XCTAssertEqual(SensorSamplingPolicy.rate(requested: 240), 120)
        XCTAssertEqual(SensorSamplingPolicy.leewayNanoseconds, 0)
    }
}
