// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class EffectTests: XCTestCase {
    func testProjectionUsesLidDisplacementAndStopsBeforeGrazing() {
        XCTAssertEqual(EffectSettings.tiltRadians(angle: 80, clearAngle: 100), 20 * .pi / 180, accuracy: 1e-12)
        XCTAssertEqual(EffectSettings.tiltRadians(angle: 70, clearAngle: 90), 20 * .pi / 180, accuracy: 1e-12)
        for angle in [100.0, 130, .nan, .infinity] {
            XCTAssertEqual(EffectSettings.tiltRadians(angle: angle, clearAngle: 100), 0)
        }
        XCTAssertEqual(EffectSettings.tiltRadians(angle: 0, clearAngle: 0), 0)
        var previous = 0.0
        for angle in stride(from: 140.0, through: -100, by: -0.25) {
            let tilt = EffectSettings.tiltRadians(angle: angle, clearAngle: 100)
            XCTAssertGreaterThanOrEqual(tilt, previous)
            XCTAssertLessThan(tilt, atan(2 / 0.7))
            previous = tilt
        }
        XCTAssertEqual(previous, 68 * .pi / 180, accuracy: 1e-12)
    }
    func testDefaultsUseRequestedBlurVignetteAndActivation() {
        let settings = EffectSettings()
        XCTAssertEqual(settings.blur, 0.9)
        XCTAssertEqual(settings.shadow, 0.5)
        XCTAssertEqual(settings.clearAngle, 90)
        for angle in stride(from: 90.0, through: 132, by: 0.25) {
            XCTAssertEqual(EffectSettings.progress(angle: angle, clearAngle: settings.clearAngle), 0)
            XCTAssertEqual(EffectSettings.tiltRadians(angle: angle, clearAngle: settings.clearAngle), 0)
        }
        XCTAssertGreaterThan(EffectSettings.progress(angle: 89.9, clearAngle: settings.clearAngle), 0)
        XCTAssertGreaterThan(EffectSettings.tiltRadians(angle: 89.9, clearAngle: settings.clearAngle), 0)
    }

    func testOpenLidAndInvalidInputNeverBend() {
        for angle in [105.0, 120, 360, .infinity, .nan] {
            XCTAssertEqual(EffectSettings.progress(angle: angle, clearAngle: 105), 0)
        }
        XCTAssertEqual(EffectSettings.progress(angle: 50, clearAngle: 0), 0)
    }
    func testClosingLidIncreasesEffectWithinBounds() {
        var previous = 0.0
        for angle in stride(from: 135.0, through: 0, by: -0.5) {
            let progress = EffectSettings.progress(angle: angle, clearAngle: 105)
            XCTAssertGreaterThanOrEqual(progress, previous)
            XCTAssertTrue((0...1).contains(progress))
            previous = progress
        }
        XCTAssertEqual(previous, 1)
        XCTAssertEqual(EffectSettings.progress(angle: -1, clearAngle: 105), 1)
    }
    func testSettingsRoundTripAndSanitization() throws {
        var settings = EffectSettings(blur: 0.3, shadow: 0.9, clearAngle: 90)
        XCTAssertEqual(try JSONDecoder().decode(EffectSettings.self, from: JSONEncoder().encode(settings)), settings)
        let legacy = Data(#"{"style":"Frost","perspective":0.7,"blur":0.3,"shadow":0.9,"clearAngle":90,"sound":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EffectSettings.self, from: legacy), settings)
        settings.blur = 3; settings.shadow = -2; settings.clearAngle = 0
        settings.sanitize()
        XCTAssertEqual(settings.blur, 1)
        XCTAssertEqual(settings.shadow, 0)
        XCTAssertEqual(settings.clearAngle, 45)
    }
}
