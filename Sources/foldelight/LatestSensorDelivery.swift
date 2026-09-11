// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// One pending notification per sensor generation. New readings replace old
/// readings while the main thread is busy instead of replaying their history.
final class LatestSensorDelivery<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int?
    private var latest: Value?
    private var pending = false

    func reset(generation: Int?) {
        lock.lock(); defer { lock.unlock() }
        self.generation = generation
        latest = nil
        pending = false
    }

    /// True means the caller must schedule a notification for this generation.
    func put(_ value: Value, generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard self.generation == generation else { return false }
        latest = value
        guard !pending else { return false }
        pending = true
        return true
    }

    func take(generation: Int) -> Value? {
        lock.lock(); defer { lock.unlock() }
        // An old queued notification must not clear the new generation's slot.
        guard self.generation == generation else { return nil }
        let value = latest
        latest = nil
        pending = false
        return value
    }
}
