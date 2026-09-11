// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class PerformanceMetricsTests: XCTestCase {
    func testDisabledAndOldEpochEventsNeverCollect() throws {
        let metrics = PerformanceMetrics()
        metrics.record(.submitted, epoch: 0)
        XCTAssertNil(metrics.currentEpoch())
        XCTAssertEqual(metrics.snapshotAndReset()[.submitted], 0)
        let old = try XCTUnwrap(metrics.setEnabled(true))
        metrics.record(.submitted, epoch: old)
        XCTAssertEqual(metrics.snapshotAndReset()[.submitted], 1)
        metrics.record(.submitted, epoch: old)
        let fresh = try XCTUnwrap(metrics.currentEpoch())
        metrics.record(.skippedBusy, epoch: fresh)
        XCTAssertNil(metrics.setEnabled(false))
        metrics.record(.failed, epoch: fresh)
        let snapshot = metrics.snapshotAndReset()
        XCTAssertTrue(snapshot.counters.isEmpty)
        XCTAssertTrue(snapshot.distributions.isEmpty)
    }

    func testActualCallbacksAreDistinctFromScheduledTimesAndDirtySkips() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        for (arrival, expected) in [(1.0, 1.01), (1.025, 1.02), (1.03, 1.03)] {
            metrics.record(.callback(arrival: arrival, expectedPresentation: expected, deadline: expected - 0.002), epoch: token)
        }
        metrics.record(.skippedClean, epoch: token)
        metrics.record(.skippedBusy, epoch: token)
        metrics.record(.submitted, epoch: token)
        let result = metrics.snapshotAndReset()
        XCTAssertEqual(result[.callbacks], 3)
        XCTAssertEqual(result[.skippedClean], 1)
        XCTAssertEqual(result[.skippedBusy], 1)
        XCTAssertEqual(result[.submitted], 1)
        XCTAssertEqual(try XCTUnwrap(result[.callbackInterval]).maximum, 25, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.expectedPresentationInterval]).maximum, 10, accuracy: 0.000001)
        XCTAssertLessThan(try XCTUnwrap(result[.callbackDeadlineMargin]).minimum, 0)
    }

    func testCommitDeadlineDoesNotStandInForPresentRequestDeadline() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        metrics.record(.commit(at: 1, deadline: 1.005), epoch: token)
        metrics.record(.presentRequested(at: 1.007, deadline: 1.005), epoch: token)
        let result = metrics.snapshotAndReset()
        XCTAssertEqual(result[.cpuCommitDeadlineMisses], 0)
        XCTAssertEqual(result[.presentRequestDeadlineMisses], 1)
        XCTAssertEqual(try XCTUnwrap(result[.presentRequestMargin]).p50, -2, accuracy: 0.000001)
    }

    func testFirstPresentationAndSettlingUseObservedPopulation() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        metrics.record(.sensorRead(id: 1, start: 1, end: 1.002, targetAngle: 80), epoch: token)
        metrics.record(.sensorRead(id: 2, start: 1.010, end: 1.012, targetAngle: 70), epoch: token)
        metrics.record(.presentation(at: 1.020, frame: PerformanceFrameTiming(sensorID: 2,
            sourceDisplayTime: 1.015, targetAngle: 70, renderedAngle: 75)), epoch: token)
        metrics.record(.presentation(at: 1.030, frame: PerformanceFrameTiming(sensorID: 2,
            targetAngle: 70, renderedAngle: 70.005)), epoch: token)
        let result = metrics.snapshotAndReset()
        XCTAssertEqual(result[.sensorReads], 2)
        XCTAssertEqual(result[.sensorFirstPresented], 1)
        XCTAssertEqual(result[.sensorSettled], 1)
        XCTAssertEqual(result[.sensorSupersededUnpresented], 1)
        XCTAssertEqual(result.sensorUnpresented, 1)
        XCTAssertEqual(result.sensorUnsettled, 1)
        XCTAssertEqual(try XCTUnwrap(result[.sensorReadStartToFirstPresent]).p50, 10, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.sensorReadEndToFirstPresent]).p50, 8, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.sensorReadEndToSettled]).p50, 18, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.sourceDisplayToPresent]).p50, 5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.angleError]).maximum, 5)
    }

    func testUnobservedSensorFramesDoNotInventReadPopulation() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        metrics.record(.presentation(at: 5, frame: PerformanceFrameTiming(sensorID: 99,
            sensorReadStart: 4, sensorReadEnd: 4.1, targetAngle: 80, renderedAngle: 80)), epoch: token)
        let result = metrics.snapshotAndReset()
        XCTAssertEqual(result[.sensorReads], 0)
        XCTAssertEqual(result[.sensorFirstPresented], 0)
        XCTAssertEqual(result[.sensorUntrackedPresentations], 1)
        XCTAssertNil(result[.sensorReadStartToFirstPresent])
    }

    func testOutOfOrderPresentationCallbacksUseActualChronologicalTimes() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        metrics.record(.sensorRead(id: 1, start: 1, end: 1.001, targetAngle: 50), epoch: token)
        for time in [1.030, 1.010, 1.020] {
            metrics.record(.presentation(at: time, frame: PerformanceFrameTiming(sensorID: 1,
                targetAngle: 50, renderedAngle: 50)), epoch: token)
        }
        let result = metrics.snapshotAndReset()
        XCTAssertEqual(try XCTUnwrap(result.presentationFPS), 100, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.presentationInterval]).maximum, 10, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.sensorReadStartToFirstPresent]).p50, 10, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.sensorReadEndToSettled]).p50, 9, accuracy: 0.000001)
        XCTAssertEqual(result[.sensorFirstPresented], 1)
    }

    func testBoundedRecentPercentilesAndLifetimeCounts() throws {
        let metrics = PerformanceMetrics(capacity: 3)
        let token = try XCTUnwrap(metrics.setEnabled(true))
        for index in 1...10 {
            metrics.record(.submitted, epoch: token)
            metrics.record(.gpu(seconds: Double(index) / 1000), epoch: token)
            metrics.record(.sensorRead(id: UInt64(index), start: Double(index), end: Double(index) + 0.001, targetAngle: 50), epoch: token)
        }
        let result = metrics.snapshotAndReset()
        XCTAssertEqual(result[.submitted], 10)
        XCTAssertEqual(result[.sensorTrackingEvictions], 7)
        XCTAssertEqual(try XCTUnwrap(result[.gpu]), PerformancePercentiles([8, 9, 10]))
    }

    func testPercentilesUseNearestRankAndRejectInvalidDurations() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        for value in 1...100 { metrics.record(.cpuEncode(seconds: Double(value) / 1000), epoch: token) }
        metrics.record(.cpuEncode(seconds: -.infinity), epoch: token)
        metrics.record(.gpu(seconds: -1), epoch: token)
        metrics.record(.presentation(at: .nan, frame: PerformanceFrameTiming()), epoch: token)
        let result = metrics.snapshotAndReset()
        let values = try XCTUnwrap(result[.cpuEncode])
        XCTAssertEqual(values.p50, 50)
        XCTAssertEqual(values.p95, 95)
        XCTAssertEqual(values.p99, 99)
        XCTAssertEqual(values.maximum, 100)
        XCTAssertEqual(result[.invalidEvents], 3)
    }

    func testGeneratedCounterTransitionsMatchIndependentStateModel() throws {
        let metrics = PerformanceMetrics(capacity: 7)
        var token = try XCTUnwrap(metrics.setEnabled(true))
        var state: UInt64 = 0xF01DE11A
        var expected = [PerformanceCounter: Int]()
        for _ in 0..<20_000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            switch state % 7 {
            case 0: metrics.record(.submitted, epoch: token); expected[.submitted, default: 0] += 1
            case 1: metrics.record(.skippedBusy, epoch: token); expected[.skippedBusy, default: 0] += 1
            case 2: metrics.record(.skippedClean, epoch: token); expected[.skippedClean, default: 0] += 1
            case 3: metrics.record(.failed, epoch: token); expected[.failed, default: 0] += 1
            case 4: metrics.record(.submitted, epoch: token &- 1)
            case 5:
                XCTAssertEqual(metrics.snapshotAndReset().counters, expected)
                expected = [:]; token = try XCTUnwrap(metrics.currentEpoch())
            default:
                metrics.setEnabled(false)
                metrics.record(.submitted, epoch: token)
                expected = [:]
                token = try XCTUnwrap(metrics.setEnabled(true))
            }
        }
        XCTAssertEqual(metrics.snapshotAndReset().counters, expected)
    }

    func testPresentationSeparatesCallbackAgeTargetErrorAndGPUQueueDelay() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        metrics.record(.gpuQueueDelay(seconds: 0.003), epoch: token)
        metrics.record(.gpu(seconds: 0.005), epoch: token)
        metrics.record(.presentation(at: 1.050, frame: PerformanceFrameTiming(
            callbackArrival: 1, expectedPresentationTime: 1.025)), epoch: token)
        metrics.record(.presentation(at: 1.080, frame: PerformanceFrameTiming(
            callbackArrival: 1.070, expectedPresentationTime: 1.085)), epoch: token)
        let result = metrics.snapshotAndReset()
        XCTAssertEqual(try XCTUnwrap(result[.callbackToPresent]).maximum, 50, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.presentationTargetError]).maximum, 25, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.presentationTargetError]).minimum, -5, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.gpuQueueDelay]).p50, 3, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result[.gpu]).p50, 5, accuracy: 0.000001)
    }

    func testUnavailableTimingDoesNotInventCompositorMeasurements() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        metrics.record(.presentation(at: 1, frame: PerformanceFrameTiming()), epoch: token)
        metrics.record(.presentation(at: 2, frame: PerformanceFrameTiming(
            callbackArrival: .nan, expectedPresentationTime: .infinity)), epoch: token)
        metrics.record(.presentation(at: 3, frame: PerformanceFrameTiming(callbackArrival: 4)), epoch: token)
        metrics.record(.gpuQueueDelay(seconds: -1), epoch: token)
        let result = metrics.snapshotAndReset()
        XCTAssertNil(result[.callbackToPresent])
        XCTAssertNil(result[.presentationTargetError])
        XCTAssertNil(result[.gpuQueueDelay])
        XCTAssertEqual(result[.invalidEvents], 1)
    }

    func testConcurrentCollectorsLoseNoEvents() throws {
        let metrics = PerformanceMetrics()
        let token = try XCTUnwrap(metrics.setEnabled(true))
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in metrics.record(.submitted, epoch: token) }
        XCTAssertEqual(metrics.snapshotAndReset()[.submitted], 10_000)
    }
}
