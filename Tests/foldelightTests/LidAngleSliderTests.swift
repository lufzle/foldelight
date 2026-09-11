// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class LidAngleSliderTests: XCTestCase {
    private let track = LidAngleTrack(width: 294)

    func testBothHandlesUseTheSameInsetAndPhysicalScale() {
        XCTAssertEqual(track.position(angle: 0), 15)
        XCTAssertEqual(track.position(angle: 66), 147)
        XCTAssertEqual(track.position(angle: 132), 279)
        XCTAssertEqual(track.position(angle: 90), 195)
        for handle in [LidAngleHandle.preview, .activation] {
            var drag = LidAngleSliderDrag(handle: handle, angle: 70)
            XCTAssertEqual(drag.update(translation: 20, track: track), 80)
            XCTAssertEqual(drag.update(translation: -20, track: track), 60)
        }
    }

    func testPressDoesNotJumpToThePointerLocation() {
        for handle in [LidAngleHandle.preview, .activation] {
            for angle in [45.0, 70, 90, 132] {
                var drag = LidAngleSliderDrag(handle: handle, angle: angle)
                XCTAssertEqual(drag.update(translation: 0, track: track), angle)
            }
        }
        var preview = LidAngleSliderDrag(handle: .preview, angle: 71.25)
        XCTAssertEqual(preview.update(translation: 0, track: track), 71.25)
    }

    func testCrossingAndCoincidentAnglesPreserveHandleIdentity() {
        var preview = LidAngleSliderDrag(handle: .preview, angle: 80)
        var activation = LidAngleSliderDrag(handle: .activation, angle: 90)
        XCTAssertEqual(preview.update(translation: 20, track: track), activation.value)
        XCTAssertEqual(preview.update(translation: 40, track: track), 100)
        XCTAssertEqual(activation.value, 90)
        XCTAssertEqual(activation.update(translation: 40, track: track), 110)
        XCTAssertEqual(preview.value, 100)
        XCTAssertEqual(preview.handle, .preview)
        XCTAssertEqual(activation.handle, .activation)
    }

    func testFractionalMotionAccumulatesBeforeActivationRounding() {
        var activation = LidAngleSliderDrag(handle: .activation, angle: 90)
        var preview = LidAngleSliderDrag(handle: .preview, angle: 90)
        for event in 1...7 {
            let translation = Double(event) * 0.25
            XCTAssertEqual(activation.update(translation: translation, track: track), (90 + translation / 2).rounded())
            XCTAssertEqual(preview.update(translation: translation, track: track), 90 + translation / 2)
        }
        XCTAssertEqual(activation.value, 91)
        XCTAssertEqual(preview.value, 90.875)
    }

    func testDuplicatePointerEventsDoNotRepeatMovement() {
        for handle in [LidAngleHandle.preview, .activation] {
            var drag = LidAngleSliderDrag(handle: handle, angle: 75)
            for _ in 0..<100 {
                XCTAssertEqual(drag.update(translation: 20, track: track), 85)
            }
        }
    }

    func testBothLimitsAllowImmediateReversalAfterOvershoot() {
        for handle in [LidAngleHandle.preview, .activation] {
            var drag = LidAngleSliderDrag(handle: handle, angle: 90)
            XCTAssertEqual(drag.update(translation: 800, track: track), 132)
            XCTAssertEqual(drag.update(translation: 1600, track: track), 132)
            XCTAssertEqual(drag.update(translation: 1598, track: track), 131)
            XCTAssertEqual(drag.update(translation: -800, track: track), handle.range.lowerBound)
            XCTAssertEqual(drag.update(translation: -1600, track: track), handle.range.lowerBound)
            XCTAssertEqual(drag.update(translation: -1598, track: track), handle.range.lowerBound + 1)
        }
    }

    func testKeyboardAdjustmentDuringDragRetainsPointerBaseline() {
        for handle in [LidAngleHandle.preview, .activation] {
            var drag = LidAngleSliderDrag(handle: handle, angle: 90)
            XCTAssertEqual(drag.update(translation: 20, track: track), 100)
            drag.setValue(101)
            XCTAssertEqual(drag.update(translation: 20, track: track), 101)
            XCTAssertEqual(drag.update(translation: 22, track: track), 102)
            drag.setValue(99)
            XCTAssertEqual(drag.update(translation: 20, track: track), 98)
        }
    }

    func testInvalidEventsAndGeometryDoNotChangeAngleOrBaseline() {
        for handle in [LidAngleHandle.preview, .activation] {
            var drag = LidAngleSliderDrag(handle: handle, angle: 90)
            XCTAssertEqual(drag.update(translation: 20, track: track), 100)
            for invalid in [Double.nan, .infinity, -.infinity] {
                XCTAssertNil(drag.update(translation: invalid, track: track))
            }
            for width in [Double.nan, .infinity, -.infinity, -100, 0, 29, 30] {
                let invalidTrack = LidAngleTrack(width: width)
                XCTAssertEqual(invalidTrack.travel, 0)
                XCTAssertNil(drag.update(translation: 100, track: invalidTrack))
            }
            XCTAssertNil(drag.update(translation: .greatestFiniteMagnitude, track: LidAngleTrack(width: 31)))
            XCTAssertEqual(drag.value, 100)
            XCTAssertEqual(drag.update(translation: 40, track: track), 110)
        }
    }

    func testNewGestureStartsAtTheHeldValue() {
        for handle in [LidAngleHandle.preview, .activation] {
            var drag = LidAngleSliderDrag(handle: handle, angle: 90)
            XCTAssertEqual(drag.update(translation: -40, track: track), 70)
            drag = LidAngleSliderDrag(handle: handle, angle: drag.value)
            XCTAssertEqual(drag.update(translation: 0, track: track), 70)
            XCTAssertEqual(drag.update(translation: 10, track: track), 75)
        }
    }

    func testInitialAndKeyboardValuesRespectEachHandleRange() {
        for handle in [LidAngleHandle.preview, .activation] {
            for angle in [-100.0, 0, 44, 45, 90, 132, 133, 135, 1000] {
                let expected = min(132, max(handle == .preview ? 0 : 45, angle))
                var drag = LidAngleSliderDrag(handle: handle, angle: angle)
                XCTAssertEqual(drag.value, expected)
                drag.setValue(90)
                drag.setValue(angle)
                XCTAssertEqual(drag.value, expected)
            }
            for invalid in [Double.nan, .infinity, -.infinity] {
                XCTAssertEqual(LidAngleSliderDrag(handle: handle, angle: invalid).value, handle == .preview ? 132 : 90)
            }
        }
    }

    func testMovementIsIndependentOfEventCountAndTrackScale() {
        for handle in [LidAngleHandle.preview, .activation] {
            for start in [45.125, 64.125, 104.125, 131.125] {
                for distance in stride(from: -300.0, through: 300, by: 7) {
                    let raw = min(132, max(handle == .preview ? 0 : 45, start + distance / 2))
                    let expected = handle == .preview ? raw : raw.rounded()
                    for count in [1, 7, 60] {
                        var drag = LidAngleSliderDrag(handle: handle, angle: start)
                        for event in 1...count {
                            _ = drag.update(translation: distance * Double(event) / Double(count), track: track)
                        }
                        XCTAssertEqual(drag.value, expected, accuracy: 1e-8)
                    }
                    var wider = LidAngleSliderDrag(handle: handle, angle: start)
                    _ = wider.update(translation: distance * 2, track: LidAngleTrack(width: 558))
                    XCTAssertEqual(wider.value, expected, accuracy: 1e-8)
                }
            }
        }
    }

    func testGeneratedMotionPreservesBoundsDirectionAndDuplicates() {
        var seed: UInt64 = 0x51_1DEA_96
        for handle in [LidAngleHandle.preview, .activation] {
            var drag = LidAngleSliderDrag(handle: handle, angle: 90)
            var translation = 0.0
            for _ in 0..<10_000 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let delta = Double(Int((seed >> 32) % 1001) - 500) / 4
                let varyingTrack = LidAngleTrack(width: Double(100 + seed % 700))
                let before = drag.value
                translation += delta
                guard let angle = drag.update(translation: translation, track: varyingTrack) else {
                    return XCTFail("Valid geometry and finite movement must produce an angle")
                }
                XCTAssertTrue(handle.range.contains(angle))
                if delta > 0 { XCTAssertGreaterThanOrEqual(angle, before) }
                if delta < 0 { XCTAssertLessThanOrEqual(angle, before) }
                XCTAssertEqual(drag.update(translation: translation, track: varyingTrack), angle)
                XCTAssertEqual(drag.handle, handle)
            }
        }
    }

    func testLegacyActivationAboveMaximumOpeningNormalizesWithoutChangingOtherSettings() throws {
        for angle in [132.0, 133, 134, 135] {
            let encoded = try JSONEncoder().encode(EffectSettings(blur: 0.7, shadow: 0.2, clearAngle: angle))
            var restored = try JSONDecoder().decode(EffectSettings.self, from: encoded)
            restored.sanitize()
            XCTAssertEqual(restored.clearAngle, 132)
            XCTAssertEqual(restored.blur, 0.7)
            XCTAssertEqual(restored.shadow, 0.2)
            XCTAssertEqual(LidAngleHandle.activation.bounded(restored.clearAngle), restored.clearAngle)
        }
    }
}
