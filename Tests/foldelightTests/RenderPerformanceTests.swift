// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
import MetalPerformanceShaders
@testable import foldelight

/// Opt-in actual-GPU measurements. FOLDELIGHT_GPU_BENCHMARK=1 swift test --filter RenderPerformanceTests
/// GPU execution only: excludes capture, drawable acquisition, CPU submission and display presentation.
final class RenderPerformanceTests: XCTestCase {
    private func initializeDetailedSource(_ source: MTLTexture) {
        let width = source.width, height = source.height
        var pixels = [UInt32](repeating: 0xff000000, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] |= UInt32((x * 17 + y * 3) & 255)
                    | UInt32((x + y * 13) & 255) << 8 | UInt32((x * 7 + y) & 255) << 16
            }
        }
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
    }

    func testGaussianBlurRemovesHighFrequencyAliasingAndRefreshes() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        let size = 128
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let checker = (0..<size * size).map { (($0 % size + $0 / size) % 2 == 0) ? UInt32.max : 0xff000000 }
        checker.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: size * 4) }
        func render(blur: Float, refresh: Bool) throws -> [UInt8] {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            try renderer.encode(command: command, pass: pass, source: input,
                uniforms: BendUniforms(progress: 0.8, blur: blur, shadow: 0),
                refreshPyramid: refresh)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            XCTAssertNil(command.error)
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
            return bytes
        }
        func centerContrast(_ bytes: [UInt8]) -> Int {
            let samples = (56..<72).flatMap { y in (56..<72).map { x in Int(bytes[(y * size + x) * 4]) } }
            return samples.max()! - samples.min()!
        }
        // Fixed projection resamples the checker even at zero blur; aliasing must remain visible.
        XCTAssertGreaterThan(centerContrast(try render(blur: 0, refresh: true)), 100)
        let blurred = try render(blur: 1, refresh: true)
        XCTAssertLessThan(centerContrast(blurred), 10, "Gaussian filtering must remove one-pixel checker aliasing.")
        XCTAssertEqual(try render(blur: 1, refresh: false), blurred, "A stationary desktop must reuse the same pyramid.")
        XCTAssertEqual(try render(blur: 0.02, refresh: false), try render(blur: 0.02, refresh: true),
            "Reducing cached blur must initialize the sharp base level before it can be sampled.")
        let black = [UInt32](repeating: 0xff000000, count: size * size)
        black.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: size * 4) }
        let updated = try render(blur: 1, refresh: true)
        XCTAssertLessThan(updated[(64 * size + 64) * 4], 25, "New capture content must replace cached blur.")
        XCTAssertNotEqual(updated, blurred)
    }

    func testNativePyramidOmitsUnusedFullResolutionLevel() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        let width = 3024, height = 1964
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDescriptor))
        initializeDetailedSource(source)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 16, height: 16, mipmapped: false)
        targetDescriptor.storageMode = .private
        targetDescriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .dontCare
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        try renderer.encode(command: command, pass: pass, source: source,
            uniforms: BendUniforms(progress: 0.5, blur: 0.5, shadow: 0))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertLessThan(renderer.pyramidAllocatedBytesForTesting, 10 * 1024 * 1024,
                          "The blur cache must not reserve a native full-resolution mip level")
        XCTAssertGreaterThan(renderer.pyramidAllocatedBytesForTesting, 0)
    }

    func testPyramidBuildExpandsOnlyAsTheOpticalRadiusNeedsIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 3024, height: 1964, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDescriptor))
        initializeDetailedSource(source)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 16, height: 16, mipmapped: false)
        targetDescriptor.storageMode = .private
        targetDescriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .dontCare

        func encode(_ uniforms: BendUniforms, refresh: Bool) throws {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            try renderer.encode(command: command, pass: pass, source: source,
                                uniforms: uniforms, refreshPyramid: refresh)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
        }

        let slight = BendUniforms(
            progress: Float(EffectSettings.progress(angle: 99.4, clearAngle: 100)),
            blur: 0.5, shadow: 0.3, pixelScale: 2,
            tiltRadians: Float(EffectSettings.tiltRadians(angle: 99.4, clearAngle: 100)))
        try encode(slight, refresh: true)
        XCTAssertEqual(renderer.pyramidValidLevelCountForTesting, 1)

        let deep = BendUniforms(progress: 1, blur: 0.5, shadow: 0.3,
                                pixelScale: 2, tiltRadians: 68 * .pi / 180)
        try encode(deep, refresh: false)
        XCTAssertEqual(renderer.pyramidValidLevelCountForTesting, 8)
    }

    func testGaussianThreadgroupPerformance() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_GPU_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_GPU_BENCHMARK=1 to run the threadgroup benchmark.")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 3024, height: 1964, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: sourceDescriptor))
        initializeDetailedSource(source)
        let pyramidDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 1512, height: 982, mipmapped: true)
        pyramidDescriptor.mipmapLevelCount = 8
        pyramidDescriptor.storageMode = .private
        pyramidDescriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
        let pyramid = try XCTUnwrap(device.makeTexture(descriptor: pyramidDescriptor))
        let levels = try (0..<8).map { level in
            try XCTUnwrap(pyramid.makeTextureView(pixelFormat: .bgra8Unorm, textureType: .type2D,
                                                  levels: level..<(level + 1), slices: 0..<1))
        }
        let candidates = [MTLSize(width: 8, height: 8, depth: 1),
                          MTLSize(width: 16, height: 8, depth: 1),
                          MTLSize(width: 32, height: 4, depth: 1),
                          MTLSize(width: 32, height: 8, depth: 1)]
        var samples = Dictionary(uniqueKeysWithValues: candidates.map { ($0.width * 1_000 + $0.height, [Double]()) })
        for iteration in 0..<60 {
            for offset in candidates.indices {
                let candidate = candidates[(iteration + offset) % candidates.count]
                let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                encoder.setComputePipelineState(renderer.gaussianPipelineForTesting)
                for level in levels.indices {
                    let output = levels[level]
                    encoder.setTexture(level == 0 ? source : levels[level - 1], index: 0)
                    encoder.setTexture(output, index: 1)
                    encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                            threadsPerThreadgroup: candidate)
                    encoder.memoryBarrier(resources: [output])
                }
                encoder.endEncoding()
                command.commit()
                command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                if iteration >= 10 {
                    samples[candidate.width * 1_000 + candidate.height, default: []]
                        .append((command.gpuEndTime - command.gpuStartTime) * 1_000)
                }
            }
        }
        for candidate in candidates {
            let values = samples[candidate.width * 1_000 + candidate.height]!.sorted()
            print(String(format: "GPU_THREADGROUP %dx%d median=%.3f p95=%.3f",
                         candidate.width, candidate.height, values[25], values[47]))
            XCTAssertLessThan(values[47], 8.333)
        }
    }

    func testOffscreenGPUPerformance() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_GPU_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_GPU_BENCHMARK=1 to run the warmed GPU benchmark.")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let sourceURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/LegacyBend.metal")
        let library = try device.makeLibrary(source: String(contentsOf: sourceURL), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "bendVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "bendFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let renderer = try BendRenderer(device: device)
        // Native quality preserves blur radius in points (pixelScale=2). Legacy ignores this extra field.
        // These lanes compare delivered quality and cost, not mathematically identical filters.
        let mps = MPSImageGaussianPyramid(device: device)
        mps.edgeMode = .clamp
        print("GPU_BENCH device=\(device.name) warmup=20 samples=60 GPU-only milliseconds")
        for (width, height) in [(1512, 982), (3024, 1964)] {
            let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            inputDescriptor.storageMode = .shared
            inputDescriptor.usage = .shaderRead
            let input = try XCTUnwrap(device.makeTexture(descriptor: inputDescriptor))
            // Fine deterministic pattern exercises texture sampling rather than uniform clears.
            let pixels = (0..<width * height).map { index -> UInt32 in
                let x = index % width, y = index / width
                return 0xff000000 | UInt32((x * 17 + y * 3) & 255) | UInt32((x + y * 13) & 255) << 8 | UInt32((x * 7 + y) & 255) << 16
            }
            pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            outputDescriptor.storageMode = .private
            outputDescriptor.usage = .renderTarget
            let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let mpsDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: width, height: height, mipmapped: true)
            mpsDescriptor.mipmapLevelCount = min(mpsDescriptor.mipmapLevelCount, GaussianPyramidPlan.maximumLevels + 1)
            mpsDescriptor.storageMode = .private
            mpsDescriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
            var mpsTexture = try XCTUnwrap(device.makeTexture(descriptor: mpsDescriptor))
            let reuseRenderer = try BendRenderer(device: device)
            let lanes = ["legacy", "mps-fresh", "gaussian-fresh", "gaussian-reuse"]
            var laneSamples = Dictionary(uniqueKeysWithValues: lanes.map { ($0, [Double]()) })
            for iteration in 0..<80 {
                for offset in lanes.indices {
                    let lane = lanes[(iteration + offset) % lanes.count]
                    let productionRenderer = lane == "gaussian-reuse" ? reuseRenderer : renderer
                    let command = try XCTUnwrap((lane == "legacy" ? queue : productionRenderer.queue).makeCommandBuffer())
                    var uniforms = BendUniforms(progress: 0.8, blur: 1, shadow: 1, pixelScale: width == 3024 ? 2 : 1)
                    if lane == "mps-fresh" {
                        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
                        blit.copy(from: input, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                            sourceSize: MTLSize(width: width, height: height, depth: 1), to: mpsTexture,
                            destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                        blit.endEncoding()
                        XCTAssertTrue(mps.encode(commandBuffer: command, inPlaceTexture: &mpsTexture, fallbackCopyAllocator: nil))
                    }
                    if lane == "legacy" || lane == "mps-fresh" {
                        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
                        encoder.setRenderPipelineState(lane == "legacy" ? pipeline : productionRenderer.pipeline)
                        encoder.setFragmentTexture(input, index: 0)
                        if lane == "mps-fresh" {
                            // Production indices begin at half resolution. MPS writes its
                            // native source at mip zero, so expose only levels one onward.
                            let compact = try XCTUnwrap(mpsTexture.makeTextureView(pixelFormat: mpsTexture.pixelFormat,
                                textureType: .type2D, levels: 1..<mpsTexture.mipmapLevelCount, slices: 0..<1))
                            encoder.setFragmentTexture(compact, index: 1)
                        }
                        if lane == "legacy" {
                            var legacy: [Float] = [0.8, 0.8, 1, 1, 2]
                            legacy.withUnsafeMutableBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                        } else {
                            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 0)
                        }
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                        encoder.endEncoding()
                    } else {
                        try productionRenderer.encode(command: command, pass: pass, source: input, uniforms: uniforms,
                            refreshPyramid: lane == "gaussian-fresh" || iteration == 0)
                    }
                    command.commit()
                    command.waitUntilCompleted()
                    XCTAssertNil(command.error)
                    XCTAssertEqual(command.status, .completed)
                    if iteration >= 20 {
                        laneSamples[lane, default: []].append((command.gpuEndTime - command.gpuStartTime) * 1_000)
                    }
                }
            }
            for lane in lanes {
                let samples = laneSamples[lane]!.sorted()
                XCTAssertGreaterThan(samples[0], 0)
                print(String(format: "GPU_BENCH %@ %dx%d median=%.3f p95=%.3f", lane, width, height, samples[30], samples[56]))
                if lane.hasPrefix("gaussian") {
                    XCTAssertLessThan(samples[56], 8.333, "The production GPU path must fit the 120 Hz frame period")
                }
            }
            if width == 3024 {
                var samples: [Double] = []
                let progress = Float(EffectSettings.progress(angle: 99.4, clearAngle: 100))
                let tilt = Float(EffectSettings.tiltRadians(angle: 99.4, clearAngle: 100))
                let uniforms = BendUniforms(progress: progress, blur: 0.5, shadow: 0.3,
                                            pixelScale: 2, tiltRadians: tilt)
                for iteration in 0..<80 {
                    let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                    try renderer.encode(command: command, pass: pass, source: input,
                                        uniforms: uniforms, refreshPyramid: true)
                    command.commit()
                    command.waitUntilCompleted()
                    XCTAssertEqual(command.status, .completed)
                    if iteration >= 20 { samples.append((command.gpuEndTime - command.gpuStartTime) * 1_000) }
                }
                samples.sort()
                print(String(format: "GPU_BENCH gaussian-slight-fresh %dx%d median=%.3f p95=%.3f",
                             width, height, samples[30], samples[56]))
                XCTAssertLessThan(samples[56], 8.333)
            }
        }
    }
}
