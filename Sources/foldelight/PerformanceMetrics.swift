// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct PerformanceFrameTiming: Sendable {
    var sensorID: UInt64?
    var sensorReadStart: Double?
    var sensorReadEnd: Double?
    var sourceDisplayTime: Double?
    var targetAngle: Double?
    var renderedAngle: Double?
    var callbackArrival: Double?
    var expectedPresentationTime: Double?

    init(sensorID: UInt64? = nil, sensorReadStart: Double? = nil, sensorReadEnd: Double? = nil,
         sourceDisplayTime: Double? = nil, targetAngle: Double? = nil, renderedAngle: Double? = nil,
         callbackArrival: Double? = nil, expectedPresentationTime: Double? = nil) {
        self.sensorID = sensorID; self.sensorReadStart = sensorReadStart; self.sensorReadEnd = sensorReadEnd
        self.sourceDisplayTime = sourceDisplayTime; self.targetAngle = targetAngle; self.renderedAngle = renderedAngle
        self.callbackArrival = callbackArrival; self.expectedPresentationTime = expectedPresentationTime
    }
}

enum PerformanceCounter: String, CaseIterable, Sendable {
    case callbacks, skippedClean, skippedBusy, submitted, failed, presented
    case sensorReads, sensorFirstPresented, sensorSettled, sensorSupersededUnpresented
    case sensorTrackingEvictions, sensorUntrackedPresentations, invalidEvents
    case cpuCommitDeadlineMisses, presentRequestDeadlineMisses
}

enum PerformanceDistribution: String, CaseIterable, Sendable {
    // All values are milliseconds except angleError, which is degrees.
    case callbackInterval, expectedPresentationInterval, presentationInterval
    case callbackPresentationLead, callbackDeadlineMargin, cpuCommitMargin, presentRequestMargin
    case gpu, gpuQueueDelay, cpuEncode, sensorReadDuration
    case callbackToPresent, presentationTargetError
    case sensorReadStartToFirstPresent, sensorReadEndToFirstPresent
    case sensorReadStartToSettled, sensorReadEndToSettled
    case sourceDisplayToPresent, angleError
}

struct PerformancePercentiles: Equatable, Sendable {
    let count: Int
    let p50: Double
    let p95: Double
    let p99: Double
    let maximum: Double
    let minimum: Double
    let mean: Double

    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))]
        }
        count = sorted.count; p50 = percentile(0.50); p95 = percentile(0.95); p99 = percentile(0.99)
        maximum = sorted.last!; minimum = sorted.first!; mean = sorted.reduce(0, +) / Double(sorted.count)
    }
}

struct PerformanceSnapshot: Sendable {
    let epoch: UInt64
    let counters: [PerformanceCounter: Int]
    let distributions: [PerformanceDistribution: PerformancePercentiles]
    let callbackFPS: Double?
    let presentationFPS: Double?
    let sensorUnpresented: Int
    let sensorUnsettled: Int

    subscript(_ counter: PerformanceCounter) -> Int { counters[counter, default: 0] }
    subscript(_ metric: PerformanceDistribution) -> PerformancePercentiles? { distributions[metric] }
}

/// Thread-safe, bounded opt-in measurements. Every event carries its collection
/// epoch, so delayed GPU callbacks cannot contaminate a subsequent segment.
/// Sensor observations count changed HID reads, not physical motion onset.
final class PerformanceMetrics: @unchecked Sendable {
    enum Event: Sendable {
        case callback(arrival: Double, expectedPresentation: Double, deadline: Double)
        case skippedClean, skippedBusy, submitted, failed
        case gpu(seconds: Double), gpuQueueDelay(seconds: Double), cpuEncode(seconds: Double)
        case commit(at: Double, deadline: Double)
        case presentRequested(at: Double, deadline: Double)
        case sensorRead(id: UInt64, start: Double, end: Double, targetAngle: Double)
        case presentation(at: Double, frame: PerformanceFrameTiming)
    }

    private struct Samples {
        var values: [Double] = []
        var next = 0
        mutating func add(_ value: Double, capacity: Int) {
            if values.count < capacity { values.append(value) }
            else { values[next] = value; next = (next + 1) % capacity }
        }
    }
    private struct Sensor {
        let start: Double
        let end: Double
        let target: Double
        var presented = false
        var settled = false
        var firstPresentedAt: Double?
        var settledAt: Double?
        var superseded = false
    }
    private struct State {
        var counters: [PerformanceCounter: Int] = [:]
        var distributions: [PerformanceDistribution: Samples] = [:]
        var arrivals = Samples()
        var expected = Samples()
        var presentations = Samples()
        var firstArrival: Double?
        var lastArrival: Double?
        var firstPresentation: Double?
        var lastPresentation: Double?
        var sensors: [UInt64: Sensor] = [:]
        var sensorOrder: [UInt64] = []
        var sensorOrderNext = 0
        var latestSensor: UInt64?
        var latestSensorEnd = -Double.infinity
    }
    private let lock = NSLock()
    private let capacity: Int
    private var enabled = false
    private var epoch: UInt64 = 0
    private var state = State()

