// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
@testable import foldelight

final class PreviewLifecycleTests: XCTestCase {
    private var base: PreviewFrameInputs {
        PreviewFrameInputs(angle: 72, settings: EffectSettings(), geometry: PreviewGeometry(
            displayID: 1, screenWidth: 1512, backingScale: 2,
            drawableWidth: 850, drawableHeight: 531, refreshRate: 120))
    }

    func testAcceptedFinalFrameSleepsThenAsynchronousFailureRetries() {
        var state = PreviewPlaybackState()
        XCTAssertTrue(state.configure(base, sourcePixelWidth: 1920))
        var submissions = 0
        let successfulSubmission = { submissions += 1; return true }
        state.submit(settled: true, using: successfulSubmission)
        XCTAssertFalse(state.isRunning)
        state.submit(settled: true, using: successfulSubmission)
        XCTAssertEqual(submissions, 1, "An unchanged settled preview does not continuously submit")
        // Simulates the renderer completion callback arriving after CPU submission.
        state.submissionFailed()
        XCTAssertTrue(state.isRunning)
        state.submit(settled: true, using: successfulSubmission)
        XCTAssertEqual(submissions, 2)
        XCTAssertFalse(state.isRunning)
    }

    func testRejectedSubmissionStaysRunningUntilAccepted() {
        var state = PreviewPlaybackState()
        state.configure(base, sourcePixelWidth: 1920)
        state.submit(settled: true) { false }
        XCTAssertTrue(state.isRunning)
        state.submit(settled: false) { true }
        XCTAssertTrue(state.isRunning)
        state.submit(settled: true) { true }
        XCTAssertFalse(state.isRunning)
    }

    func testDismantledPreviewRejectsLateFailureAndSubmission() {
        var state = PreviewPlaybackState()
        state.configure(base, sourcePixelWidth: 1920)
        state.dismantle()
        state.submissionFailed()
        var calls = 0
        state.submit(settled: true) { calls += 1; return true }
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(state.isRunning)
        XCTAssertNil(state.inputs)
    }

    func testEveryGeometryDimensionInvalidatesSettledPreview() {
        let edits: [(inout PreviewGeometry) -> Void] = [
            { $0.displayID += 1 }, { $0.screenWidth += 1 }, { $0.backingScale = 1 },
            { $0.drawableWidth += 1 }, { $0.drawableHeight += 1 }, { $0.refreshRate = 60 }
        ]
        for edit in edits {
            var state = PreviewPlaybackState()
            state.configure(base, sourcePixelWidth: 1920)
            state.submit(settled: true) { true }
            XCTAssertFalse(state.configure(base, sourcePixelWidth: 1920))
            XCTAssertFalse(state.isRunning)
            var changed = base
            edit(&changed.geometry)
            XCTAssertTrue(state.configure(changed, sourcePixelWidth: 1920))
            XCTAssertTrue(state.isRunning)
        }
    }

    func testGeneratedSubmissionAndLifecycleEventsMatchReference() {
        var state = PreviewPlaybackState()
        var expectedInputs: PreviewFrameInputs?
        var expectedRunning = false
        var seed: UInt64 = 0xCAFE_F01D
        for _ in 0..<10_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            switch (seed >> 32) % 5 {
            case 0:
                var inputs = base
                inputs.geometry.drawableWidth += Double(seed % 3)
                let changed = inputs != expectedInputs
                XCTAssertEqual(state.configure(inputs, sourcePixelWidth: 1920), changed)
                if changed { expectedInputs = inputs; expectedRunning = true }
            case 1:
                state.dismantle(); expectedInputs = nil; expectedRunning = false
            case 2:
                state.submissionFailed()
                if expectedInputs != nil { expectedRunning = true }
            default:
                let accepted = seed & 1 == 1
                let settled = seed & 2 == 2
                var submissionCalls = 0
                state.submit(settled: settled) { submissionCalls += 1; return accepted }
                XCTAssertEqual(submissionCalls, expectedRunning ? 1 : 0)
                if expectedRunning && accepted && settled { expectedRunning = false }
            }
            XCTAssertEqual(state.isRunning, expectedRunning)
            XCTAssertEqual(state.inputs, expectedInputs)
        }
    }

    func testBackendClockReconfiguresForMigrationButNotControlChangesOrMissingSource() {
        var state = PreviewPlaybackState()
        var configuredScreens: [PreviewGeometry] = []
        let configure = { configuredScreens.append($0) }
        XCTAssertFalse(state.configure(base, sourcePixelWidth: nil, configureClock: configure))
        XCTAssertTrue(configuredScreens.isEmpty)
        XCTAssertNil(state.inputs)
        XCTAssertTrue(state.configure(base, sourcePixelWidth: 1920, configureClock: configure))
        var controls = base
        controls.angle = 40
        XCTAssertTrue(state.configure(controls, sourcePixelWidth: 1920, configureClock: configure))
        XCTAssertEqual(configuredScreens.count, 1)
        var migrated = controls
        migrated.geometry.displayID = 2
        migrated.geometry.backingScale = 1
        migrated.geometry.refreshRate = 60
        XCTAssertFalse(state.configure(migrated, sourcePixelWidth: nil, configureClock: configure))
        XCTAssertEqual(configuredScreens.count, 1)
        XCTAssertTrue(state.configure(migrated, sourcePixelWidth: 1920, configureClock: configure))
        XCTAssertEqual(configuredScreens, [base.geometry, migrated.geometry])
    }

    func testPixelScaleTracksActualSourcePixelsAcrossGeneratedDisplays() {
        for sourceWidth in stride(from: 320, through: 3840, by: 160) {
            for pointWidth in stride(from: 640, through: 3200, by: 160) {
                var geometry = base.geometry
                geometry.screenWidth = Double(pointWidth)
                let scale = geometry.pixelScale(sourcePixelWidth: sourceWidth)
                XCTAssertEqual(Double(scale) * Double(pointWidth), Double(sourceWidth), accuracy: 0.001)
                XCTAssertEqual(geometry.pixelScale(sourcePixelWidth: sourceWidth * 2), scale * 2)
            }
        }
    }
}

final class PreviewArtworkScaleTests: XCTestCase {
    @MainActor
    func testBundledArtworkRetainsNativePixelsAtLogicalPreviewSize() throws {
        let image = try PreviewArtwork.image()
        let bitmap = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(image.size.width, 960)
        XCTAssertEqual(image.size.height, 600)
        XCTAssertEqual(bitmap.width, 1586)
        XCTAssertEqual(bitmap.height, 992)
        for backingScale in [1.0, 2.0] {
            let geometry = PreviewGeometry(displayID: 1, screenWidth: 1512,
                backingScale: backingScale, drawableWidth: 425 * backingScale,
                drawableHeight: 266 * backingScale, refreshRate: 120)
            let scale = geometry.pixelScale(sourcePixelWidth: bitmap.width)
            XCTAssertEqual(Double(scale), 1586.0 / 1512, accuracy: 0.000_001)
            XCTAssertNotEqual(scale, geometry.pixelScale(sourcePixelWidth: Int(image.size.width)))
        }
    }
}
