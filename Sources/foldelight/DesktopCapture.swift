// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ScreenCaptureKit
import MetalKit
import QuartzCore

@MainActor
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var panel: NSPanel?
    private var metalView: MTKView?
    private var worker: LiveRenderWorker?
    private var screen: NSScreen?
    private var capturedDisplayID: UInt32?
    private var capturedFrame = NSRect.zero
    private var capturedScale: CGFloat = 1
    private let mailbox = CaptureMailbox()
    private let captureQueue = DispatchQueue(label: "com.lufzle.foldelight.capture", qos: .userInteractive)
    private nonisolated let directAngles = LatestAngleInput()
    private var generation = 0
    private var receivedFrame = false
    private var firstFrameTask: Task<Void, Never>?
    var onFailure: ((String) -> Void)?
    var onFrame: (() -> Void)?
    var angle = 135.0 { didSet { update() } }
    var settings = EffectSettings() { didSet { update() } }
    var tracksDirectSensorInput = true { didSet { update() } }

    nonisolated func submitAngle(_ angle: Double?, readStartedAt: Double, sampledAt: Double) {
        if let angle { directAngles.put(angle: angle, sampledAt: sampledAt, readStartedAt: readStartedAt) }
        else { directAngles.invalidate(at: sampledAt) }
    }

    func start() async throws {
        generation += 1
        let token = generation
        let oldStream = releaseResources()
        try? await oldStream?.stopCapture()
        guard token == generation else { return }
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }), let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            throw CaptureError.message("No built-in display is available. Connect the MacBook display and try again.")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw BendRenderer.RenderError.unavailable }
        // The hidden panel must exist before enumerating windows so the filter
        // can exclude its exact identity without removing settings or menus.
        let overlay = try DesktopOverlayPolicy.make(screen: screen, device: device)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard token == generation else { return }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.message("The built-in display is not available for capture.")
        }
        let filter = try DesktopOverlayPolicy.captureFilter(display: display, excluding: overlay.panel,
                                                            windows: content.windows)
        let renderer = try BendRenderer(device: device)
        renderer.onFirstPresentation = { DebugLog.log("foldelight: first live effect frame presented successfully") }
        let panel = overlay.panel, view = overlay.view, layer = overlay.layer
        self.panel = panel
        self.metalView = view
        self.screen = screen
        capturedDisplayID = displayID
        capturedFrame = screen.frame
        capturedScale = screen.backingScaleFactor
        let worker = LiveRenderWorker(layer: layer, renderer: renderer, rate: screen.maximumFramesPerSecond,
            scale: Float(capturedScale), angle: angle, settings: settings, followsSensor: tracksDirectSensorInput,
            sensor: directAngles, frames: mailbox, visibility: { [weak self, weak panel] visible in
                guard let self, self.generation == token, let panel else { return }
                if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
            })
        self.worker = worker
        directAngles.observe { [weak worker] sample in worker?.sensorChanged(sample) }
        mailbox.observe { [weak worker] in worker?.sourceChanged() }
        receivedFrame = false
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * Double(filter.pointPixelScale)).rounded())
        configuration.height = Int((filter.contentRect.height * Double(filter.pointPixelScale)).rounded())
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(screen.maximumFramesPerSecond))
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        mailbox.activate(newStream)
        stream = newStream
        DebugLog.log("foldelight: capture %dx%d at %d Hz", configuration.width, configuration.height, screen.maximumFramesPerSecond)
        do {
            try await newStream.startCapture()
            guard token == generation else { try? await newStream.stopCapture(); return }
            firstFrameTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, token == self.generation, !self.receivedFrame else { return }
                DebugLog.log("foldelight: capture timeout: %@", self.mailbox.sampleStatus)
                self.onFailure?("macOS started screen capture but sent no desktop frames. Restart your Mac if enabling foldelight again does not resolve this.")
            }
        } catch {
            if token == generation { await stop() }
            throw error
        }
    }

    func stop() async {
        generation += 1
        let oldStream = releaseResources()
        try? await oldStream?.stopCapture()
    }

    func cancel() {
        generation += 1
        let oldStream = releaseResources()
        Task { try? await oldStream?.stopCapture() }
    }

    private func releaseResources() -> SCStream? {
        directAngles.observe(nil)
        mailbox.observe(nil)
        worker?.stop()
        worker = nil
        mailbox.reset()
        firstFrameTask?.cancel()
        firstFrameTask = nil
        panel?.orderOut(nil)
        panel = nil
        metalView?.delegate = nil
        metalView = nil
        receivedFrame = false
        let oldStream = stream
        stream = nil
        return oldStream
    }

    func displayConfigurationChanged() -> Bool {
        guard let capturedDisplayID,
              let current = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == capturedDisplayID
              }) else { return true }
        return current.frame != capturedFrame || current.backingScaleFactor != capturedScale
    }

    func hideImmediately() { worker?.stop(); worker = nil; panel?.orderOut(nil) }

    private func update() {
        worker?.update(angle: angle, settings: settings, followsSensor: tracksDirectSensorInput)
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard sampleBuffer.isValid else {
            mailbox.recordStatus("Invalid screen sample", from: stream)
            return
        }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else {
            mailbox.recordStatus("Screen sample has no frame status", from: stream)
            return
        }
        guard SCFrameStatus(rawValue: raw) == .complete else {
            mailbox.recordStatus("Screen sample status \(raw) (not complete)", from: stream)
            return
        }
        guard let buffer = sampleBuffer.imageBuffer else {
            mailbox.recordStatus("Complete screen sample has no image buffer", from: stream)
            return
        }
        let info = attachments[0]
        let metadata = CaptureMetadata.decode(info)
        // Source notifications wake the render run loop. Main receives only the
        // first-frame status update, through common modes rather than dispatch.
        if mailbox.put(buffer, from: stream, displayTime: metadata.displayTime, damage: metadata.damage) {
            MainRunLoop.perform {
                guard stream === self.stream else { return }
                self.receivedFrame = true
                self.firstFrameTask?.cancel()
                self.onFrame?()
                self.update()
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        MainRunLoop.perform {
            guard stream === self.stream else { return }
            self.hideImmediately()
            self.onFailure?(error.localizedDescription)
        }
    }
    enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
    }
}

