// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import MetalKit
import ScreenCaptureKit

/// Shared by live capture and native presentation experiments so their window
/// level and full-display geometry cannot silently diverge.
@MainActor
enum DesktopOverlayPolicy {
    struct Surface {
        let panel: NSPanel
        let view: MTKView
        let layer: CAMetalLayer
    }

    static func make(screen: NSScreen, device: MTLDevice?) throws -> Surface {
        let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        view.preferredFramesPerSecond = screen.maximumFramesPerSecond
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.delegate = nil
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.contentView = view
        guard let layer = view.layer as? CAMetalLayer else { throw BendRenderer.RenderError.unavailable }
        // Supply complete backing dimensions before the hidden window first
        // presents; MTKView may defer propagating drawableSize to its layer.
        layer.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                    height: screen.frame.height * screen.backingScaleFactor)
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        layer.displaySyncEnabled = true
        return Surface(panel: panel, view: view, layer: layer)
    }

    static func includeWholeDisplay(in filter: SCContentFilter) {
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
    }

    /// Never start a stream with an unverified exclusion. The same panel stays
    /// alive for the stream's lifetime, including while the effect is hidden.
    static func captureFilter(display: SCDisplay, excluding panel: NSPanel,
                              windows: [SCWindow]) throws -> SCContentFilter {
        let window = try captureWindow(windowNumber: panel.windowNumber, in: windows)
        let filter = SCContentFilter(display: display, excludingWindows: [window])
        includeWholeDisplay(in: filter)
        return filter
    }

    static func captureWindow(windowNumber: Int, in windows: [SCWindow],
                              processID: pid_t = ProcessInfo.processInfo.processIdentifier) throws -> SCWindow {
        guard let windowID = CGWindowID(exactly: windowNumber), windowID != kCGNullWindowID,
              let window = windows.first(where: {
                  $0.windowID == windowID && $0.owningApplication?.processID == processID
              }) else {
            throw DesktopCapture.CaptureError.message("foldelight could not exclude its own overlay from capture. Relaunch the app and try again.")
        }
        return window
    }
}
