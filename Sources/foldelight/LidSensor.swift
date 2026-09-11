// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import IOKit.hid
import QuartzCore

/// Main-thread API with serial background hardware sampling. Apple does not
/// document these HID layouts. Report 1 supplies whole degrees. On the verified
/// Apple device, report 7 supplies hundredths, with a guarded report 1 fallback.
final class LidSensor {
    var onChange: ((Double?) -> Void)?
    var onSample: (@Sendable (Double?, Double, Double) -> Void)?
    private(set) var status = "Lid sensor has not started"
    let samplingRate: Int
    private let queue = DispatchQueue(label: "com.lufzle.foldelight.lid", qos: .userInteractive)
    private let reader = Reader()
    private let delivery = LatestSensorDelivery<PendingReading>()
    private var generation = 0
    private var running = false

    init(samplingRate: Int? = nil) {
        let displayRate = NSScreen.screens.first(where: {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return false }
            return CGDisplayIsBuiltin(id) != 0
        })?.maximumFramesPerSecond ?? 60
        self.samplingRate = SensorSamplingPolicy.rate(requested: samplingRate ?? displayRate)
    }

    func start() {
        precondition(Thread.isMainThread)
        guard !running else { return }
        generation += 1
        let token = generation
        delivery.reset(generation: token)
        // Preserve synchronous first-reading semantics for the Enable action.
        let initial = queue.sync { self.reader.openAndRead() }
        status = initial.status
        running = initial.angle != nil
        let initialEnd = initial.readCompletedAt ?? CACurrentMediaTime()
        onSample?(initial.angle, initial.readStartedAt ?? initialEnd, initialEnd)
        onChange?(initial.angle)
        guard running, token == generation else { return }
        let reader = reader
        let timing = reader.timing
        let delivery = delivery
        let onSample = onSample
        let rate = samplingRate
        let samplingQueue = queue
        queue.async {
            reader.begin(rate: rate, queue: samplingQueue) { result in
                let queuedAt = DebugLog.shared.enabled ? CACurrentMediaTime() : nil
                let readEnd = result.readCompletedAt ?? CACurrentMediaTime()
                onSample?(result.angle, result.readStartedAt ?? readEnd, readEnd)
                guard delivery.put(PendingReading(reading: result, queuedAt: queuedAt), generation: token) else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.running else { return }
                    guard let latest = delivery.take(generation: token) else { return }
                    let result = latest.reading
                    if let queuedAt = latest.queuedAt { timing.recordDelivery(CACurrentMediaTime() - queuedAt) }
                    self.status = result.status
                    if result.stopped { self.running = false }
                    self.onChange?(result.angle)
                }
            }
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        delivery.reset(generation: nil)
        running = false
        let reader = reader
        queue.async { reader.stop() }
        status = "Lid sensor paused"
    }

    /// Explicit fresh read. Continuous reads never block the main thread.
    func readOnce() -> Double? {
        precondition(Thread.isMainThread)
        guard running else { return nil }
        let result = queue.sync { reader.read() }
        status = result.status
        return result.angle
    }

    deinit {
        let reader = reader
        queue.async { reader.stop() }
    }

    private struct Reading {
        var angle: Double?
        var status: String
        var stopped = false
        var readStartedAt: Double?
        var readCompletedAt: Double?
    }

    private struct PendingReading {
        var reading: Reading
        var queuedAt: Double?
    }

    /// All mutable Reader state belongs to the serial sampling queue.
    private final class Reader {
        let timing = SensorTiming()
        private var device: IOHIDDevice?
        private var timer: DispatchSourceTimer?
        private var failures = 0
        private var lastAngle: Double?
        private var lastStatus = ""
        private var selection = LidReportSelection()

        func openAndRead() -> Reading {
            stop()
            let matching: [String: Any] = [kIOProviderClassKey: "IOHIDDevice",
                kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A]
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching as CFDictionary)
            guard service != 0 else { return Reading(status: "No compatible lid sensor found. Use the preview slider.") }
            defer { IOObjectRelease(service) }
            guard let candidate = IOHIDDeviceCreate(kCFAllocatorDefault, service) else {
                return Reading(status: "Could not connect to the lid sensor")
            }
            let result = IOHIDDeviceOpen(candidate, 0)
            guard result == kIOReturnSuccess else {
                return Reading(status: "Lid sensor access unavailable (\(result)). Use the preview slider.")
            }
            device = candidate
            failures = 0
            let initial = read(opening: true)
            lastAngle = initial.angle
            lastStatus = initial.status
            if initial.angle == nil { stop() }
            return initial
        }

        func begin(rate: Int, queue: DispatchQueue?, deliver: @escaping (Reading) -> Void) {
            guard device != nil, let queue else { return }
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let interval = DispatchTimeInterval.nanoseconds(1_000_000_000 / rate)
            source.schedule(deadline: .now() + interval, repeating: interval,
                            leeway: .nanoseconds(SensorSamplingPolicy.leewayNanoseconds))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                var result = self.read()
                if self.failures >= 3 {
                    self.stop()
                    result.stopped = true
                }
                // Cached sensor values often stay unchanged. Do not wake SwiftUI
                // or redraw the desktop for duplicate readings.
                if result.angle != self.lastAngle || result.status != self.lastStatus || result.stopped {
                    if result.angle != self.lastAngle { self.timing.recordChange(at: CACurrentMediaTime()) }
                    self.lastAngle = result.angle
                    self.lastStatus = result.status
                    deliver(result)
                }
                self.timing.reportIfDue(at: CACurrentMediaTime())
            }
            timer = source
            source.resume()
        }

        private func supportsPrecision(_ device: IOHIDDevice) -> Bool {
            let vendor = (IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue ?? -1
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue ?? -1
            let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []
            return elements.contains { element in
                PreciseLidCapability.supports(vendor: vendor, product: product,
                    report: Int(IOHIDElementGetReportID(element)), usagePage: Int(IOHIDElementGetUsagePage(element)),
                    usage: Int(IOHIDElementGetUsage(element)), minimum: IOHIDElementGetLogicalMin(element),
                    maximum: IOHIDElementGetLogicalMax(element), exponent: Int(IOHIDElementGetUnitExponent(element)))
            }
        }

        func read(opening: Bool = false) -> Reading {
            guard let device else { return Reading(status: "Lid sensor paused") }
            let readStart = CACurrentMediaTime()
            var lastResult = kIOReturnSuccess
            let fetch: (Int) -> Double? = { reportID in
              withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 8) { bytes in
                bytes.initialize(repeating: 0)
                var count = bytes.count
                lastResult = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, reportID, bytes.baseAddress!, &count)
                guard lastResult == kIOReturnSuccess else { return nil }
                let report = UnsafeBufferPointer(start: bytes.baseAddress, count: bytes.count)
                return reportID == 7 ? LidReportDecoder.preciseAngle(from: report, count: count)
                    : LidReportDecoder.angle(from: report, count: count)
              }
            }
            let wasPrecise = selection.usesPrecision
            let angle = opening ? selection.open(supportsPrecision: supportsPrecision(device), read: fetch)
                : selection.next(read: fetch)
            if opening || wasPrecise != selection.usesPrecision {
                DebugLog.log("Lid input: %@", selection.usesPrecision ? "validated report 7 (0.01 degree)" : "report 1 (whole degree fallback)")
            }
            var reading: Reading
            if let angle {
                failures = 0
                reading = Reading(angle: angle, status: "Lid sensor connected")
            } else {
                failures += 1
                reading = Reading(status: "Lid sensor read failed or unsupported report (\(lastResult))")
            }
            let readEnd = CACurrentMediaTime()
            reading.readStartedAt = readStart
            reading.readCompletedAt = readEnd
            if DebugLog.shared.enabled { timing.recordRead(readEnd - readStart) }
            return reading
        }

        func stop() {
            timer?.cancel()
            timer = nil
            if let device { IOHIDDeviceClose(device, 0) }
            device = nil
        }
    }

    /// Bounded diagnostic samples only. The sampling queue reports once per five
    /// seconds; the main queue only records delivery delay under a short lock.
    private final class SensorTiming {
        private struct Samples {
            var count = 0
            var maximum = 0.0
            var values: [Double] = []
            mutating func add(_ value: Double) {
                count += 1
                maximum = max(maximum, value)
                if values.count < 1024 { values.append(value) }
                else { values[(count - 1) % 1024] = value }
            }
            var description: String {
                guard !values.isEmpty else { return "count=0" }
                let sorted = values.sorted()
                let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
                return String(format: "count=%d p95=%.2fms max=%.2fms", count, p95 * 1000, maximum * 1000)
            }
        }
        private let lock = NSLock()
        private var reads = Samples()
        private var changes = Samples()
        private var deliveries = Samples()
        private var changedReports = 0
        private var lastChange: Double?
        private var started: Double?

        func recordRead(_ duration: Double) {
            lock.lock(); defer { lock.unlock() }
            reads.add(duration)
        }
        func recordDelivery(_ delay: Double) {
            lock.lock(); defer { lock.unlock() }
            deliveries.add(delay)
        }
        func recordChange(at time: Double) {
            guard DebugLog.shared.enabled else { return }
            lock.lock(); defer { lock.unlock() }
            changedReports += 1
            if let lastChange { changes.add(time - lastChange) }
            lastChange = time
        }
        func reportIfDue(at time: Double) {
            let enabled = DebugLog.shared.enabled
            lock.lock()
            if !enabled {
                reads = Samples(); changes = Samples(); deliveries = Samples()
                changedReports = 0; lastChange = nil; started = nil
                lock.unlock()
                return
            }
            guard let started else { self.started = time; lock.unlock(); return }
            guard time - started >= 5 else { lock.unlock(); return }
            let readSnapshot = reads
            let changeSnapshot = changes
            let deliverySnapshot = deliveries
            let changedCount = changedReports
            reads = Samples(); changes = Samples(); deliveries = Samples()
            changedReports = 0; self.started = time
            lock.unlock()
            DebugLog.log("Sensor timing %.2fs: HID read [%@]; changed reports=%d, interarrival [%@] (includes stationary gaps); UI main-queue delivery [%@]",
                time - started, readSnapshot.description, changedCount, changeSnapshot.description, deliverySnapshot.description)
        }
    }
}

