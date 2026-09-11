// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

/// Run with FOLDELIGHT_GPU_BENCHMARK=1 swift test -c release --filter GPUTracePerformanceTests.
/// These are GPU execution measurements. They do not measure display presentation.
final class GPUTracePerformanceTests: XCTestCase {
    private func requireBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_GPU_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_GPU_BENCHMARK=1 to run release GPU trace benchmarks")
        }
    }
    private func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * q)) - 1))]
    }

    func testChangingContentAndAngleTracesAgainst52bf1ef() throws {
        try requireBenchmark()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        print("GPU_TRACE device=\(device.name) pixels=3024x1964 warmup=30 samples=180 rounds=3 source=initialized lanes=interleaved baseline=52bf1ef")
        for round in 0..<3 {
            for scenario in ["small-damage", "window-damage", "full-damage"] {
                let fixture = try DamageFixture(device: device, width: 3024, height: 1964, readableOutput: false)
                let baseline = try Baseline52BendRenderer(device: device)
                let full = try BendRenderer(device: device), partial = try BendRenderer(device: device)
                let lanes = ["baseline-full", "current-full", "current-partial"]
                var samples = Dictionary(uniqueKeysWithValues: lanes.map { ($0, [Double]()) })
                var pending: [CGRect] = []
                for frame in 0..<210 {
                    let phase = Double(frame % 180) / 179
                    let angle = 101 - 67 * sin(phase * .pi)
                    let progress = Float(EffectSettings.progress(angle: angle, clearAngle: 100))
                    let tilt = Float(EffectSettings.tiltRadians(angle: angle, clearAngle: 100))
                    let uniforms = BendUniforms(progress: progress, blur: 0.5, shadow: 0.3, pixelScale: 2, tiltRadians: tilt)
                    let rect: CGRect
                    if scenario == "full-damage" {
                        rect = CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height)
                    } else {
                        let width = scenario == "small-damage" ? 96 : 720
                        let height = scenario == "small-damage" ? 64 : 480
                        rect = CGRect(x: (frame * 43) % (fixture.width - width),
                                      y: (frame * 29) % (fixture.height - height), width: width, height: height)
                    }
                    fixture.change([rect], frame: frame + 1)
                    pending.append(rect)
                    for offset in lanes.indices {
                        let lane = lanes[(frame + offset + round) % lanes.count]
                        let renderer = lane == "current-full" ? full : partial
                        let command = try XCTUnwrap((lane == "baseline-full" ? baseline.queue : renderer.queue).makeCommandBuffer())
                        if lane == "baseline-full" {
                            try baseline.encode(command: command, pass: fixture.pass, source: fixture.source,
                                uniforms: Baseline52BendUniforms(progress: progress, blur: 0.5, shadow: 0.3,
                                    pixelScale: 2, tiltRadians: tilt), refreshPyramid: true)
                        } else {
                            try renderer.encode(command: command, pass: fixture.pass, source: fixture.source,
                                uniforms: uniforms, refreshPyramid: true,
                                damage: lane == "current-partial" ? pending : nil)
                        }
                        command.commit(); command.waitUntilCompleted()
                        XCTAssertEqual(command.status, .completed); XCTAssertNil(command.error)
                        if frame >= 30 { samples[lane, default: []].append((command.gpuEndTime - command.gpuStartTime) * 1000) }
                    }
                    if uniforms.progress > 0 && uniforms.blurAmount > 0 { pending.removeAll(keepingCapacity: true) }
                }
                for lane in lanes {
                    print(String(format: "GPU_TRACE round=%d scenario=%@ lane=%@ median=%.4f p95=%.4f",
                        round, scenario, lane, quantile(samples[lane]!, 0.5), quantile(samples[lane]!, 0.95)))
                }
                // A relative guard catches a substantial regression while allowing
                // normal contention on a shared GPU. It is not a 120 Hz guarantee.
                let relativeBudget = scenario == "full-damage" ? 1.3 : 0.9
                XCTAssertLessThan(quantile(samples["current-partial"]!, 0.5),
                                  quantile(samples["current-full"]!, 0.5) * relativeBudget)
            }
        }
    }

    func testFinalComputeBarrierCostWithIdenticalContentAndRenderPass() throws {
        try requireBenchmark()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        let fixture = try DamageFixture(device: device, width: 3024, height: 1964, readableOutput: false)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 1512, height: 982, mipmapped: true)
        descriptor.mipmapLevelCount = 8; descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        let pyramid = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let levels = try (0..<8).map {
            try XCTUnwrap(pyramid.makeTextureView(pixelFormat: .bgra8Unorm, textureType: .type2D,
                                                  levels: $0..<($0 + 1), slices: 0..<1))
        }
        for round in 0..<3 {
            var samples = [true: [Double](), false: [Double]()]
            for frame in 0..<140 {
                fixture.change([CGRect(x: (frame * 31) % 2800, y: (frame * 23) % 1700, width: 128, height: 128)], frame: frame)
                for lastBarrier in frame % 2 == 0 ? [true, false] : [false, true] {
                    let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                    let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                    encoder.setComputePipelineState(renderer.gaussianPipelineForTesting)
                    for level in levels.indices {
                        let output = levels[level]
                        encoder.setTexture(level == 0 ? fixture.source : levels[level - 1], index: 0)
                        encoder.setTexture(output, index: 1)
                        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                        if lastBarrier || level < levels.count - 1 { encoder.memoryBarrier(resources: [output]) }
                    }
                    encoder.endEncoding()
                    let render = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: fixture.pass))
                    render.setRenderPipelineState(renderer.pipeline)
                    render.setFragmentTexture(fixture.source, index: 0); render.setFragmentTexture(pyramid, index: 1)
                    var uniforms = BendUniforms(progress: 0.8, blur: 1, shadow: 0.3, pixelScale: 2)
                    render.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 0)
                    render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    render.endEncoding(); command.commit(); command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed); XCTAssertNil(command.error)
                    if frame >= 20 { samples[lastBarrier, default: []].append((command.gpuEndTime - command.gpuStartTime) * 1000) }
                }
            }
            for last in [true, false] {
                print(String(format: "GPU_FINAL_BARRIER round=%d enabled=%d median=%.4f p95=%.4f",
                    round, last ? 1 : 0, quantile(samples[last]!, 0.5), quantile(samples[last]!, 0.95)))
            }
        }
    }

    func testReportAvailableGPUProfilingCapabilities() throws {
        try requireBenchmark()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        print("GPU_CAPABILITIES device=\(device.name) threadExecutionWidth=\(renderer.gaussianPipelineForTesting.threadExecutionWidth) maxThreads=\(renderer.gaussianPipelineForTesting.maxTotalThreadsPerThreadgroup)")
        for set in device.counterSets ?? [] {
            print("GPU_COUNTER_SET \(set.name): \(set.counters.map(\.name).joined(separator: ","))")
        }
        print("GPU_COUNTER_STAGE=\(device.supportsCounterSampling(.atStageBoundary)) GPU_COUNTER_DISPATCH=\(device.supportsCounterSampling(.atDispatchBoundary))")
    }
}
