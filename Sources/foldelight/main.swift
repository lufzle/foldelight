// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import SwiftUI
import Metal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let model = AppModel()
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var localKeyMonitor: Any?
    let diagnosticRecorder = DiagnosticRecorder()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: "debugLogging") { DebugLog.shared.setEnabled(true) }
        DebugLog.log("Application launched")
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(); appMenu.delegate = self
        addItem("Settings…", action: #selector(showSettings), to: appMenu, key: ",")
        appMenu.addItem(.separator())
        addItem("Quit foldelight", action: #selector(quit), to: appMenu, key: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
        let menu = NSMenu(); menu.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = FoldingIcon.menuBarImage()
        statusItem?.button?.toolTip = "foldelight · Desktop lid effects"
        statusItem?.menu = menu
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.model.pause(); return nil
            }
            return event
        }
        showSettings()
    }

    @objc func showSettings() {
        model.section = "Settings"
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.delegate = self
            window.title = "foldelight"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.backgroundColor = NSColor(red: 41.0 / 255, green: 43.0 / 255, blue: 48.0 / 255, alpha: 1)
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: model.lidAngle.map { "foldelight · \(Int($0))°" } ?? "foldelight · Sensor unavailable", action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        addItem(model.enabled || model.starting ? "Pause foldelight" : "Enable foldelight", action: #selector(toggle), to: menu)
        addItem("Settings…", action: #selector(showSettings), to: menu, key: ",")
        let test = addItem("Test desktop for 4 seconds", action: #selector(testDesktop), to: menu)
        test.isEnabled = model.enabled && !model.testing
        menu.addItem(.separator())
        let debug = addItem("Debug", action: #selector(toggleDebug), to: menu)
        debug.state = DebugLog.shared.enabled ? .on : .off
        let logs = addItem("Open Debug Logs…", action: #selector(openDebugLogs), to: menu)
        logs.isEnabled = FileManager.default.fileExists(atPath: DebugLog.shared.folder.path)
        addItem(diagnosticRecorder.active ? "Stop diagnostic recording" : "Record 15-second diagnostic…", action: #selector(toggleDiagnosticRecording), to: menu)
        menu.addItem(.separator())
        addItem("Quit foldelight", action: #selector(quit), to: menu, key: "q")
    }
    @discardableResult private func addItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item); return item
    }
    @objc func toggleDebug() {
        let requested = !DebugLog.shared.enabled
        if DebugLog.shared.setEnabled(requested) {
            UserDefaults.standard.set(requested, forKey: "debugLogging")
            if requested { DebugLog.log("State: enabled=%d starting=%d lid=%@ sensor=%@", model.enabled, model.starting, model.lidAngle.map(String.init(describing:)) ?? "unavailable", model.sensorStatus) }
        } else {
            let alert = NSAlert()
            alert.messageText = "Debug logging could not start"
            alert.informativeText = DebugLog.shared.lastError ?? "The temporary folder is unavailable."
            alert.runModal()
        }
    }
    @objc func toggleDiagnosticRecording() {
        if diagnosticRecorder.active { diagnosticRecorder.stop() }
        else { diagnosticRecorder.start() }
    }
    @objc func openDebugLogs() { NSWorkspace.shared.open(DebugLog.shared.folder) }
    @objc func toggle() { model.toggle() }
    @objc func testDesktop() { model.testDesktop() }
    @objc func quit() { model.pause(); NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { DebugLog.log("Application terminating normally"); model.pause() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
}

if CommandLine.arguments.contains("--diagnose") {
    let sensor = LidSensor(); sensor.start()
    print("Sensor: \(sensor.status)")
    print("Lid angle: \(sensor.readOnce().map { String($0) } ?? "unavailable")")
    sensor.stop()
    if let device = MTLCreateSystemDefaultDevice() {
        do { _ = try BendRenderer(device: device); print("Metal pipeline: ready (\(device.name))") }
        catch { print("Metal pipeline: \(error)"); exit(1) }
    } else { print("Metal: unavailable"); exit(1) }
    print("Screen Recording already granted: \(CGPreflightScreenCaptureAccess())")
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
