// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

/// Opt-in, visible native-resolution presentation experiments. This exercises
/// the production worker and compositor, but uses synthetic input, not HID or
/// ScreenCaptureKit. Each window closes automatically after its short trace.
final class LivePresentationTests: XCTestCase {
    @MainActor
    func testNativeAnglePacedBlackoutHoldsReopensAndRecoversExpiredPrediction() async throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_LIVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_LIVE_BENCHMARK=1 for native blackout lifecycle verification")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let overlay = try DesktopOverlayPolicy.make(screen: screen, device: device)
        let renderer = try BendRenderer(device: device)
        let settings = EffectSettings()
        let foldStop = settings.clearAngle - EffectSettings.maximumTiltDegrees
        let sensor = LatestAngleInput(), frames = CaptureMailbox(), stream = NSObject()
        frames.activate(stream)
        let worker = LiveRenderWorker(layer: overlay.layer, renderer: renderer,
            rate: screen.maximumFramesPerSecond, scale: Float(screen.backingScaleFactor),
            angle: 0, settings: settings, followsSensor: false, sensor: sensor, frames: frames,
            metricsEnabled: { true }, visibility: { visible in
                if visible { overlay.panel.orderFrontRegardless() } else { overlay.panel.orderOut(nil) }
            })
        defer { sensor.observe(nil); frames.observe(nil); worker.stop(); overlay.panel.orderOut(nil) }
        frames.observe { [weak worker] in worker?.sourceChanged() }
        _ = frames.put(try artwork(width: Int(overlay.layer.drawableSize.width),
                                  height: Int(overlay.layer.drawableSize.height)), from: stream)
        func currentOpacity() async -> Double {
            await withCheckedContinuation { continuation in
                _ = renderer.callbackExecutor { continuation.resume(returning: renderer.blackout) }
            }
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        let closing = renderer.metrics.snapshotAndReset()
        let closedOpacity = await currentOpacity()
        XCTAssertEqual(closedOpacity, 1)
        XCTAssertEqual(closing[.submitted], 1, "A held maximum fold is immediately black and does not keep fading")
        XCTAssertEqual(closing[.failed], 0)
        XCTAssertTrue(overlay.panel.isVisible)
        try await Task.sleep(nanoseconds: 150_000_000)
        let dormant = renderer.metrics.snapshotAndReset()
        XCTAssertEqual(dormant[.submitted], 0)
        XCTAssertLessThanOrEqual(dormant[.callbacks], 1)
        worker.update(angle: foldStop + 8, settings: settings, followsSensor: false)
        try await Task.sleep(nanoseconds: 700_000_000)
        let opening = renderer.metrics.snapshotAndReset()
        let openedOpacity = await currentOpacity()
        XCTAssertGreaterThan(openedOpacity, 0.35)
        XCTAssertLessThan(openedOpacity, 0.40)
        XCTAssertGreaterThan(opening[.submitted], 0, "The identical initial black frame must not strand reopening")
        XCTAssertEqual(opening[.failed], 0)
        try await Task.sleep(nanoseconds: 150_000_000)
        let heldOpacity = await currentOpacity()
        XCTAssertEqual(heldOpacity, openedOpacity, "Pausing the lid pauses the fade")
        let held = renderer.metrics.snapshotAndReset()
        XCTAssertEqual(held[.submitted], 0)
        XCTAssertLessThanOrEqual(held[.callbacks], 1)
        // A forecast can enter the black region before the measured lid does.
        // Its expiry must complete smoothing back out, without another input.
        sensor.observe { [weak worker] in worker?.sensorChanged($0) }
        worker.update(angle: foldStop + 18, settings: settings, followsSensor: true)
        sensor.put(angle: foldStop + 18, sampledAt: CACurrentMediaTime())
        try await Task.sleep(nanoseconds: 100_000_000)
        sensor.put(angle: foldStop + 3, sampledAt: CACurrentMediaTime())
        try await Task.sleep(nanoseconds: 60_000_000)
        let forecastOpacity = await currentOpacity()
        XCTAssertEqual(forecastOpacity, 1, "The fixture must first render an opaque-black forecast")
        try await Task.sleep(nanoseconds: 400_000_000)
        let recoveredOpacity = await currentOpacity()
        XCTAssertGreaterThan(recoveredOpacity, 0.8)
        XCTAssertLessThan(recoveredOpacity, 0.95, "An expired forecast must not strand a black frame")
        _ = renderer.metrics.snapshotAndReset()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(renderer.metrics.snapshotAndReset()[.callbacks], 0)
        print("BLACKOUT_LIVE closing_submitted=\(closing[.submitted]) opening_submitted=\(opening[.submitted]) dormant_callbacks=\(dormant[.callbacks]) dormant_submitted=\(dormant[.submitted])")
    }

