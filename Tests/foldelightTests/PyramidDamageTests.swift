// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

/// Full-frame recomputation is the independent reference for damage propagation.
final class PyramidDamageTests: XCTestCase {
    func testEveryCachedMipMatchesFullRebuildForSeededDamage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var state: UInt64 = 0x47c9_31d8
        func random(_ upper: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Int((state >> 32) % UInt64(upper))
        }
        for (width, height) in [(1, 17), (33, 25), (132, 98), (513, 335)] {
            let fixture = try DamageFixture(device: device, width: width, height: height)
            let partial = try BendRenderer(device: device), full = try BendRenderer(device: device)
            let uniforms = BendUniforms(progress: 0.8, blur: 1, shadow: 0, pixelScale: 2)
            _ = try fixture.render(partial, uniforms: uniforms)
            for frame in 1...36 {
                let changed = (0..<(1 + random(3))).map { _ -> CGRect in
                    let x = random(width), y = random(height)
                    return CGRect(x: x, y: y, width: 1 + random(min(19, width - x)),
                                  height: 1 + random(min(13, height - y)))
                }
                fixture.change(changed, frame: frame)
                _ = try fixture.render(partial, uniforms: uniforms, damage: changed)
                _ = try fixture.render(full, uniforms: uniforms)
                XCTAssertEqual(try readValidMips(partial), try readValidMips(full),
                    "A cached texel differs at \(width)x\(height), frame \(frame)")
            }
        }
    }

    private func readValidMips(_ renderer: BendRenderer) throws -> [[UInt8]] {
        let texture = try XCTUnwrap(renderer.pyramidTextureForTesting)
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        var copies: [MTLTexture] = []
        for level in 0..<renderer.pyramidValidLevelCountForTesting {
            let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .shared
            let copy = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: width, height: height, depth: 1), to: copy,
                destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
            copies.append(copy)
        }
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed); XCTAssertNil(command.error)
        return copies.map { copy in
            var bytes = [UInt8](repeating: 0, count: copy.width * copy.height * 4)
            bytes.withUnsafeMutableBytes {
                copy.getBytes($0.baseAddress!, bytesPerRow: copy.width * 4,
                    from: MTLRegionMake2D(0, 0, copy.width, copy.height), mipmapLevel: 0)
            }
            return bytes
        }
    }

    func testFullAndPartialOutputMatchPreserved52bf1efRenderer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for (width, height, scale) in [(131, 97, Float(1)), (511, 333, 3), (3024, 1964, 2)] {
            let fixture = try DamageFixture(device: device, width: width, height: height)
            let baseline = try Baseline52BendRenderer(device: device)
            let current = try BendRenderer(device: device)
            var pending: [CGRect] = []
            for (frame, angle) in [105.0, 99.4, 75, 35, 98, 42].enumerated() {
                let rect = CGRect(x: (frame * 17) % (width - 9), y: (frame * 13) % (height - 11), width: 9, height: 11)
                fixture.change([rect], frame: frame + 1)
                pending.append(rect)
                let progress = Float(EffectSettings.progress(angle: angle, clearAngle: 100))
                let tilt = Float(EffectSettings.tiltRadians(angle: angle, clearAngle: 100))
                let command = try XCTUnwrap(baseline.queue.makeCommandBuffer())
                try baseline.encode(command: command, pass: fixture.pass, source: fixture.source,
                    uniforms: Baseline52BendUniforms(progress: progress, blur: 1, shadow: 0.3,
                        pixelScale: scale, tiltRadians: tilt))
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed); XCTAssertNil(command.error)
                let expected = fixture.readOutput()
                let actual = try fixture.render(current,
                    uniforms: BendUniforms(progress: progress, blur: 1, shadow: 0.3, pixelScale: scale, tiltRadians: tilt),
                    damage: pending)
                XCTAssertEqual(actual, expected, "Changed pixels at \(width)x\(height), angle \(angle)")
                if progress > 0 { pending.removeAll(keepingCapacity: true) }
            }
        }
    }

    func testPartialUpdatesMatchFullRebuildAcrossHalosOddSizesAndBackingScales() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for (width, height, scale) in [(131, 97, Float(1)), (131, 97, 2),
                                       (511, 333, 0.75), (511, 333, 2),
                                       (768, 512, 1), (768, 512, 3)] {
            let fixture = try DamageFixture(device: device, width: width, height: height)
            let partial = try BendRenderer(device: device), full = try BendRenderer(device: device)
            let deep = BendUniforms(progress: 0.8, blur: 1, shadow: 0.3, pixelScale: scale)
            XCTAssertEqual(try fixture.render(partial, uniforms: deep), try fixture.render(full, uniforms: deep))
            let rectangles = [CGRect(x: 0, y: 0, width: 1, height: 1),
                CGRect(x: width - 1, y: height - 1, width: 1, height: 1),
                CGRect(x: width / 2, y: 0, width: 1, height: 7),
                CGRect(x: 0, y: height / 2, width: 5, height: 1),
                CGRect(x: width / 3, y: height / 3, width: 9, height: 11),
                CGRect(x: width - 11, y: 3, width: 11, height: 13)]
            for step in 0..<12 {
                let changed = step % 3 == 0 ? [rectangles[step % rectangles.count], rectangles[(step + 3) % rectangles.count]]
                    : [rectangles[step % rectangles.count]]
                fixture.change(changed, frame: step + 1)
                // Lower blur after a source change, then grow it on the same source:
                // cached upper levels must never retain pixels from the old image.
                let angle = step % 3 == 0 ? 99.4 : (step % 3 == 1 ? 75.0 : 35.0)
                let uniforms = BendUniforms(progress: Float(EffectSettings.progress(angle: angle, clearAngle: 100)),
                    blur: 1, shadow: 0.3, pixelScale: scale,
                    tiltRadians: Float(EffectSettings.tiltRadians(angle: angle, clearAngle: 100)))
                let updated = try fixture.render(partial, uniforms: uniforms, damage: changed)
                XCTAssertEqual(updated, try fixture.render(full, uniforms: uniforms),
                    "Partial update differs at \(width)x\(height), scale \(scale), step \(step)")
                XCTAssertEqual(try fixture.render(partial, uniforms: deep, refresh: false),
                               try fixture.render(full, uniforms: deep),
                    "Growing the cached pyramid must use the latest source")
            }
        }
    }

    func testEmptyDamagePreservesPixelsAndInvalidDamageFallsBackToFull() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try DamageFixture(device: device, width: 127, height: 99)
        let partial = try BendRenderer(device: device), full = try BendRenderer(device: device)
        let uniforms = BendUniforms(progress: 0.7, blur: 1, shadow: 0, pixelScale: 2)
        let original = try fixture.render(partial, uniforms: uniforms)
        XCTAssertEqual(original, try fixture.render(partial, uniforms: uniforms, damage: []))
        fixture.change([CGRect(x: 0, y: 0, width: 127, height: 99)], frame: 29)
        let invalid = [CGRect(x: Double.nan, y: 0, width: 8, height: 8)]
        XCTAssertEqual(try fixture.render(partial, uniforms: uniforms, damage: invalid),
                       try fixture.render(full, uniforms: uniforms))
    }

    func testSourceResizeThatKeepsTheSameHalfDimensionsForcesFullRebuild() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let partial = try BendRenderer(device: device), full = try BendRenderer(device: device)
        let uniforms = BendUniforms(progress: 0.6, blur: 0.8, shadow: 0, pixelScale: 1)
        let old = try DamageFixture(device: device, width: 131, height: 99)
        _ = try old.render(partial, uniforms: uniforms)
        let resized = try DamageFixture(device: device, width: 130, height: 98)
        XCTAssertEqual(try resized.render(partial, uniforms: uniforms, damage: []),
                       try resized.render(full, uniforms: uniforms))
    }
}

