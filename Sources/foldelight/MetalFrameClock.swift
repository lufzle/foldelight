// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import QuartzCore

/// Core Animation owns drawable acquisition and supplies the presentation
/// deadline. This avoids calling CAMetalLayer.nextDrawable on the main thread.
@MainActor
final class MetalFrameClock: NSObject, CAMetalDisplayLinkDelegate {
    static let preferredLatency: Float = 1
    private var link: CAMetalDisplayLink?
    struct Configuration: Equatable {
        var latency: Float
        var minimumRate: Float
        var maximumRate: Float
        var preferredRate: Float?
        var paused: Bool
    }
    var configuration: Configuration? {
        guard let link else { return nil }
        let rate = link.preferredFrameRateRange
        return Configuration(latency: link.preferredFrameLatency, minimumRate: rate.minimum,
            maximumRate: rate.maximum, preferredRate: rate.preferred, paused: link.isPaused)
    }
    var configured: Bool { link != nil }
    var tick: ((CAMetalDisplayLink.Update) -> Void)?

    func configure(layer: CAMetalLayer, screen: NSScreen) {
        invalidate()
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self
        link.preferredFrameLatency = Self.preferredLatency
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func start() { link?.isPaused = false }
    func stop() { link?.isPaused = true }
    func invalidate() {
        link?.invalidate()
        link = nil
    }

    nonisolated func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // The link is registered only on the main run loop above.
        MainActor.assumeIsolated { tick?(update) }
    }
}

struct RenderInputs: Equatable {
    var angle: Double
    var settings: EffectSettings
    var sourceRevision: UInt64
    var blackout: Double = 0
}

/// A failed or skipped submission remains dirty. Only a submitted frame may
/// become the baseline for suppressing identical work.
struct DirtyFrameGate {
    private(set) var submitted: RenderInputs?
    func needsFrame(_ inputs: RenderInputs) -> Bool {
        // New captures and angles cannot change a fully opaque black frame.
        if inputs.blackout == 1, submitted?.blackout == 1 { return false }
        return inputs != submitted
    }
    mutating func didSubmit(_ inputs: RenderInputs) { submitted = inputs }
    mutating func reset() { submitted = nil }
}
