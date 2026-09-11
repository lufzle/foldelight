// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
import ScreenCaptureKit
@testable import foldelight

final class DesktopOverlayPolicyTests: XCTestCase {
    @MainActor
    func testActualOverlayCoversFullScreenAboveMenuBar() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        })
        let overlay = try DesktopOverlayPolicy.make(screen: screen, device: nil)
        overlay.panel.isReleasedWhenClosed = false
        defer { overlay.panel.close() }
        XCTAssertEqual(overlay.panel.frame, screen.frame)
        XCTAssertEqual(overlay.view.frame, NSRect(origin: .zero, size: screen.frame.size))
        XCTAssertEqual(overlay.view.bounds.size, screen.frame.size)
        XCTAssertGreaterThan(overlay.panel.level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertGreaterThan(overlay.panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
        XCTAssertTrue(overlay.panel.frame.contains(screen.visibleFrame))
        XCTAssertTrue(overlay.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(overlay.panel.ignoresMouseEvents)
        XCTAssertFalse(overlay.panel.hasShadow)
        XCTAssertTrue(overlay.panel.isOpaque)
        XCTAssertEqual(overlay.panel.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
    }

    @MainActor
    func testActualOverlayDrawableUsesWholeRetinaFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let overlay = try DesktopOverlayPolicy.make(screen: screen, device: nil)
        overlay.panel.isReleasedWhenClosed = false
        defer { overlay.panel.close() }
        overlay.view.layoutSubtreeIfNeeded()
        let expected = NSSize(width: screen.frame.width * screen.backingScaleFactor,
                              height: screen.frame.height * screen.backingScaleFactor)
        XCTAssertEqual(overlay.view.drawableSize, expected)
        XCTAssertEqual(overlay.layer.drawableSize, expected)
        XCTAssertEqual(overlay.view.preferredFramesPerSecond, screen.maximumFramesPerSecond)
        XCTAssertTrue(overlay.view.isPaused)
        XCTAssertFalse(overlay.view.enableSetNeedsDisplay)
        XCTAssertTrue(overlay.layer.framebufferOnly)
        XCTAssertFalse(overlay.layer.presentsWithTransaction)
        XCTAssertTrue(overlay.layer.displaySyncEnabled)
    }

    @MainActor
    func testCapturePolicyExplicitlyEnablesMenuBar() throws {
        guard #available(macOS 14.2, *) else { throw XCTSkip("The menu-bar property requires macOS14.2") }
        let filter = SCContentFilter()
        filter.includeMenuBar = false
        DesktopOverlayPolicy.includeWholeDisplay(in: filter)
        XCTAssertTrue(filter.includeMenuBar)
    }
}
