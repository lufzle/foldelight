// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import QuartzCore

/// A display-owned clock. No timer competes with the compositor's cadence.
@MainActor
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    var tick: ((Double) -> Void)?
    func start(screen: NSScreen? = NSScreen.main) {
        guard link == nil, let screen else { return }
        let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
        let rate = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    func stop() { link?.invalidate(); link = nil }
    @objc private func frame(_ link: CADisplayLink) { tick?(link.targetTimestamp) }
}

struct AngleSmoother {
    static let responseTime = 0.008
    private(set) var value: Double
    private var timestamp: Double?
    init(_ value: Double) { self.value = value }
    mutating func advance(to target: Double, at time: Double) -> Double {
        let dt = min(0.1, max(0, time - (timestamp ?? (time - 1.0 / 120))))
        timestamp = time
        // One degree of sensor quantization still crosses several pixels at
        // native resolution. An 8 ms constant smooths that step over frames
        // without the former 25 ms input lag.
        value += (target - value) * (1 - exp(-dt / Self.responseTime))
        if abs(target - value) < 0.01 { value = target }
        return value
    }
}
