// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
import CoreFoundation
@testable import foldelight

private final class WorkerClockProbe: LiveRenderClock, @unchecked Sendable {
    private let lock = NSLock()
    private var paused = true
    private var invalidated = false
    private var writes = 0
    let resumed = DispatchSemaphore(value: 0)
    let pausedAfterResume = DispatchSemaphore(value: 0)
    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set {
            lock.lock()
            let wasPaused = paused
            paused = newValue; writes += 1
            lock.unlock()
            if !newValue { resumed.signal() }
            else if !wasPaused { pausedAfterResume.signal() }
        }
    }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    var state: (invalidated: Bool, writes: Int) {
        lock.lock(); defer { lock.unlock() }; return (invalidated, writes)
    }
}

final class LiveRenderWorkerTests: XCTestCase {
    private final class Fixture {
        let sensor = LatestAngleInput()
        let frames = CaptureMailbox()
        let stream = NSObject()
        let clock = WorkerClockProbe()
        let worker: LiveRenderWorker
        let renderer: BendRenderer
        init(settings: EffectSettings = EffectSettings(), latency: Float = 1,
             visibility: @escaping @MainActor (Bool) -> Void = { _ in }) throws {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            renderer = try BendRenderer(device: device)
            let layer = CAMetalLayer()
            layer.device = device
            frames.activate(stream)
            sensor.put(angle: 135, sampledAt: 1, readStartedAt: 0.999)
            let clock = clock
            worker = LiveRenderWorker(layer: layer, renderer: renderer, rate: 120, scale: 2,
                angle: 135, settings: settings, followsSensor: true, sensor: sensor,
                frames: frames, preferredFrameLatency: latency, visibility: visibility, clockFactory: { native in
                    XCTAssertFalse(Thread.isMainThread, "Clock configuration belongs to the worker")
                    XCTAssertEqual(native.preferredFrameLatency, latency)
                    XCTAssertEqual(native.preferredFrameRateRange.maximum, 120)
                    XCTAssertNotNil(native.delegate)
                    XCTAssertTrue(native.isPaused)
                    native.invalidate() // No actual drawable callbacks or GPU submissions in these tests.
                    return clock
                })
            sensor.observe { [weak worker] snapshot in worker?.sensorChanged(snapshot) }
            frames.observe { [weak worker] in worker?.sourceChanged() }
        }
        func supplyFrame() throws {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            _ = frames.put(try XCTUnwrap(buffer), from: stream)
        }
        func motionFrame(at presentationTime: Double, now: Double) throws -> LiveMotionFrame {
            var result: LiveMotionFrame?
            let completed = DispatchSemaphore(value: 0), worker = worker
            XCTAssertTrue(renderer.callbackExecutor {
                result = worker.nextMotionFrame(at: presentationTime, now: now)
                completed.signal()
            })
            XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
            return try XCTUnwrap(result)
        }
        deinit { sensor.observe(nil); frames.observe(nil); worker.stop() }
    }

    func testTwoFrameLatencyConfiguresActualNativeLink() throws {
        let fixture = try Fixture(latency: 2)
        XCTAssertTrue(fixture.clock.isPaused)
    }

    @MainActor
    func testDormantSourceThenDirectThresholdCrossingWakesWithBlockedMain() throws {
        let fixture = try Fixture()
        try fixture.supplyFrame()
        XCTAssertTrue(fixture.clock.isPaused)
        // No UI onChange/update(angle:) call is made. Main cannot process events
        // during the following semaphore wait, but direct sensor wake must run.
        fixture.sensor.put(angle: 75, sampledAt: 2, readStartedAt: 1.999)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(fixture.clock.isPaused)
    }

