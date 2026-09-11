// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit

/// Compare production Metal reconstruction with a direct 16-texel CPU convolution.
/// The oracle uses the piecewise cubic kernel, not the shader's bilinear grouping.
final class CubicReconstructionTests: XCTestCase {
    private struct Level {
        let width: Int
        let height: Int
        let pixels: [UInt8]
    }

    private func kernel(_ distance: Double) -> Double {
        let x = abs(distance)
        if x < 1 { return (4 - 6 * x * x + 3 * x * x * x) / 6 }
        if x < 2 { return pow(2 - x, 3) / 6 }
        return 0
    }

    private func reference(_ level: Level, u: Float, v: Float) -> SIMD3<Double> {
        let px = Double(u) * Double(level.width) - 0.5
        let py = Double(v) * Double(level.height) - 0.5
        let baseX = Int(floor(px)), baseY = Int(floor(py))
        var result = SIMD3<Double>(repeating: 0)
        for y in (baseY - 1)...(baseY + 2) {
            for x in (baseX - 1)...(baseX + 2) {
                let weight = kernel(px - Double(x)) * kernel(py - Double(y))
                let clampedX = min(level.width - 1, max(0, x))
                let clampedY = min(level.height - 1, max(0, y))
                let offset = (clampedY * level.width + clampedX) * 4
                for channel in 0..<3 { result[channel] += Double(level.pixels[offset + channel]) / 255 * weight }
            }
        }
        return result
    }

