// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import AppKit
import ScreenCaptureKit
@testable import foldelight

final class DesktopCaptureFilterTests: XCTestCase {
    @MainActor
    func testMissingOverlayIsRejected() {
        XCTAssertThrowsError(try DesktopOverlayPolicy.captureWindow(windowNumber: 42, in: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not exclude its own overlay"))
        }
    }

    @MainActor
    func testInvalidWindowNumbersAreRejectedWithoutTrapping() {
        for number in [-1, 0, Int(UInt32.max) + 1] {
            XCTAssertThrowsError(try DesktopOverlayPolicy.captureWindow(windowNumber: number, in: []))
        }
    }

    @MainActor
    func testNativeHiddenOverlayRequiresItsOwnFreshWindowIdentity() async throws {
        try requireNativeCheck()
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("Permission-free current-process enumeration requires macOS 14.4.")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let overlay = try DesktopOverlayPolicy.make(screen: screen, device: nil)
        overlay.panel.isReleasedWhenClosed = false
        defer { overlay.panel.close() }
        XCTAssertFalse(overlay.panel.isVisible)
        let content = try await SCShareableContent.currentProcess
        let window = try DesktopOverlayPolicy.captureWindow(windowNumber: overlay.panel.windowNumber,
                                                             in: content.windows)
        XCTAssertEqual(window.windowID, CGWindowID(overlay.panel.windowNumber))
        XCTAssertEqual(window.owningApplication?.processID, ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(window.isOnScreen)
        XCTAssertThrowsError(try DesktopOverlayPolicy.captureWindow(windowNumber: overlay.panel.windowNumber,
            in: [window], processID: ProcessInfo.processInfo.processIdentifier + 1))

        // A snapshot taken before a replacement panel exists cannot protect it.
        let replacement = try DesktopOverlayPolicy.make(screen: screen, device: nil)
        replacement.panel.isReleasedWhenClosed = false
        defer { replacement.panel.close() }
        XCTAssertThrowsError(try DesktopOverlayPolicy.captureWindow(windowNumber: replacement.panel.windowNumber,
                                                                    in: content.windows))
        let refreshed = try await SCShareableContent.currentProcess
        let replacementWindow = try DesktopOverlayPolicy.captureWindow(windowNumber: replacement.panel.windowNumber,
                                                                        in: refreshed.windows)
        XCTAssertEqual(replacementWindow.windowID, CGWindowID(replacement.panel.windowNumber))
        XCTAssertNotEqual(replacementWindow.windowID, window.windowID)
        XCTAssertFalse(replacement.panel.isVisible)
    }

    /// Captures only a small synthetic patch and keeps every pixel in memory.
    /// No permission prompt appears. All fixture windows close automatically.
    @MainActor
    func testNativeCaptureKeepsOwnWindowsAndExcludesShownOverlay() async throws {
        try requireNativeCheck()
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Native pixel verification requires existing Screen Recording permission.")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32).map {
                CGDisplayIsBuiltin($0) != 0
            } ?? false
        })
        let displayID = try XCTUnwrap(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
        let patch = NSRect(x: screen.frame.midX - 48, y: screen.frame.midY - 48, width: 96, height: 96)
        let overlay = try DesktopOverlayPolicy.make(screen: screen, device: nil)
        overlay.panel.isReleasedWhenClosed = false
        // Keep the two small markers above any effect the user already runs.
        overlay.panel.level = NSWindow.Level(rawValue: overlay.panel.level.rawValue + 2)
        overlay.panel.setFrame(patch, display: false)
        paint(overlay.panel, .init(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        defer { overlay.panel.orderOut(nil); overlay.panel.close() }
        let ownWindow = solidWindow(frame: patch, color: .init(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                                    level: NSWindow.Level(rawValue: overlay.panel.level.rawValue - 1))
        defer { ownWindow.orderOut(nil); ownWindow.close() }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let display = try XCTUnwrap(content.displays.first { $0.displayID == displayID })
        let filtered = try DesktopOverlayPolicy.captureFilter(display: display, excluding: overlay.panel,
                                                              windows: content.windows)
        let unfiltered = SCContentFilter(display: display, excludingWindows: [])
        if #available(macOS 14.2, *) { XCTAssertTrue(filtered.includeMenuBar) }
        XCTAssertEqual(filtered.contentRect, unfiltered.contentRect)
        let configuration = SCStreamConfiguration()
        configuration.width = 96
        configuration.height = 96
        configuration.sourceRect = CGRect(x: patch.minX - screen.frame.minX,
                                          y: screen.frame.maxY - patch.maxY,
                                          width: patch.width, height: patch.height)
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB

        ownWindow.orderFrontRegardless()
        overlay.panel.orderFrontRegardless()
        CATransaction.flush()
        try await expectPixel([255, 0, 0], filter: unfiltered, configuration: configuration,
                              message: "The positive control must actually capture the visible overlay")
        try await expectPixel([0, 0, 255], filter: filtered, configuration: configuration,
                              message: "Only the overlay is excluded; another own window remains captured")

        let windowNumber = overlay.panel.windowNumber
        overlay.panel.orderOut(nil)
        try await expectPixel([0, 0, 255], filter: unfiltered, configuration: configuration,
                              message: "Hiding the overlay reveals the same own window")
        overlay.panel.orderFrontRegardless()
        XCTAssertEqual(overlay.panel.windowNumber, windowNumber)
        try await expectPixel([0, 0, 255], filter: filtered, configuration: configuration,
                              message: "The existing exclusion survives hiding and showing the panel")

        // A settings or menu window created after capture starts must also pass.
        let lateWindow = solidWindow(frame: patch, color: .init(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                                     level: ownWindow.level)
        defer { lateWindow.orderOut(nil); lateWindow.close() }
        lateWindow.orderFrontRegardless()
        try await expectPixel([0, 255, 0], filter: filtered, configuration: configuration,
                              message: "Own windows created after filter construction remain captured")
    }

    private func requireNativeCheck() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_NATIVE_CAPTURE_TEST"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_NATIVE_CAPTURE_TEST=1 for native capture-filter verification.")
        }
    }

    @MainActor
    private func solidWindow(frame: NSRect, color: NSColor, level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = true
        paint(panel, color)
        return panel
    }

    @MainActor
    private func paint(_ panel: NSPanel, _ color: NSColor) {
        panel.backgroundColor = color
        let view = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
        panel.contentView = view
    }

    @MainActor
    private func expectPixel(_ expected: [UInt8], filter: SCContentFilter,
                             configuration: SCStreamConfiguration, message: String,
                             file: StaticString = #filePath, line: UInt = #line) async throws {
        var actual: [UInt8] = []
        // WindowServer can finish a window-order change after the first request.
        for attempt in 0..<10 {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            actual = try centerPixel(image)
            if zip(actual.prefix(3), expected).allSatisfy({ abs(Int($0) - Int($1)) <= 12 }) { return }
            if attempt < 9 { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTFail("\(message): expected RGB \(expected), received RGBA \(actual)", file: file, line: line)
    }

    private func centerPixel(_ image: CGImage) throws -> [UInt8] {
        let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2,
                                                          width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