/// At most one pending IOSurface, with the union of skipped capture damage.
final class CaptureMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var active: ObjectIdentifier?
    private var generation: UInt64 = 0
    private var pending: CapturedFrame?
    private var first = true
    private var samples = 0
    private var started = 0.0
    private var status = "No samples received"
    private var onFrame: (() -> Void)?
    var sampleStatus: String {
        lock.lock(); defer { lock.unlock() }
        return status
    }
    var hasPendingFrame: Bool {
        lock.lock(); defer { lock.unlock() }
        return pending != nil
    }
    func observe(_ callback: (() -> Void)?) {
        lock.lock(); onFrame = callback; lock.unlock()
    }
    func recordStatus(_ value: String, from stream: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        guard ObjectIdentifier(stream) == active else { return }
        status = value
    }
    func activate(_ stream: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        active = ObjectIdentifier(stream); pending = nil; first = true
        status = "No samples received"
        samples = 0; started = CACurrentMediaTime()
    }
    func reset() {
        lock.lock()
        let count = samples, duration = CACurrentMediaTime() - started
        generation &+= 1
        active = nil; pending = nil; first = true
        status = "No samples received"; samples = 0
        lock.unlock()
        if count > 0 { DebugLog.log("foldelight: %d complete capture samples over %.2f seconds", count, duration) }
    }
    func put(_ frame: CVPixelBuffer, from stream: AnyObject,
             displayTime: Double? = nil, damage: [CGRect]? = nil) -> Bool {
        lock.lock()
        guard active == ObjectIdentifier(stream) else { lock.unlock(); return false }
        let merged = pending.map { FrameDamage.merging($0.damage, damage) } ?? damage
        pending = CapturedFrame(buffer: frame, displayTime: displayTime, damage: merged, generation: generation)
        status = "Complete screen sample received"
        samples += 1
        let notify = first; first = false
        let callback = onFrame
        lock.unlock()
        callback?()
        return notify
    }
    func takeSample() -> CapturedFrame? {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending = nil
        return result
    }
    func take() -> CVPixelBuffer? { takeSample()?.buffer }

    /// A failed texture mapping retains its pixels for retry. If capture already
    /// supplied something newer, preserve that surface and merge the lost damage.
    func restore(_ frame: CapturedFrame) {
        lock.lock(); defer { lock.unlock() }
        guard active != nil, frame.generation == generation else { return }
        if var latest = pending {
            latest.damage = FrameDamage.merging(frame.damage, latest.damage)
            pending = latest
        } else { pending = frame }
    }
}
