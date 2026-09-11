// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class PreviewLidDragTests: XCTestCase {
    func testPressKeepsTheDisplayedAngle() {
        for angle in [0.0, 32, 78, 100, 119.75, 132] {
            var drag = PreviewLidDrag(angle: angle)
            XCTAssertEqual(drag.update(translation: 0, travel: 240), angle)
        }
    }

    func testUpOpensAndDownClosesInProportionToPreviewHeight() {
        var drag = PreviewLidDrag(angle: 60)
        XCTAssertEqual(drag.update(translation: -40, travel: 264), 80)
        XCTAssertEqual(drag.update(translation: 20, travel: 264), 50)
    }

    func testClosingBringsTheLidTowardTheViewerAsTheEffectIncreases() {
        XCTAssertEqual(PreviewLidDrag.hingeRotation(angle: 0), -90)
        XCTAssertEqual(PreviewLidDrag.hingeRotation(angle: 90), 0)
        XCTAssertEqual(PreviewLidDrag.hingeRotation(angle: 132), 42)
        for angle in stride(from: 1.0, through: 132, by: 1) {
            let rotation = PreviewLidDrag.hingeRotation(angle: angle)
            let closingRotation = PreviewLidDrag.hingeRotation(angle: angle - 1)
            XCTAssertLessThan(closingRotation, rotation)
            // The top edge lies above the hinge (negative Y). Rotating it by
            // a more negative angle increases Z, toward the viewer.
            XCTAssertGreaterThan(-sin(closingRotation * .pi / 180), -sin(rotation * .pi / 180))
            XCTAssertGreaterThanOrEqual(EffectSettings.progress(angle: angle - 1, clearAngle: 100),
                EffectSettings.progress(angle: angle, clearAngle: 100))
        }
        XCTAssertEqual(PreviewLidDrag.hingeRotation(angle: 300), 42)
        XCTAssertEqual(PreviewLidDrag.hingeRotation(angle: -100), -90)
    }

    func testRepeatedPointerEventDoesNotMoveTheLidAgain() {
        var drag = PreviewLidDrag(angle: 90)
        XCTAssertEqual(drag.update(translation: 60, travel: 264), 60)
        for _ in 0..<100 {
            XCTAssertEqual(drag.update(translation: 60, travel: 264), 60)
        }
    }

    func testClosingOvershootImmediatelyReverses() {
        var drag = PreviewLidDrag(angle: 78)
        XCTAssertEqual(drag.update(translation: 400, travel: 264), 0)
        XCTAssertEqual(drag.update(translation: 800, travel: 264), 0)
        XCTAssertEqual(drag.update(translation: 799, travel: 264), 0.5)
    }

    func testOpeningOvershootImmediatelyReverses() {
        var drag = PreviewLidDrag(angle: 78)
        XCTAssertEqual(drag.update(translation: -400, travel: 264), 132)
        XCTAssertEqual(drag.update(translation: -800, travel: 264), 132)
        XCTAssertEqual(drag.update(translation: -799, travel: 264), 131.5)
    }

    func testNextGestureContinuesFromHeldAngleWithANewPointerOrigin() {
        var drag = PreviewLidDrag(angle: 105)
        let held = drag.update(translation: 60, travel: 264)
        // Release/cancellation discards the session. The next press can occur
        // anywhere in the stationary hit region, including over a closed lid.
        drag = PreviewLidDrag(angle: held)
        XCTAssertEqual(drag.update(translation: 0, travel: 264), 75)
        XCTAssertEqual(drag.update(translation: -10, travel: 264), 80)
        drag = PreviewLidDrag(angle: 0)
        XCTAssertEqual(drag.update(translation: -10, travel: 264), 5)
    }

    func testArrowKeysDuringADragPreserveItsPointerOrigin() {
        var drag = PreviewLidDrag(angle: 90)
        XCTAssertEqual(drag.update(translation: 60, travel: 264), 60)
        XCTAssertEqual(drag.adjust(by: 5), 65)
        XCTAssertEqual(drag.update(translation: 60, travel: 264), 65)
        XCTAssertEqual(drag.update(translation: 70, travel: 264), 60)
        XCTAssertEqual(drag.adjust(by: -5), 55)
        XCTAssertEqual(drag.update(translation: 60, travel: 264), 60)
    }

    func testInvalidGeometryAndEventsPreserveAngleAndPointerOrigin() {
        var drag = PreviewLidDrag(angle: 90)
        drag.update(translation: 10, travel: 264)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(drag.update(translation: invalid, travel: 264), 85)
            XCTAssertEqual(drag.update(translation: 50, travel: invalid), 85)
        }
        XCTAssertEqual(drag.update(translation: 50, travel: 0), 85)
        XCTAssertEqual(drag.update(translation: 50, travel: -1), 85)
        XCTAssertEqual(drag.update(translation: 20, travel: 264), 80)
    }

    func testInitialAndKeyboardAnglesStayWithinPhysicalLimits() {
        XCTAssertEqual(PreviewLidDrag(angle: -20).angle, 0)
        XCTAssertEqual(PreviewLidDrag(angle: 200).angle, 132)
        XCTAssertEqual(PreviewLidDrag.clamped(130 + 5), 132)
        XCTAssertEqual(PreviewLidDrag.clamped(2 - 5), 0)
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(PreviewLidDrag.angleRange.contains(PreviewLidDrag(angle: invalid).angle))
        }
    }

    func testGeneratedGestureSequencesPreserveBoundsDirectionAndDuplicateEvents() {
        var seed: UInt64 = 0xD12A_6F01
        var drag = PreviewLidDrag(angle: 78)
        var translation = 0.0
        for _ in 0..<10_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let delta = Double(Int((seed >> 32) % 501) - 250)
            let travel = Double(180 + seed % 400)
            let previous = drag.angle
            translation += delta
            let angle = drag.update(translation: translation, travel: travel)
            XCTAssertTrue(angle.isFinite)
            XCTAssertTrue(PreviewLidDrag.angleRange.contains(angle))
            if delta > 0 { XCTAssertLessThanOrEqual(angle, previous) }
            if delta < 0 { XCTAssertGreaterThanOrEqual(angle, previous) }
            XCTAssertEqual(drag.update(translation: translation, travel: travel), angle)
        }
    }

    func testMonotonicMovementIsIndependentOfEventCountAndPreviewScale() {
        for start in stride(from: 0.0, through: 132, by: 5) {
            for distance in stride(from: -400.0, through: 400, by: 20) {
                var oneEvent = PreviewLidDrag(angle: start)
                let expected = oneEvent.update(translation: distance, travel: 240)
                for steps in [2, 7, 30, 120] {
                    var manyEvents = PreviewLidDrag(angle: start)
                    for step in 1...steps {
                        manyEvents.update(translation: distance * Double(step) / Double(steps), travel: 240)
                    }
                    XCTAssertEqual(manyEvents.angle, expected, accuracy: 0.000_000_1)
                }
                var doubledPreview = PreviewLidDrag(angle: start)
                XCTAssertEqual(doubledPreview.update(translation: distance * 2, travel: 480), expected)
            }
        }
    }

    func testDragAnglesDriveTheExistingFadeAndReopenAtTheSamePose() {
        var drag = PreviewLidDrag(angle: 100)
        let closingTranslations = stride(from: 0.0, through: 140, by: 1).map { $0 }
        let closing = closingTranslations.map { translation -> (Double, Double) in
            let angle = drag.update(translation: translation, travel: 264)
            return (angle, FoldBlackout.opacity(angle: angle, clearAngle: 100))
        }
        XCTAssertEqual(closing.first?.1, 0)
        XCTAssertEqual(closing.last?.1, 1)
        XCTAssertTrue(closing.contains { $0.1 > 0 && $0.1 < 1 })
        for (translation, expected) in zip(closingTranslations.reversed(), closing.reversed()) {
            let angle = drag.update(translation: translation, travel: 264)
            XCTAssertEqual(angle, expected.0)
            XCTAssertEqual(FoldBlackout.opacity(angle: angle, clearAngle: 100), expected.1)
        }
    }
}