    init(capacity: Int = 4096) { self.capacity = max(1, capacity) }

    /// A nil token means callers can omit all timing reads and callback capture.
    @discardableResult func setEnabled(_ value: Bool) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        if value != enabled { enabled = value; epoch &+= 1; state = State() }
        return enabled ? epoch : nil
    }
    func currentEpoch() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return enabled ? epoch : nil
    }

    func record(_ event: Event, epoch token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, token == epoch else { return }
        switch event {
        case let .callback(arrival, expected, deadline):
            guard valid(arrival, expected, deadline) else { invalid(); return }
            increment(.callbacks)
            state.arrivals.add(arrival, capacity: capacity)
            state.expected.add(expected, capacity: capacity)
            state.firstArrival = min(state.firstArrival ?? arrival, arrival)
            state.lastArrival = max(state.lastArrival ?? arrival, arrival)
            add(.callbackPresentationLead, (expected - arrival) * 1000)
            add(.callbackDeadlineMargin, (deadline - arrival) * 1000)
        case .skippedClean: increment(.skippedClean)
        case .skippedBusy: increment(.skippedBusy)
        case .submitted: increment(.submitted)
        case .failed: increment(.failed)
        case let .gpu(seconds): duration(.gpu, seconds)
        case let .gpuQueueDelay(seconds): duration(.gpuQueueDelay, seconds)
        case let .cpuEncode(seconds): duration(.cpuEncode, seconds)
        case let .commit(time, deadline):
            guard valid(time, deadline) else { invalid(); return }
            add(.cpuCommitMargin, (deadline - time) * 1000)
            if time > deadline { increment(.cpuCommitDeadlineMisses) }
        case let .presentRequested(time, deadline):
            guard valid(time, deadline) else { invalid(); return }
            add(.presentRequestMargin, (deadline - time) * 1000)
            if time > deadline { increment(.presentRequestDeadlineMisses) }
        case let .sensorRead(id, start, end, target):
            guard valid(start, end, target), end >= start else { invalid(); return }
            guard state.sensors[id] == nil else { return }
            increment(.sensorReads)
            duration(.sensorReadDuration, end - start)
            if end >= state.latestSensorEnd {
                if let previous = state.latestSensor, var sensor = state.sensors[previous], !sensor.superseded {
                    sensor.superseded = true
                    state.sensors[previous] = sensor
                    if !sensor.presented { increment(.sensorSupersededUnpresented) }
                }
                state.latestSensor = id; state.latestSensorEnd = end
            }
            if state.sensorOrder.count == capacity {
                let oldID = state.sensorOrder[state.sensorOrderNext]
                state.sensors.removeValue(forKey: oldID)
                state.sensorOrder[state.sensorOrderNext] = id
                state.sensorOrderNext = (state.sensorOrderNext + 1) % capacity
                increment(.sensorTrackingEvictions)
            } else { state.sensorOrder.append(id) }
            let superseded = end < state.latestSensorEnd
            if superseded { increment(.sensorSupersededUnpresented) }
            state.sensors[id] = Sensor(start: start, end: end, target: target, superseded: superseded)
        case let .presentation(time, frame):
            guard time.isFinite, time > 0 else { invalid(); return }
            increment(.presented)
            state.presentations.add(time, capacity: capacity)
            state.firstPresentation = min(state.firstPresentation ?? time, time)
            state.lastPresentation = max(state.lastPresentation ?? time, time)
            if let arrival = frame.callbackArrival, arrival.isFinite, arrival >= 0, arrival <= time {
                duration(.callbackToPresent, time - arrival)
            }
            if let expected = frame.expectedPresentationTime, expected.isFinite, expected >= 0 {
                add(.presentationTargetError, (time - expected) * 1000)
            }
            if let source = frame.sourceDisplayTime, source.isFinite, source >= 0, source <= time {
                duration(.sourceDisplayToPresent, time - source)
            }
            if let angle = frame.renderedAngle, let target = frame.targetAngle, valid(angle, target) {
                add(.angleError, abs(angle - target))
            }
            guard let id = frame.sensorID else { return }
            guard var sensor = state.sensors[id] else { increment(.sensorUntrackedPresentations); return }
            guard time >= sensor.end else { invalid(); return }
            if !sensor.presented {
                sensor.presented = true
                increment(.sensorFirstPresented)
                if sensor.superseded { increment(.sensorSupersededUnpresented, by: -1) }
            }
            sensor.firstPresentedAt = min(sensor.firstPresentedAt ?? time, time)
            if let rendered = frame.renderedAngle, rendered.isFinite,
               abs(rendered - sensor.target) <= 0.01 {
                if !sensor.settled { increment(.sensorSettled) }
                sensor.settled = true
                sensor.settledAt = min(sensor.settledAt ?? time, time)
            }
            state.sensors[id] = sensor
        }
    }

    /// Copies bounded samples while locked. Sorting and summaries happen after
    /// releasing the lock so a report cannot block frame collection while sorting.
    func snapshotAndReset() -> PerformanceSnapshot {
        lock.lock()
        let copy = state, oldEpoch = epoch
        epoch &+= 1; state = State()
        lock.unlock()
        var distributions = copy.distributions.compactMapValues { PerformancePercentiles($0.values) }
        let sensors = Array(copy.sensors.values)
        distributions[.sensorReadStartToFirstPresent] = PerformancePercentiles(sensors.compactMap { sensor in sensor.firstPresentedAt.map { ($0 - sensor.start) * 1000 } })
        distributions[.sensorReadEndToFirstPresent] = PerformancePercentiles(sensors.compactMap { sensor in sensor.firstPresentedAt.map { ($0 - sensor.end) * 1000 } })
        distributions[.sensorReadStartToSettled] = PerformancePercentiles(sensors.compactMap { sensor in sensor.settledAt.map { ($0 - sensor.start) * 1000 } })
        distributions[.sensorReadEndToSettled] = PerformancePercentiles(sensors.compactMap { sensor in sensor.settledAt.map { ($0 - sensor.end) * 1000 } })
        func intervals(_ samples: Samples) -> PerformancePercentiles? {
            let sorted = samples.values.sorted()
            return PerformancePercentiles(zip(sorted.dropFirst(), sorted).map { ($0 - $1) * 1000 })
        }
        distributions[.callbackInterval] = intervals(copy.arrivals)
        distributions[.expectedPresentationInterval] = intervals(copy.expected)
        distributions[.presentationInterval] = intervals(copy.presentations)
        func rate(_ count: Int, _ first: Double?, _ last: Double?) -> Double? {
            guard count > 1, let first, let last, last > first else { return nil }
            return Double(count - 1) / (last - first)
        }
        return PerformanceSnapshot(epoch: oldEpoch, counters: copy.counters, distributions: distributions,
            callbackFPS: rate(copy.counters[.callbacks, default: 0], copy.firstArrival, copy.lastArrival),
            presentationFPS: rate(copy.counters[.presented, default: 0], copy.firstPresentation, copy.lastPresentation),
            sensorUnpresented: copy.counters[.sensorReads, default: 0] - copy.counters[.sensorFirstPresented, default: 0],
            sensorUnsettled: copy.counters[.sensorReads, default: 0] - copy.counters[.sensorSettled, default: 0])
    }

    private func valid(_ values: Double...) -> Bool { values.allSatisfy(\.isFinite) }
    private func increment(_ counter: PerformanceCounter, by amount: Int = 1) { state.counters[counter, default: 0] += amount }
    private func invalid() { increment(.invalidEvents) }
    private func add(_ metric: PerformanceDistribution, _ value: Double) {
        state.distributions[metric, default: Samples()].add(value, capacity: capacity)
    }
    private func duration(_ metric: PerformanceDistribution, _ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { invalid(); return }
        add(metric, seconds * 1000)
    }
}