    func testBentSensorWaitsForSourceThenWakesOnFirstFrame() throws {
        let fixture = try Fixture()
        fixture.sensor.put(angle: 75, sampledAt: 2)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertTrue(fixture.clock.isPaused)
        try fixture.supplyFrame()
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success)
    }

    func testUnavailableHidesInNestedTrackingWithoutUIDelivery() throws {
        let completed = expectation(description: "worker visibility reaches nested loop")
        var hidden = false
        let fixture = try Fixture { visible in
            if !visible { hidden = true; completed.fulfill() }
        }
        try fixture.supplyFrame()
        fixture.sensor.put(angle: 75, sampledAt: 2)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success)
        let nested = expectation(description: "nested main callback finished")
        DispatchQueue.main.async {
            var uiDelivered = false
            DispatchQueue.main.async { uiDelivered = true }
            fixture.sensor.invalidate(at: 3)
            XCTAssertEqual(fixture.clock.pausedAfterResume.wait(timeout: .now() + 2), .success)
            let mode = CFRunLoopMode(rawValue: "NSEventTrackingRunLoopMode" as CFString)
            CFRunLoopAddCommonMode(CFRunLoopGetCurrent(), mode)
            CFRunLoopRunInMode(mode, 0.05, false)
            XCTAssertFalse(uiDelivered, "The fixture must withhold main-dispatch telemetry")
            XCTAssertTrue(hidden, "Hide must occur inside the nested loop, not after UI delivery resumes")
            nested.fulfill()
        }
        wait(for: [completed, nested], timeout: 3)
        XCTAssertTrue(fixture.clock.isPaused)
    }

    func testObserverReorderingCannotRestoreInvalidatedSensor() throws {
        let fixture = try Fixture()
        try fixture.supplyFrame()
        fixture.sensor.put(angle: 75, sampledAt: 2)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success)
        fixture.sensor.invalidate(at: 3)
        XCTAssertEqual(fixture.clock.pausedAfterResume.wait(timeout: .now() + 2), .success)
        // This stale observer event must only wake consumption of current storage.
        fixture.worker.sensorChanged(SensorInputSnapshot(
            reading: TimedAngle(angle: 75, sampledAt: 2), unavailable: false))
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertTrue(fixture.clock.isPaused)
        fixture.sensor.put(angle: 75, sampledAt: 4)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success,
            "Fresh recovery at the same angle must wake after invalidation")
    }

    func testStoppedWorkerRejectsLateSensorAndFrameWake() throws {
        let fixture = try Fixture()
        fixture.worker.stop()
        let stopped = fixture.clock.state
        XCTAssertTrue(stopped.invalidated)
        fixture.sensor.put(angle: 60, sampledAt: 2)
        fixture.sensor.invalidate(at: 3)
        try fixture.supplyFrame()
        fixture.worker.update(angle: 60, settings: EffectSettings(), followsSensor: false)
        XCTAssertEqual(fixture.clock.state.writes, stopped.writes)
        XCTAssertTrue(fixture.clock.isPaused)
    }

    func testPhysicalFrameUsesForecastButManualSimulationDoesNot() throws {
        let fixture = try Fixture()
        try fixture.supplyFrame()
        fixture.sensor.put(angle: 90, sampledAt: 1.1)
        _ = try fixture.motionFrame(at: 1.14, now: 1.1)
        fixture.sensor.put(angle: 86, sampledAt: 1.2)
        _ = try fixture.motionFrame(at: 1.24, now: 1.2)
        let moving = try fixture.motionFrame(at: 1.29, now: 1.25)
        XCTAssertLessThan(moving.angle, 84, "The production worker must bridge sparse sensor samples")
        XCTAssertEqual(moving.target, 86)
        let stale = try fixture.motionFrame(at: 2, now: 1.96)
        XCTAssertEqual(stale.angle, 86, accuracy: 0.01)
        fixture.worker.update(angle: 65, settings: EffectSettings(), followsSensor: false)
        let manual = try fixture.motionFrame(at: 3, now: 2.96)
        XCTAssertEqual(manual.angle, 65, accuracy: 0.01)
        XCTAssertFalse(manual.followsSensor)
        fixture.worker.update(angle: 65, settings: EffectSettings(), followsSensor: true)
        let resumed = try fixture.motionFrame(at: 4, now: 3.96)
        XCTAssertEqual(resumed.angle, 86, accuracy: 0.01, "Mode changes must discard old velocity")
    }

    func testChangingActivationReevaluatesADeadbandReadingWithoutANewSample() throws {
        let fixture = try Fixture()
        var settings = EffectSettings()
        settings.clearAngle = 101
        fixture.worker.update(angle: 135, settings: settings, followsSensor: true)
        try fixture.supplyFrame()
        fixture.sensor.put(angle: 32.05, sampledAt: 2)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success)
        _ = try fixture.motionFrame(at: 2.01, now: 2)
        fixture.sensor.put(angle: 31.95, sampledAt: 2.1)
        XCTAssertEqual(try fixture.motionFrame(at: 2.14, now: 2.1).target, 32.05,
            "The fixture must contain a reading retained by the noise filter")
        XCTAssertEqual(try fixture.motionFrame(at: 2.5, now: 2.49).blackout, 1)
        settings.clearAngle = 100
        fixture.worker.update(angle: 135, settings: settings, followsSensor: true)
        let reconfigured = try fixture.motionFrame(at: 3.01, now: 3)
        XCTAssertEqual(reconfigured.target, 31.95, "Use the existing HID reading with the new threshold")
        XCTAssertEqual(try fixture.motionFrame(at: 3.4, now: 3.39).blackout, 1)
    }

    func testSubDegreeReopeningCannotLeaveTheActualWorkerBlack() throws {
        let fixture = try Fixture(settings: EffectSettings(clearAngle: 100))
        try fixture.supplyFrame()
        fixture.sensor.put(angle: 32.05, sampledAt: 2)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success)
        XCTAssertLessThan(try fixture.motionFrame(at: 2.01, now: 2).blackout, 1)
        fixture.sensor.put(angle: 31.95, sampledAt: 2.1)
        _ = try fixture.motionFrame(at: 2.14, now: 2.1)
        XCTAssertEqual(try fixture.motionFrame(at: 2.5, now: 2.49).blackout, 1)
        fixture.sensor.put(angle: 32.05, sampledAt: 2.6)
        _ = try fixture.motionFrame(at: 2.64, now: 2.6)
        let open = try fixture.motionFrame(at: 3.01, now: 3)
        XCTAssertEqual(open.target, 32.05)
        XCTAssertLessThan(open.blackout, 1)
    }

    func testActualWorkerHoldsPartialOpacityAndResetsAfterSensorFailure() throws {
        let fixture = try Fixture(settings: EffectSettings(clearAngle: 100))
        try fixture.supplyFrame()
        fixture.sensor.put(angle: 38.8, sampledAt: 2)
        XCTAssertEqual(fixture.clock.resumed.wait(timeout: .now() + 2), .success)
        let start = try fixture.motionFrame(at: 2.01, now: 2)
        XCTAssertEqual(start.blackout, 0.5, accuracy: 1e-10)
        XCTAssertEqual(start.angle, 38.8)
        XCTAssertEqual(try fixture.motionFrame(at: 2.185, now: 2.18).blackout, 0.5, accuracy: 1e-10)
        XCTAssertEqual(try fixture.motionFrame(at: 2.38, now: 2.37).blackout, 0.5, accuracy: 1e-10)
        fixture.sensor.put(angle: 50, sampledAt: 3)
        XCTAssertEqual(try fixture.motionFrame(at: 3.01, now: 3).blackout, 0)
        XCTAssertEqual(try fixture.motionFrame(at: 3.4, now: 3.39).blackout, 0)
        fixture.sensor.put(angle: 30, sampledAt: 4)
        _ = try fixture.motionFrame(at: 4.01, now: 4)
        XCTAssertEqual(try fixture.motionFrame(at: 4.4, now: 4.39).blackout, 1)
        fixture.sensor.invalidate(at: 5)
        XCTAssertEqual(fixture.clock.pausedAfterResume.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try fixture.motionFrame(at: 5.01, now: 5).blackout, 0)
        fixture.worker.update(angle: 30, settings: EffectSettings(clearAngle: 100), followsSensor: false)
        let manual = try fixture.motionFrame(at: 6.01, now: 6)
        XCTAssertEqual(manual.blackout, 1)
        XCTAssertFalse(manual.followsSensor)
        XCTAssertEqual(try fixture.motionFrame(at: 6.4, now: 6.39).blackout, 1)
    }

    func testForecastAndOpacityUseTheSameRenderedAngle() throws {
        let fixture = try Fixture(settings: EffectSettings(clearAngle: 100))
        try fixture.supplyFrame()
        fixture.sensor.put(angle: 50, sampledAt: 2)
        _ = try fixture.motionFrame(at: 2.01, now: 2)
        fixture.sensor.put(angle: 42, sampledAt: 2.1)
        let moving = try fixture.motionFrame(at: 2.2, now: 2.16)
        XCTAssertLessThan(moving.angle, 38.8)
        XCTAssertGreaterThan(moving.blackout, 0.5,
            "The visible glass has passed the fade midpoint even though the latest measured angle has not")
        let expired = try fixture.motionFrame(at: 3, now: 2.96)
        XCTAssertEqual(expired.angle, 42, accuracy: 0.01)
        XCTAssertGreaterThan(expired.blackout, 0)
        XCTAssertLessThan(expired.blackout, 0.2)
    }
}