    @MainActor
    func testNativeSparseSensorPresentation() async throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_LIVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_LIVE_BENCHMARK=1 for the native 10 Hz sensor comparison.")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let buffer = try artwork(width: Int(screen.frame.width * screen.backingScaleFactor),
                                 height: Int(screen.frame.height * screen.backingScaleFactor))
        var measuredFPS: [Double] = []
        for lane in 0..<3 {
            let overlay = try DesktopOverlayPolicy.make(screen: screen, device: device)
            let renderer = try BendRenderer(device: device)
            let sensor = LatestAngleInput(), frames = CaptureMailbox(), stream = NSObject()
            frames.activate(stream)
            let predicted = lane == 2
            let worker = LiveRenderWorker(layer: overlay.layer, renderer: renderer,
                rate: screen.maximumFramesPerSecond, scale: Float(screen.backingScaleFactor),
                angle: 75, settings: EffectSettings(), followsSensor: true, sensor: sensor, frames: frames,
                predictsSensorMotion: predicted, metricsEnabled: { true }, visibility: { visible in
                    if visible { overlay.panel.orderFrontRegardless() } else { overlay.panel.orderOut(nil) }
                })
            sensor.observe { [weak worker] in worker?.sensorChanged($0) }
            frames.observe { [weak worker] in worker?.sourceChanged() }
            _ = frames.put(buffer, from: stream)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "foldelight.sparse-input", qos: .userInteractive))
            let start = CACurrentMediaTime()
            var lastAngle: Double?
            timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .nanoseconds(0))
            timer.setEventHandler {
                let time = CACurrentMediaTime(), ideal = 50 + 25 * cos((time - start) * 2.1)
                let angle = lane == 0 ? ideal.rounded() : (ideal * 100).rounded() / 100
                if angle != lastAngle {
                    lastAngle = angle
                    sensor.put(angle: angle, sampledAt: time, readStartedAt: time)
                }
            }
            timer.resume()
            defer {
                timer.cancel(); sensor.observe(nil); frames.observe(nil)
                worker.stop(); overlay.panel.orderOut(nil)
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            _ = renderer.metrics.snapshotAndReset()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let snapshot = renderer.metrics.snapshotAndReset()
            let label = ["coarse-measured", "fine-measured", "fine-predicted"][lane]
            log(snapshot, round: lane, inFlight: 1, latency: 1, pool: 3, phase: "10Hz-" + label)
            measuredFPS.append(snapshot.presentationFPS ?? 0)
            XCTAssertEqual(snapshot[.failed], 0)
            // A static source exposes the old path's one-frame-per-report
            // behavior. Do not require its baseline to animate between reads.
            XCTAssertGreaterThan(snapshot[.submitted], predicted ? 180 : 20)
            timer.cancel()
            try await Task.sleep(nanoseconds: 400_000_000)
            _ = renderer.metrics.snapshotAndReset()
            try await Task.sleep(nanoseconds: 100_000_000)
            let idle = renderer.metrics.snapshotAndReset()
            XCTAssertEqual(idle[.submitted], 0, "\(label) must settle when reports stop")
            XCTAssertLessThanOrEqual(idle[.callbacks], 1, "\(label) must stop its idle clock")
            worker.stop(); overlay.panel.orderOut(nil)
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        XCTAssertGreaterThan(measuredFPS[2], measuredFPS[0] * 1.2,
            "The measured sparse-input path must present more consistently than the old quantized path")
    }

    @MainActor
    func testFirstSlightFoldRemainsVisibleWithoutFurtherInput() async throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_LIVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_LIVE_BENCHMARK=1 for native activation verification.")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let overlay = try DesktopOverlayPolicy.make(screen: screen, device: device)
        let renderer = try BendRenderer(device: device)
        let sensor = LatestAngleInput(), frames = CaptureMailbox(), stream = NSObject()
        frames.activate(stream)
        var settings = EffectSettings()
        settings.clearAngle = 135
        var visibility: [Bool] = []
        let worker = LiveRenderWorker(layer: overlay.layer, renderer: renderer,
            rate: screen.maximumFramesPerSecond, scale: Float(screen.backingScaleFactor),
            angle: 150, settings: settings, followsSensor: true, sensor: sensor, frames: frames,
            metricsEnabled: { true }, visibility: { visible in
                visibility.append(visible)
                if visible { overlay.panel.orderFrontRegardless() } else { overlay.panel.orderOut(nil) }
            })
        defer {
            sensor.observe(nil); frames.observe(nil)
            worker.stop(); overlay.panel.orderOut(nil)
        }
        sensor.observe { [weak worker] in worker?.sensorChanged($0) }
        frames.observe { [weak worker] in worker?.sourceChanged() }
        _ = frames.put(try artwork(width: Int(overlay.layer.drawableSize.width),
                                  height: Int(overlay.layer.drawableSize.height)), from: stream)
        // One degree below activation, then no further sensor or source wake.
        let now = CACurrentMediaTime()
        sensor.put(angle: 134, sampledAt: now, readStartedAt: now)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(visibility.last, true, "An old open angle must not hide the first slight fold")
        XCTAssertTrue(overlay.panel.isVisible)
        let snapshot = renderer.metrics.snapshotAndReset()
        print("ACTIVATION_TRACE callbacks=\(snapshot[.callbacks]) submitted=\(snapshot[.submitted]) presented=\(snapshot[.presented]) clean=\(snapshot[.skippedClean]) busy=\(snapshot[.skippedBusy]) failures=\(snapshot[.failed]) visibility=\(visibility)")
        XCTAssertEqual(snapshot[.submitted], 1)
        XCTAssertEqual(snapshot[.gpu]?.count, 1, "The isolated frame must complete on the GPU")
        XCTAssertEqual(snapshot[.failed], 0)
        XCTAssertGreaterThan(snapshot[.skippedClean], 0)
        // A composed recording verified this frame on macOS 15.1.1 even when
        // addPresentedHandler never fired. A lone drawable is not a reliable
        // presentation-timestamp instrument on this host.
        try await Task.sleep(nanoseconds: 100_000_000)
        let idle = renderer.metrics.snapshotAndReset()
        XCTAssertEqual(idle[.submitted], 0, "A still desktop must not redraw continuously")
        XCTAssertLessThanOrEqual(idle[.callbacks], 1, "The clock must pause after the frame settles")
    }

    @MainActor
    func testNativePresentationTraceAndMainThreadStall() async throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_LIVE_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_LIVE_BENCHMARK=1 to show the native presentation benchmark.")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32).map { CGDisplayIsBuiltin($0) != 0 } ?? false
        })
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let width = Int(screen.frame.width * screen.backingScaleFactor)
        let height = Int(screen.frame.height * screen.backingScaleFactor)
        let buffer = try artwork(width: width, height: height)
        let rounds = Int(ProcessInfo.processInfo.environment["FOLDELIGHT_LIVE_ROUNDS"] ?? "2") ?? 2
        print("LIVE_TRACE device=\(device.name) pixels=\(width)x\(height) refresh=\(screen.maximumFramesPerSecond) synthetic-angle fixed-source excludes-HID-and-capture")
        for round in 0..<max(1, min(3, rounds)) {
            let pools = ProcessInfo.processInfo.environment["FOLDELIGHT_LIVE_POOL_BENCHMARK"] == "1"
            let choices = pools ? [(1, 1, 2), (1, 1, 3), (1, 2, 2), (1, 2, 3)] : [(1, 1, 3), (2, 1, 3), (1, 2, 3), (2, 2, 3)]
            for offset in choices.indices {
                let (inFlight, latency, pool) = choices[(offset + round) % choices.count]
                let overlay = try DesktopOverlayPolicy.make(screen: screen, device: device)
                let panel = overlay.panel
                panel.isReleasedWhenClosed = false
                let layer = overlay.layer
                layer.maximumDrawableCount = pool
                let renderer = try BendRenderer(device: device, maxFramesInFlight: inFlight)
                let sensor = LatestAngleInput(), frames = CaptureMailbox(), stream = NSObject()
                frames.activate(stream)
                let worker = LiveRenderWorker(layer: layer, renderer: renderer,
                    rate: screen.maximumFramesPerSecond, scale: Float(screen.backingScaleFactor),
                    angle: 85, settings: EffectSettings(), followsSensor: true, sensor: sensor, frames: frames,
                    preferredFrameLatency: Float(latency), metricsEnabled: { true }, visibility: { [weak panel] visible in
                        if visible { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
                    })
                sensor.observe { [weak worker] in worker?.sensorChanged($0) }
                frames.observe { [weak worker] in worker?.sourceChanged() }
                _ = frames.put(buffer, from: stream)
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "foldelight.trace-input", qos: .userInteractive))
                let start = CACurrentMediaTime()
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 120), leeway: .nanoseconds(0))
                timer.setEventHandler {
                    let time = CACurrentMediaTime()
                    let angle = 62 + 22 * cos((time - start) * 2.1)
                    sensor.put(angle: angle, sampledAt: time, readStartedAt: time)
                }
                timer.resume()
                defer {
                    timer.cancel()
                    sensor.observe(nil); frames.observe(nil)
                    worker.stop()
                    panel.orderOut(nil); panel.close()
                }
                // Exclude initial allocation and first-window presentation.
                try await Task.sleep(nanoseconds: 500_000_000)
                _ = renderer.metrics.snapshotAndReset()
                try await Task.sleep(nanoseconds: 1_300_000_000)
                let normal = renderer.metrics.snapshotAndReset()
                log(normal, round: round, inFlight: inFlight, latency: latency, pool: pool, phase: "steady")
                let stallStart = CACurrentMediaTime()
                // Deliberately stall main while the real render loop continues.
                blockMainThread(for: 0.150)
                let stalled = renderer.metrics.snapshotAndReset()
                let duration = CACurrentMediaTime() - stallStart
                log(stalled, round: round, inFlight: inFlight, latency: latency, pool: pool, phase: "main-stalled")
                XCTAssertGreaterThan(normal[.presented], 20, "The production worker must present a moving trace")
                XCTAssertGreaterThan(stalled[.presented], 2, "Main work must not stop active presentation")
                XCTAssertLessThan(duration, 0.5, "The deliberate 150 ms stall must stay bounded")
                XCTAssertEqual(normal[.failed], 0)
                XCTAssertEqual(stalled[.failed], 0)
                timer.cancel()
                sensor.observe(nil); frames.observe(nil)
                worker.stop()
                panel.orderOut(nil)
                try await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    /// This synchronous helper deliberately blocks the native benchmark. An
    /// async suspension would not exercise independence from the main thread.
    @MainActor
    private func blockMainThread(for duration: TimeInterval) {
        Thread.sleep(forTimeInterval: duration)
    }

    private func log(_ snapshot: PerformanceSnapshot, round: Int, inFlight: Int, latency: Int, pool: Int, phase: String) {
        func metric(_ key: PerformanceDistribution, _ value: KeyPath<PerformancePercentiles, Double>) -> Double {
            snapshot[key].map { $0[keyPath: value] } ?? -1
        }
        print(String(format: "LIVE_TRACE round=%d inFlight=%d latency=%d pool=%d phase=%@ callbacks=%d submitted=%d presented=%d clean=%d busy=%d failures=%d fps=%.2f arrivalP99=%.3f presentP99=%.3f gpuP50=%.3f gpuP99=%.3f sensorP50=%.3f sensorP99=%.3f callbackToPresentP50=%.3f targetErrorP50=%.3f gpuQueueP99=%.3f requestMisses=%d",
            round, inFlight, latency, pool, phase, snapshot[.callbacks], snapshot[.submitted], snapshot[.presented],
            snapshot[.skippedClean], snapshot[.skippedBusy], snapshot[.failed], snapshot.presentationFPS ?? 0,
            metric(.callbackInterval, \.p99), metric(.presentationInterval, \.p99), metric(.gpu, \.p50), metric(.gpu, \.p99),
            metric(.sensorReadEndToFirstPresent, \.p50), metric(.sensorReadEndToFirstPresent, \.p99), metric(.callbackToPresent, \.p50),
            metric(.presentationTargetError, \.p50), metric(.gpuQueueDelay, \.p99), snapshot[.presentRequestDeadlineMisses]))
    }

    @MainActor
    private func artwork(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                                         kCVPixelBufferMetalCompatibilityKey as String: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(result), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(result), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let image = try XCTUnwrap(PreviewArtwork.image().cgImage(forProposedRect: nil, context: nil, hints: nil))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return result
    }
}