extension PerformanceSnapshot {
    /// Counts cover the segment; percentiles cover each bounded recent window.
    /// Unpresented includes coalesced and still-pending reads, not proven drops.
    func log() {
        let counts = PerformanceCounter.allCases.map { "\($0.rawValue)=\(self[$0])" }.joined(separator: " ")
        DebugLog.log("Performance segment epoch=%llu: %@", epoch, counts)
        DebugLog.log("Performance rates: actual-callback-fps=%@ presented-fps=%@ sensor-unpresented=%d sensor-unsettled=%d (includes pending/coalesced; tracking evictions are reported separately)",
                     callbackFPS.map { String(format: "%.3f", $0) } ?? "unavailable",
                     presentationFPS.map { String(format: "%.3f", $0) } ?? "unavailable",
                     sensorUnpresented, sensorUnsettled)
        for metric in PerformanceDistribution.allCases {
            guard let values = self[metric] else { continue }
            DebugLog.log("Performance %@: recent-count=%d p50=%.3f p95=%.3f p99=%.3f max=%.3f min=%.3f mean=%.3f %@",
                         metric.rawValue, values.count, values.p50, values.p95, values.p99,
                         values.maximum, values.minimum, values.mean, metric == .angleError ? "degrees" : "ms")
        }
    }
}
