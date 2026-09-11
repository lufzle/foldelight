// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

final class MetalTests: XCTestCase {
    func testNativePreviewTextureCanLoad() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        try renderer.loadPreview()
        XCTAssertEqual(renderer.sourcePixelWidth, 1586)
        let cachedRenderer = try BendRenderer(device: device)
        try cachedRenderer.loadPreview()
        XCTAssertEqual(cachedRenderer.sourcePixelWidth, 1586)
    }
    func testActualShaderNeutralAndFold() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Run GPU checks outside the command sandbox.")
        let renderer = try BendRenderer(device: device)
        let size = 64
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
        inputDescriptor.storageMode = .shared
        inputDescriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: inputDescriptor))
        let pixels = (0..<size * size).flatMap { index -> [UInt8] in
            ((index % size) / 4 + (index / size) / 4) % 2 == 0 ? [60, 120, 220, 255] : [180, 80, 30, 255]
        }
        pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * 4) }
        func render(progress: Float, blur: Float = 0.55) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget, .shaderRead]
            let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            var uniforms = BendUniforms(progress: progress, blur: blur, shadow: 0.45)
            encoder.setRenderPipelineState(renderer.pipeline)
            encoder.setFragmentTexture(input, index: 0)
            encoder.setFragmentTexture(input, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            XCTAssertNil(command.error)
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: size * 4, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
            return bytes
        }
        let neutral = try render(progress: 0)
        XCTAssertTrue(zip(neutral, pixels).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "Open lid must reproduce the source without distortion.")
        let folded = try render(progress: 0.7, blur: 0)
        XCTAssertNotEqual(folded, neutral)
        XCTAssertLessThan(folded[(size / 2 * size) * 4 + 2], 10, "Without diffusion, rays beyond the fixed desktop expose its dark surround.")
        XCTAssertTrue(stride(from: 3, to: folded.count, by: 4).allSatisfy { folded[$0] == 255 })
    }
}
