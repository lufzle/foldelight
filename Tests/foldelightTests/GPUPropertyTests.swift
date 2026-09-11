// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

/// Seeded, reproducible image properties exercised through the production Metal pipeline.
/// BGRA readback tests visible output, not floating-point shader intermediates.
final class GPUPropertyTests: XCTestCase {
    private struct Generator {
        var state: UInt64 = 0xF01DE119
        mutating func next(_ upper: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 32) % UInt64(upper))
        }
        mutating func fraction() -> Float { Float(next(10_001)) / 10_000 }
    }

    private func render(_ pixels: [UInt8], width: Int, height: Int,
                        uniforms: BendUniforms) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "GPU properties require host Metal access")
        let renderer = try BendRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: width * 4)
        }
        descriptor.usage = [.renderTarget, .shaderRead]
        let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 0)
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        try renderer.encode(command: command, pass: pass, source: source, uniforms: uniforms)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        var result = [UInt8](repeating: 0, count: pixels.count)
        result.withUnsafeMutableBytes {
            destination.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        XCTAssertTrue(stride(from: 3, to: result.count, by: 4).allSatisfy { result[$0] == 255 },
                      "Every target pixel must receive opaque output")
        return result
    }

    private func pattern(width: Int, height: Int) -> [UInt8] {
        var result = [UInt8]()
        for i in 0..<(width * height) {
            result.append(UInt8((i * 17) % 256))
            result.append(UInt8((i * 31 + 13) % 256))
            result.append(UInt8((i * 7 + 97) % 256))
            result.append(255)
        }
        return result
    }

    func testRandomNeutralFramesPreserveSourceRegardlessOfControls() throws {
        var random = Generator()
        for sample in 0..<12 {
            let width = 33 + random.next(200), height = 31 + random.next(150)
            let source = pattern(width: width, height: height)
            let result = try render(source, width: width, height: height,
                uniforms: BendUniforms(progress: 0, blur: random.fraction(), shadow: random.fraction(),
                                       pixelScale: 1 + random.fraction() * 2))
            XCTAssertTrue(zip(result, source).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                          "Neutral identity failed for seeded sample \(sample), \(width)x\(height)")
        }
    }

    func testRandomBentFramesBlurTopRowsWithoutProtectedMenuBand() throws {
        var random = Generator()
        for sample in 0..<10 {
            let width = 65 + random.next(140), height = 80 + random.next(100)
            let source = pattern(width: width, height: height)
            let progress = 0.3 + random.fraction() * 0.7
            let result = try render(source, width: width, height: height,
                uniforms: BendUniforms(progress: progress,
                    blur: 0.5 + random.fraction() * 0.5, shadow: random.fraction(),
                    pixelScale: 1 + random.fraction()))
            for row in 0..<max(1, height / 20) {
                let differences = (width / 3..<width * 2 / 3).map { x -> Double in
                    let index = (row * width + x) * 4
                    return abs(Double(result[index]) - Double(source[index]))
                }
                XCTAssertGreaterThan(differences.reduce(0, +) / Double(differences.count), 20,
                    "Upper center must receive the effect, sample \(sample), row \(row)")
            }
        }
    }

    func testRandomVignetteIsMonotonicSymmetricAndLeavesHingeCenterUnchanged() throws {
        var random = Generator()
        for sample in 0..<8 {
            let width = 120 + random.next(100), height = 90 + random.next(70)
            let source = Array(repeating: [UInt8](arrayLiteral: 170, 190, 210, 255), count: width * height).flatMap { $0 }
            let progress = 0.1 + random.fraction() * 0.9
            let blur = random.fraction()
            var frames = [[UInt8]]()
            for shadow: Float in [0, 0.5, 1] {
                frames.append(try render(source, width: width, height: height,
                    uniforms: BendUniforms(progress: progress, blur: blur, shadow: shadow)))
            }
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4, mirror = (y * width + width - 1 - x) * 4
                    for c in 0..<3 {
                        XCTAssertLessThanOrEqual(frames[1][i + c], frames[0][i + c], "Sample \(sample)")
                        XCTAssertLessThanOrEqual(frames[2][i + c], frames[1][i + c], "Sample \(sample)")
                        XCTAssertEqual(Int(frames[2][i + c]), Int(frames[2][mirror + c]), accuracy: 1)
                    }
                }
                let center = (y * width + width / 2) * 4
                if y >= height / 2 {
                    XCTAssertEqual(Array(frames[0][center..<center + 3]), Array(frames[2][center..<center + 3]))
                }
            }
            let side = ((height - 4) * width + width / 8) * 4
            XCTAssertGreaterThan(Int(frames[0][side]) - Int(frames[2][side]), 8,
                                 "Vignette must have a visible lateral effect, sample \(sample)")
        }
    }

    func testZeroBlurIgnoresPixelScaleAndPreservesHingeDetail() throws {
        var random = Generator()
        for _ in 0..<8 {
            let width = 128 + random.next(64), height = 96 + random.next(64)
            let source = pattern(width: width, height: height)
            let progress = random.fraction()
            let first = try render(source, width: width, height: height,
                uniforms: BendUniforms(progress: progress, blur: 0, shadow: 0, pixelScale: 1))
            let second = try render(source, width: width, height: height,
                uniforms: BendUniforms(progress: progress, blur: 0, shadow: 0, pixelScale: 3))
            XCTAssertEqual(first, second, "A zero blur radius must be independent of display scale")
            let center = ((height - 1) * width + width / 2) * 4
            for channel in 0..<3 {
                XCTAssertEqual(Int(first[center + channel]), Int(source[center + channel]), accuracy: 3,
                               "The fully open hinge must retain its source detail")
            }
        }
    }
}
