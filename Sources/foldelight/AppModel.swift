// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: EffectSettings {
        didSet {
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "effectSettings") }
            capture.settings = settings
        }
    }
    @Published private(set) var lidAngle: Double?
    @Published private(set) var sensorStatus = "Connecting to the lid sensor…"
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published private(set) var status = "Ready when you are"
    @Published private(set) var error: String?
    @Published var previewAngle = 78.0
    @Published var followLid = false
    @Published var section = "Settings"
    @Published private(set) var testing = false
    private var currentLidAngle: Double?
    private var lastLidPublication = 0.0
    private var telemetryPending = false
    private let sensor = LidSensor()
    private let capture = DesktopCapture()
    private var operation = 0
    private let previewClock = FrameClock()
    private let desktopClock = FrameClock()
    private var observers: [NSObjectProtocol] = []

    init() {
        var saved = UserDefaults.standard.data(forKey: "effectSettings")
            .flatMap { try? JSONDecoder().decode(EffectSettings.self, from: $0) } ?? EffectSettings()
        saved.sanitize()
        settings = saved
        capture.settings = saved
        capture.onFailure = { [weak self] message in self?.fail(message) }
        capture.onFrame = { [weak self] in self?.status = "Following your lid" }
        let capture = capture
        sensor.onSample = { [weak capture] angle, readStartedAt, sampledAt in
            capture?.submitAngle(angle, readStartedAt: readStartedAt, sampledAt: sampledAt)
        }
        sensor.onChange = { [weak self] angle in
            guard let self else { return }
            self.currentLidAngle = angle
            if !self.testing { self.capture.angle = angle ?? self.settings.clearAngle }
            self.publishLidTelemetry()
            if self.sensorStatus != self.sensor.status { self.sensorStatus = self.sensor.status; DebugLog.log("Sensor: %@", self.sensor.status) }
            if angle == nil, self.enabled || self.starting { self.fail(self.sensor.status) }
        }
        sensor.start()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in DebugLog.log("System sleep"); self?.pause(); self?.sensor.stop() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in DebugLog.log("Session deactivated"); self?.pause() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in DebugLog.log("System wake"); self?.sensor.stop(); self?.sensor.start() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled || self.starting else { return }
                guard self.capture.displayConfigurationChanged() else { return }
                DebugLog.log("Display configuration changed")
                self.pause()
                self.status = "Display changed. Enable foldelight to reconnect."
            }
        })
    }

    // Numeric settings telemetry must not invalidate the whole SwiftUI tree at
    // the sensor rate. Live capture always receives the freshest value first.
    private func publishLidTelemetry() {
        let now = CACurrentMediaTime()
        if currentLidAngle == nil || lidAngle == nil {
            if lidAngle != currentLidAngle { lidAngle = currentLidAngle }
            lastLidPublication = now
        } else if !telemetryPending {
            telemetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 0.1 - (now - lastLidPublication))) { [weak self] in
                guard let self else { return }
                self.telemetryPending = false
                if self.lidAngle != self.currentLidAngle { self.lidAngle = self.currentLidAngle }
                self.lastLidPublication = CACurrentMediaTime()
            }
        }
    }

    var displayedAngle: Double { followLid ? (lidAngle ?? settings.clearAngle) : previewAngle }

    func enable() {
        DebugLog.log("Enable requested")
        guard !enabled, !starting else { return }
        error = nil
        sensor.stop()
        sensor.start()
        guard currentLidAngle != nil else { error = sensorStatus; return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            error = "Allow foldelight in System Settings → Privacy & Security → Screen & System Audio Recording. Then reopen foldelight if macOS requests it."
            status = "Screen Recording permission needed"
            return
        }
        operation += 1
        let token = operation
        starting = true
        status = "Connecting to your desktop…"
        Task {
            guard operation == token else { return }
            do {
                try await capture.start()
                guard operation == token else { return }
                guard currentLidAngle != nil else { fail(sensorStatus); return }
                starting = false
                enabled = true
                capture.angle = currentLidAngle ?? settings.clearAngle
                if status == "Connecting to your desktop…" { status = "Waiting for the first desktop frame…" }
            } catch {
                guard operation == token else { return }
                fail(error.localizedDescription)
            }
        }
    }

    func pause() {
        DebugLog.log("Effect paused")
        operation += 1
        desktopClock.stop()
        testing = false
        capture.tracksDirectSensorInput = true
        starting = false
        enabled = false
        capture.cancel()
        status = "Paused · your desktop is clear"
    }

    private func fail(_ message: String) { DebugLog.log("Effect failure: %@", message); pause(); error = message; status = "foldelight needs attention" }

    func toggle() { if enabled || starting { pause() } else { enable() } }

    func playPreview() {
        followLid = false
        previewClock.stop()
        var start: Double?
        previewClock.tick = { [weak self] time in
            guard let self else { return }
            if start == nil { start = time }
            let phase = min(1, (time - start!) / 3)
            self.previewAngle = 115 - 90 * pow(sin(phase * .pi), 2)
            if phase == 1 { self.previewClock.stop() }
        }
        previewClock.start()
    }

    func testDesktop() {
        guard enabled else { return }
        desktopClock.stop()
        DebugLog.log("Desktop test started")
        testing = true
        capture.tracksDirectSensorInput = false
        status = "Testing desktop · clears automatically in 4 seconds"
        var start: Double?
        desktopClock.tick = { [weak self] time in
            guard let self else { return }
            if start == nil { start = time }
            let phase = min(1, (time - start!) / 4)
            self.capture.angle = self.settings.clearAngle * (1 - 0.72 * pow(sin(phase * .pi), 2))
            if phase == 1 {
                self.desktopClock.stop()
                self.testing = false
                self.capture.tracksDirectSensorInput = true
                self.capture.angle = self.currentLidAngle ?? self.settings.clearAngle
                self.status = "Following your lid"
            }
        }
        desktopClock.start()
    }

    func stopPreviewAnimation() { previewClock.stop() }
    func beginManualPreview() -> Double {
        let angle = PreviewLidDrag.clamped(displayedAngle)
        stopPreviewAnimation()
        previewAngle = angle
        followLid = false
        return angle
    }
    func retrySensor() { sensor.stop(); sensor.start() }
    func resetAppearance() { settings = EffectSettings() }
    func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }
}
