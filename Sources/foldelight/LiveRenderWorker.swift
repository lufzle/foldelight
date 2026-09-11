// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import MetalKit
import QuartzCore

/// A narrow lifecycle seam. Production still creates and configures the native
/// link on its owning executor before exposing this interface.
protocol LiveRenderClock: AnyObject {
    var isPaused: Bool { get set }
    func invalidate()
}

extension CAMetalDisplayLink: LiveRenderClock {}

struct LiveMotionFrame {
    var angle: Double
    var blackout: Double
    var target: Double
    var settings: EffectSettings
    var followsSensor: Bool
    var input: SensorInputSnapshot
}

/// The window lives on main. This object's display link, texture cache, optical
/// state, and command encoding belong exclusively to its render run loop.
final class LiveRenderWorker: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private struct Controls {
        var angle: Double
        var settings: EffectSettings
        var followsSensor: Bool
    }
    private let executor = RenderExecutor()
    private let controlsLock = NSLock()
    private var controls: Controls
    private let sensor: LatestAngleInput
    private let frames: CaptureMailbox
    private let renderer: BendRenderer
    private let scale: Float
    private let predictsSensorMotion: Bool
    private let metricsEnabled: @Sendable () -> Bool
    private let visibility: @MainActor (Bool) -> Void
    private var link: (any LiveRenderClock)?
    private var wake: RenderWakeSignal!
    private var running = true
    private var visible = false
    private var smoother: AngleSmoother
    private var motion = LidMotionEstimator()
    private var motionClearAngle: Double?
    private var frameGate = DirtyFrameGate()
    private var sourceRevision: UInt64 = 0
    private var sourceDisplayTime: Double?

    init(layer: CAMetalLayer, renderer: BendRenderer, rate: Int, scale: Float,
         angle: Double, settings: EffectSettings, followsSensor: Bool,
         sensor: LatestAngleInput, frames: CaptureMailbox,
         preferredFrameLatency: Float = 1,
         predictsSensorMotion: Bool = true,
         metricsEnabled: @escaping @Sendable () -> Bool = { DebugLog.shared.enabled },
         visibility: @escaping @MainActor (Bool) -> Void,
         clockFactory: @escaping (CAMetalDisplayLink) -> any LiveRenderClock = { $0 }) {
        precondition(preferredFrameLatency == 1 || preferredFrameLatency == 2)
        self.renderer = renderer
        self.metricsEnabled = metricsEnabled
        self.scale = scale
        self.predictsSensorMotion = predictsSensorMotion
        self.sensor = sensor
        self.frames = frames
        self.visibility = visibility
        controls = Controls(angle: angle, settings: settings, followsSensor: followsSensor)
        smoother = AngleSmoother(angle)
        super.init()
        wake = RenderWakeSignal(executor: executor) { [weak self] in self?.consumeInput() }
        executor.sync { [self] in
            renderer.callbackExecutor = { [weak executor] work in executor?.perform(work) ?? false }
            renderer.onSubmissionFailure = { [weak self] in
                guard let self, self.running else { return }
                self.frameGate.reset()
                self.consumeInput()
            }
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameLatency = preferredFrameLatency
            let rate = Float(max(1, rate))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
            link.isPaused = true
            link.add(to: .current, forMode: .common)
            self.link = clockFactory(link)
        }
    }

    func update(angle: Double, settings: EffectSettings, followsSensor: Bool) {
        controlsLock.lock()
        controls = Controls(angle: angle, settings: settings, followsSensor: followsSensor)
        controlsLock.unlock()
        wake.signal()
    }

    func sourceChanged() { wake.signal() }

    func sensorChanged(_ observation: SensorInputSnapshot) {
        // Observe every changed report before wake coalescing. Consumption reads
        // sensor.snapshot() again, because concurrent notifications may reorder.
        if let epoch = renderer.metrics.setEnabled(metricsEnabled()), let sample = observation.reading {
            record(sample, epoch: epoch)
        }
        wake.signal()
    }

    func stop() {
        executor.sync { [self] in
            running = false
            link?.invalidate(); link = nil
            renderer.onSubmissionFailure = nil
            renderer.clear()
        }
        executor.stop()
    }

    private func configuration() -> Controls {
        controlsLock.lock(); defer { controlsLock.unlock() }
        return controls
    }

    private func target(_ configuration: Controls, _ input: SensorInputSnapshot) -> Double {
        // A changed threshold can cross a deadband-retained reading without a
        // new HID timestamp. Reanchor from the current sample before predicting.
        if motionClearAngle != configuration.settings.clearAngle {
            motion.reset()
            motionClearAngle = configuration.settings.clearAngle
        }
        guard configuration.followsSensor else { motion.reset(); return configuration.angle }
        if input.unavailable { motion.reset(); return configuration.settings.clearAngle }
        guard predictsSensorMotion else { return input.reading?.angle ?? configuration.angle }
        if let sample = input.reading { motion.observe(sample, activationAngle: configuration.settings.clearAngle) }
        return motion.measuredAngle ?? configuration.angle
    }

    private func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        let visibility = visibility
        MainRunLoop.perform { visibility(value) }
    }

    private func consumeInput() {
        guard running else { return }
        let configuration = configuration()
        let input = sensor.snapshot()
        let target = target(configuration, input)
        if configuration.followsSensor, input.unavailable {
            smoother = AngleSmoother(target)
            renderer.blackout = 0
            link?.isPaused = true
            frameGate.reset()
            setVisible(false)
            renderer.reportPerformance()
            return
        }
        guard frames.hasPendingFrame || renderer.sourcePixelWidth != nil else { return }
        if EffectSettings.progress(angle: target, clearAngle: configuration.settings.clearAngle) > 0.0001 || visible {
            // While hidden, smoothing has no visible state to preserve. Prime
            // from the current sample so an old clear angle cannot hide the
            // first slight fold and strand a paused layer without another wake.
            if !visible { smoother = AngleSmoother(target) }
            setVisible(true)
            link?.isPaused = false
        }
    }

    /// Sample input and configuration together on the owning run loop. Native
    /// callbacks and deterministic lifecycle tests use the same frame planning.
    func nextMotionFrame(at presentationTime: Double, now: Double) -> LiveMotionFrame {
        precondition(executor.isCurrent)
        let configuration = configuration()
        let input = sensor.snapshot()
        let target = target(configuration, input)
        let forecast = configuration.followsSensor && predictsSensorMotion
            ? motion.target(at: presentationTime, now: now) ?? target : target
        let angle = smoother.advance(to: forecast, at: presentationTime)
        let opacity = FoldBlackout.opacity(angle: angle, clearAngle: configuration.settings.clearAngle)
        return LiveMotionFrame(angle: angle, blackout: opacity,
            target: target, settings: configuration.settings, followsSensor: configuration.followsSensor, input: input)
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        precondition(executor.isCurrent)
        guard running else { return }
        let debug = metricsEnabled()
        let arrival = CACurrentMediaTime()
        renderer.collectsMetrics = debug
        let metrics = renderer.metrics
        let epoch = debug ? metrics.currentEpoch() : nil
        if let epoch {
            metrics.record(.callback(arrival: arrival, expectedPresentation: update.targetPresentationTimestamp,
                                     deadline: update.targetTimestamp), epoch: epoch)
        }
        let frame = nextMotionFrame(at: update.targetPresentationTimestamp, now: arrival)
        let angle = frame.angle, target = frame.target
        renderer.angle = angle
        renderer.blackout = frame.blackout
        renderer.settings = frame.settings
        if EffectSettings.progress(angle: angle, clearAngle: frame.settings.clearAngle) <= 0.0001 {
            if let epoch { metrics.record(.skippedClean, epoch: epoch) }
            setVisible(false)
            if EffectSettings.progress(angle: target, clearAngle: frame.settings.clearAngle) <= 0.0001 {
                link.isPaused = true
                smoother = AngleSmoother(target)
                renderer.reportPerformance()
            }
            return
        }
        setVisible(true)
        if let frame = frames.takeSample() {
            if renderer.setFrame(frame.buffer, damage: frame.damage) {
                sourceRevision &+= 1
                sourceDisplayTime = frame.displayTime
            } else {
                frames.restore(frame)
                if let epoch { metrics.record(.failed, epoch: epoch) }
                return
            }
        }
        let inputs = RenderInputs(angle: angle, settings: frame.settings,
            sourceRevision: sourceRevision, blackout: frame.blackout)
        guard frameGate.needsFrame(inputs) else {
            if let epoch { metrics.record(.skippedClean, epoch: epoch) }
            // An identical pair of projected frames can occur during a turn.
            // Keep the clock alive until the forecast expires or settles.
            // Several reopening steps can still be fully black. Keep smoothing
            // until the measured pose is reached, including after a forecast expires.
            link.isPaused = angle == target && (!frame.followsSensor
                || !predictsSensorMotion || !motion.isPredicting(at: arrival))
            return
        }
        let sample = frame.followsSensor ? frame.input.reading : nil
        let timing = PerformanceFrameTiming(sensorID: sample?.sampledAt.bitPattern,
            sensorReadStart: sample?.readStartedAt, sensorReadEnd: sample?.sampledAt,
            sourceDisplayTime: sourceDisplayTime, targetAngle: target, renderedAngle: angle,
            callbackArrival: debug ? arrival : nil,
            expectedPresentationTime: debug ? update.targetPresentationTimestamp : nil)
        if renderer.draw(drawable: update.drawable, pixelScale: scale,
                         targetDeadline: update.targetTimestamp, timing: timing) {
            frameGate.didSubmit(inputs)
        }
    }

    private func record(_ sample: TimedAngle, epoch: UInt64) {
        renderer.metrics.record(.sensorRead(id: sample.sampledAt.bitPattern,
            start: sample.readStartedAt ?? sample.sampledAt, end: sample.sampledAt,
            targetAngle: sample.angle), epoch: epoch)
    }
}