enum SensorSamplingPolicy {
    static let minimumRate = 30
    static let maximumRate = 120
    static let leewayNanoseconds = 0

    static func rate(requested: Int) -> Int {
        min(maximumRate, max(minimumRate, requested))
    }
}

enum LidReportDecoder {
    static func angle(from bytes: UnsafeBufferPointer<UInt8>, count: Int) -> Double? {
        guard count >= 3, count <= bytes.count, bytes.count >= 3, bytes[0] == 1 else { return nil }
        let degrees = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
        return degrees <= 360 ? Double(degrees) : nil
    }

    static func angle(from bytes: [UInt8], count: Int? = nil) -> Double? {
        bytes.withUnsafeBufferPointer { angle(from: $0, count: count ?? bytes.count) }
    }

    static func preciseAngle(from bytes: UnsafeBufferPointer<UInt8>, count: Int) -> Double? {
        guard count == 5, bytes.count >= 5, bytes[0] == 7 else { return nil }
        let hundredths = UInt32(bytes[1]) | (UInt32(bytes[2]) << 8)
            | (UInt32(bytes[3]) << 16) | (UInt32(bytes[4]) << 24)
        return hundredths <= 36000 ? Double(hundredths) / 100 : nil
    }

    static func preciseAngle(from bytes: [UInt8], count: Int? = nil) -> Double? {
        bytes.withUnsafeBufferPointer { preciseAngle(from: $0, count: count ?? bytes.count) }
    }
}
