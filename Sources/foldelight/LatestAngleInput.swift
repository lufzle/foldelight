// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct TimedAngle: Equatable {
    var angle: Double
    var sampledAt: Double
    var readStartedAt: Double? = nil
}

struct SensorInputSnapshot: Equatable {
    var reading: TimedAngle?
    var unavailable: Bool
}

/// The render clock reads the newest physical sample directly. UI telemetry
/// can remain throttled without inserting another display interval into motion.
final class LatestAngleInput: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimedAngle?
    private var unavailable = false
    private var lastTimestamp = -Double.infinity
    private var onChange: ((SensorInputSnapshot) -> Void)?

    @discardableResult
    func put(angle: Double, sampledAt: Double, readStartedAt: Double? = nil) -> Bool {
        guard angle.isFinite, sampledAt.isFinite,
              readStartedAt == nil || (readStartedAt!.isFinite && readStartedAt! <= sampledAt) else { return false }
        lock.lock()
        guard sampledAt >= lastTimestamp else { lock.unlock(); return false }
        value = TimedAngle(angle: angle, sampledAt: sampledAt, readStartedAt: readStartedAt)
        unavailable = false
        lastTimestamp = sampledAt
        let callback = onChange, snapshot = SensorInputSnapshot(reading: value, unavailable: false)
        lock.unlock()
        callback?(snapshot)
        return true
    }

    @discardableResult
    func invalidate(at time: Double) -> Bool {
        guard time.isFinite else { return false }
        lock.lock()
        guard time >= lastTimestamp else { lock.unlock(); return false }
        value = nil; unavailable = true; lastTimestamp = time
        let callback = onChange
        lock.unlock()
        callback?(SensorInputSnapshot(reading: nil, unavailable: true))
        return true
    }

    func snapshot() -> SensorInputSnapshot {
        lock.lock(); defer { lock.unlock() }
        return SensorInputSnapshot(reading: value, unavailable: unavailable)
    }

    func observe(_ callback: ((SensorInputSnapshot) -> Void)?) {
        lock.lock(); onChange = callback; lock.unlock()
    }

    func latest() -> TimedAngle? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func reset() {
        lock.lock()
        value = nil
        unavailable = false
        lastTimestamp = -Double.infinity
        lock.unlock()
    }
}