    private func makeLevels(width: Int, height: Int, constants: [SIMD3<UInt8>]? = nil) -> [Level] {
        var levels: [Level] = []
        var w = width, h = height
        repeat {
            let mip = levels.count
            var pixels = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let color = constants?[mip] ?? SIMD3<UInt8>(
                        UInt8((x * 79 + y * 37 + mip * 53) % 256),
                        UInt8((x * 13 + y * 103 + mip * 29) % 256),
                        UInt8((x * 149 + y * 17 + mip * 67) % 256))
                    for channel in 0..<3 { pixels[(y * w + x) * 4 + channel] = color[channel] }
                }
            }
            levels.append(Level(width: w, height: h, pixels: pixels))
            if w == 1 && h == 1 { break }
            w = max(1, w / 2)
            h = max(1, h / 2)
        } while true
        return levels
    }

    private func evaluate(_ levels: [Level], samples: [SIMD4<Float>]) throws -> [SIMD4<Float>] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Cubic reconstruction checks require host Metal access")
        let shaderURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/foldelight/Resources/Bend.metal")
        let shader = try String(contentsOf: shaderURL, encoding: .utf8) + """

        kernel void verifyGlassCubic(texture2d<half> tex [[texture(0)]],
                                     device const float4 *samples [[buffer(0)]],
                                     device float4 *result [[buffer(1)]],
                                     uint index [[thread_position_in_grid]]) {
            float4 input = samples[index];
            half3 color = input.w > .5 ? glassDiffusion(tex, input.xy, input.z)
                                        : glassCubicLevel(tex, input.xy, uint(input.z));
            result[index] = float4(float3(color), 1);
        }
        """
        let library = try device.makeLibrary(source: shader, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "verifyGlassCubic"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: levels[0].width, height: levels[0].height, mipmapped: levels.count > 1)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        XCTAssertEqual(texture.mipmapLevelCount, levels.count)
        for (mip, level) in levels.enumerated() {
            level.pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, level.width, level.height),
                    mipmapLevel: mip, withBytes: $0.baseAddress!, bytesPerRow: level.width * 4)
            }
        }
        let byteCount = samples.count * MemoryLayout<SIMD4<Float>>.stride
        let input = try samples.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(bytes: bytes.baseAddress!, length: byteCount, options: .storageModeShared))
        }
        let output = try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: samples.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(64, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self),
                                         count: samples.count))
    }

    func testOddMipDimensionsAndFractionalCoordinatesMatchSixteenTapOracle() throws {
        let levels = makeLevels(width: 27, height: 19)
        let coordinates: [Float] = [0.013, 0.093, 0.247, 0.381, 0.509, 0.733, 0.897, 0.991]
        var samples: [SIMD4<Float>] = []
        for mip in levels.indices {
            for u in coordinates {
                for v in coordinates { samples.append(SIMD4(u, v, Float(mip), 0)) }
            }
        }
        let actual = try evaluate(levels, samples: samples)
        for (index, sample) in samples.enumerated() {
            let expected = reference(levels[Int(sample.z)], u: sample.x, v: sample.y)
            for channel in 0..<3 {
                XCTAssertEqual(Double(actual[index][channel]), expected[channel], accuracy: 0.003,
                               "Cubic sample \(sample), channel \(channel)")
            }
        }
    }

    func testClampToEdgeMatchesIndependentKernelOutsideTheImage() throws {
        let levels = makeLevels(width: 13, height: 9)
        let coordinates: [Float] = [-0.4, -0.021, 0, 0.001, 0.5, 0.999, 1, 1.017, 1.4]
        var samples: [SIMD4<Float>] = []
        for mip in levels.indices {
            for u in coordinates {
                for v in coordinates { samples.append(SIMD4(u, v, Float(mip), 0)) }
            }
        }
        let actual = try evaluate(levels, samples: samples)
        for (index, sample) in samples.enumerated() {
            let expected = reference(levels[Int(sample.z)], u: sample.x, v: sample.y)
            for channel in 0..<3 {
                XCTAssertEqual(Double(actual[index][channel]), expected[channel], accuracy: 0.003,
                               "Edge sample \(sample), channel \(channel)")
            }
        }
    }

    func testDiffusionMapsSourceLODOneToCompactPyramidLevelZero() throws {
        let colors: [SIMD3<UInt8>] = [SIMD3(255, 0, 255), SIMD3(20, 80, 140), SIMD3(80, 180, 20),
                                     SIMD3(180, 30, 90), SIMD3(40, 160, 220)]
        let levels = makeLevels(width: 27, height: 19, constants: colors)
        let lods: [Float] = [-10, 0, 0.3, 0.999, 1, 1.01, 1.37, 1.99, 2, 2.65, 3.01, 3.9, 4, 8]
        let samples = lods.map { SIMD4<Float>(0.371, 0.619, $0, 1) }
        let actual = try evaluate(levels, samples: samples)
        for (index, lod) in lods.enumerated() {
            let bounded = max(0, min(Double(levels.count - 1), Double(lod) - 1))
            let lower = Int(floor(bounded)), upper = min(lower + 1, levels.count - 1)
            let fraction = bounded - Double(lower)
            for channel in 0..<3 {
                let expected = (Double(colors[lower][channel]) * (1 - fraction)
                                + Double(colors[upper][channel]) * fraction) / 255
                XCTAssertEqual(Double(actual[index][channel]), expected, accuracy: 0.003,
                               "Explicit mip blend at LOD \(lod), channel \(channel)")
            }
        }
    }

    func testSingleLevelTextureFallsBackToItsOnlyLevel() throws {
        var pixels: [UInt8] = []
        for i in 0..<35 {
            pixels.append(UInt8(i * 7))
            pixels.append(UInt8(255 - i * 7))
            pixels.append(61)
            pixels.append(255)
        }
        let level = Level(width: 7, height: 5, pixels: pixels)
        let samples: [SIMD4<Float>] = [-2, 0, 0.5, 3, 20].map { SIMD4(0.319, 0.713, $0, 1) }
        let actual = try evaluate([level], samples: samples)
        let expected = reference(level, u: samples[0].x, v: samples[0].y)
        for output in actual {
            for channel in 0..<3 { XCTAssertEqual(Double(output[channel]), expected[channel], accuracy: 0.003) }
        }
    }
}
