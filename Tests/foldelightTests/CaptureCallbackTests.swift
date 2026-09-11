// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class CaptureCallbackTests: XCTestCase {
    func testScreenCaptureCallbacksAreVisibleToObjectiveC() {
        MainActor.assumeIsolated {
            let capture = DesktopCapture()
            XCTAssertTrue(capture.responds(to: NSSelectorFromString("stream:didOutputSampleBuffer:ofType:")))
            XCTAssertTrue(capture.responds(to: NSSelectorFromString("stream:didStopWithError:")))
        }
    }
}
