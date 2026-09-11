// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Reconstructs motion between measured HID updates. Reading a cached report
/// at 120 Hz does not make it a new measurement. Only changed, timestamped
/// reports enter this estimator; prediction has a short, explicit lifetime.
struct LidMotionEstimator {
    static let noiseFloor = 0.15
    static let maximumVelocity = 180.0
    static let maximumOffset = 24.0
    static let maximumLead = 0.05
    private(set) var measuredAngle: Double?
    private(set) var velocity = 0.0
    private(set) var interval = 0.1
    private var last: TimedAngle?

    mutating func reset() { self = Self() }

    mutating func observe(_ sample: TimedAngle, activationAngle: Double? = nil) {
        guard sample.angle.isFinite, sample.sampledAt.isFinite,
              (0...360).contains(sample.angle) else { return }
        if let last {
            guard sample.sampledAt > last.sampledAt else { return }
            let elapsed = sample.sampledAt - last.sampledAt
            let delta = sample.angle - last.angle
            // Duplicate polls must not refresh the age or erase the velocity
            // of the last real change. Sensor invalidation is a separate event.
            guard delta != 0 else { return }
            if (0.004...0.25).contains(elapsed) {
                interval = min(0.12, max(1.0 / 120, interval * 0.75 + elapsed * 0.25))
                let displaced = abs(sample.angle - (measuredAngle ?? last.angle)) > Self.noiseFloor
                velocity = abs(delta) > Self.noiseFloor && displaced
                    ? min(Self.maximumVelocity, max(-Self.maximumVelocity, delta / elapsed)) : 0
            } else {
                // A resumed device or an isolated jump supplies no trustworthy
                // velocity. Wait for the next nearby measurement.
                velocity = 0
                interval = 0.1
            }
        }
        let crossedActivation = activationAngle.map { threshold in
            measuredAngle.map { ($0 < threshold) != (sample.angle < threshold) } ?? false
        } ?? false
        // A sub-degree movement through the blackout boundary must remain
        // observable in both directions, even when normal sensor noise is held.
        let crossedFoldStop = activationAngle.map { clearAngle in
            let threshold = max(0, clearAngle - EffectSettings.maximumTiltDegrees)
            return measuredAngle.map { ($0 <= threshold) != (sample.angle <= threshold) } ?? false
        } ?? false
        if measuredAngle == nil || abs(sample.angle - measuredAngle!) > Self.noiseFloor || crossedActivation || crossedFoldStop {
            measuredAngle = sample.angle
        }
        last = sample
    }

    /// `now` is actual callback arrival. `presentationTime` may be in the
    /// future, but must never make a missing sensor look fresh. The 25% grace
    /// covers the measured 100-110 ms cadence and polling jitter. Once it
    /// expires, the normal 8 ms render smoother returns to the measured pose.
    func target(at presentationTime: Double, now: Double) -> Double? {
        guard let measuredAngle, let last else { return nil }
        guard now.isFinite, presentationTime.isFinite, now >= last.sampledAt else { return measuredAngle }
        let age = now - last.sampledAt
        let horizon = min(0.15, max(0.025, interval * 1.25))
        guard age <= horizon else { return measuredAngle }
        let lead = min(Self.maximumLead, max(0, presentationTime - now))
        let offset = min(Self.maximumOffset, max(-Self.maximumOffset, velocity * (age + lead)))
        return min(360, max(0, measuredAngle + offset))
    }

    func isPredicting(at now: Double) -> Bool {
        guard let last, now.isFinite, now >= last.sampledAt, velocity != 0 else { return false }
        return now - last.sampledAt <= min(0.15, max(0.025, interval * 1.25))
    }
}