/// Shared by correctness and opt-in trace benchmarks. Source bytes are always initialized.
final class DamageFixture {
    let width: Int, height: Int
    let source: MTLTexture
    let output: MTLTexture
    let pass: MTLRenderPassDescriptor
    var pixels: [UInt32]
    init(device: MTLDevice, width: Int, height: Int, readableOutput: Bool = true) throws {
        self.width = width; self.height = height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .shaderRead
        source = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        descriptor.storageMode = readableOutput ? .shared : .private
        descriptor.usage = .renderTarget
        output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pixels = [UInt32](repeating: 0xff000000, count: width * height)
        change([CGRect(x: 0, y: 0, width: width, height: height)], frame: 0)
    }
    func change(_ rectangles: [CGRect], frame: Int) {
        for rectangle in rectangles {
            let rect = rectangle.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rect.isEmpty else { continue }
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) {
                    pixels[y * width + x] = 0xff000000 | UInt32((x * 17 + y * 3 + frame * 71) & 255)
                        | UInt32((x + y * 13 + frame * 43) & 255) << 8
                        | UInt32((x * 7 + y + frame * 29) & 255) << 16
                }
            }
            pixels.withUnsafeBytes {
                source.replace(region: MTLRegionMake2D(Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)),
                    mipmapLevel: 0, withBytes: $0.baseAddress!.advanced(by: (Int(rect.minY) * width + Int(rect.minX)) * 4),
                    bytesPerRow: width * 4)
            }
        }
    }
    func render(_ renderer: BendRenderer, uniforms: BendUniforms, refresh: Bool = true,
                damage: [CGRect]? = nil) throws -> [UInt8] {
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        try renderer.encode(command: command, pass: pass, source: source, uniforms: uniforms,
                            refreshPyramid: refresh, damage: damage)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed); XCTAssertNil(command.error)
        return readOutput()
    }
    func readOutput() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }
}
