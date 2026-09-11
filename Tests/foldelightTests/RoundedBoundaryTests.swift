// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

/// Visible-output requirements for the projected desktop's rounded, diffused boundary.
final class RoundedBoundaryTests: XCTestCase {
    private func render(width: Int, height: Int, progress: Float = 0.5, blur: Float = 0,
                        degrees: Float = 0, scale: Float = 1,
                        paint: (Int, Int) -> UInt8 = { _, _ in 220 }) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = paint(x, y)
                for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
            }
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Rounded boundary tests require host GPU access")
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
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        try renderer.encode(command: command, pass: pass, source: source,
            uniforms: BendUniforms(progress: progress, blur: blur, shadow: 0,
                                   pixelScale: scale, tiltRadians: degrees * .pi / 180))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        var result = [UInt8](repeating: 0, count: pixels.count)
        result.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return result
    }

    func testAllFourProjectedCornersRoundWhileStraightEdgesRemain() throws {
        let width = 360, height = 240
        let pixels = try render(width: width, height: height)
        func value(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * width + x) * 4] }
        for x in [1, width - 2] {
            for y in [1, height - 2] {
                XCTAssertLessThan(value(x, y), 10, "Every corner must expose the dark surround")
            }
        }
        for x in [18, width - 19] {
            for y in [18, height - 19] {
                XCTAssertGreaterThan(value(x, y), 210, "The corner must form an arc rather than a large square cutout")
            }
        }
        for point in [(width / 2, 2), (width / 2, height - 3), (2, height / 2), (width - 3, height / 2)] {
            XCTAssertGreaterThan(value(point.0, point.1), 210, "Rounded corners must preserve straight edge interiors")
        }
        XCTAssertEqual(value(width / 2, height / 2), 220)
    }

    func testFullyOpenDesktopHasNoCornerMaskOrAddedBlur() throws {
        let width = 180, height = 120
        let pixels = try render(width: width, height: height, progress: 0, blur: 1, degrees: 40) { x, y in
            UInt8((x * 17 + y * 31) % 256)
        }
        for y in 0..<height {
            for x in 0..<width {
                let expected = (x * 17 + y * 31) % 256
                for channel in 0..<3 {
                    XCTAssertEqual(Int(pixels[(y * width + x) * 4 + channel]), expected, accuracy: 1)
                }
            }
        }
    }

    func testSlightFoldAlreadyHasRoundedCorners() throws {
        let width = 360, height = 240
        // Use the real activation curve: these angles produce very small progress,
        // including the first visible frames just above the capture threshold.
        for angle in [99.4, 99.0, 98.0] {
            let progress = Float(EffectSettings.progress(angle: angle, clearAngle: 100))
            XCTAssertGreaterThan(progress, 0.0001)
            let pixels = try render(width: width, height: height, progress: progress,
                                    blur: 0.5, degrees: Float(100 - angle))
            for x in [5, width - 6] {
                for y in [5, height - 6] {
                    XCTAssertLessThan(pixels[(y * width + x) * 4], 20,
                                      "Corners must already be round at lid angle \(angle)")
                }
            }
            for x in [22, width - 23] {
                for y in [22, height - 23] {
                    XCTAssertGreaterThan(pixels[(y * width + x) * 4], 210,
                                         "The curved corner must retain its interior")
                }
            }
        }
    }

    func testBlurBroadensTheProjectedSideBoundary() throws {
        let width = 720, height = 480
        let sharp = try render(width: width, height: height, degrees: 35)
        let soft = try render(width: width, height: height, blur: 1, degrees: 35)
        let row = height / 2
        func transitionPixels(_ pixels: [UInt8]) -> Int {
            (0..<width / 3).filter {
                let value = pixels[(row * width + $0) * 4]
                return value > 20 && value < 200
            }.count
        }
        XCTAssertLessThanOrEqual(transitionPixels(sharp), 3, "Zero blur must keep a clean antialiased boundary")
        XCTAssertGreaterThan(transitionPixels(soft), transitionPixels(sharp) + 8,
                             "The perimeter must visibly soften when Blur increases")
        let center = (row * width + width / 2) * 4
        XCTAssertEqual(soft[center], sharp[center], "Edge softness must not darken the central flat color")
    }

    func testPerimeterDiffusionIsStrongerThanBodyDiffusionAtTheSameHeight() throws {
        let width = 960, height = 640
        let paint: (Int, Int) -> UInt8 = { x, _ in
            UInt8((127 + 100 * sin(Double(x) * 2 * .pi / 24)).rounded())
        }
        let sharp = try render(width: width, height: height, degrees: 35, paint: paint)
        let soft = try render(width: width, height: height, blur: 1, degrees: 35, paint: paint)
        let row = height * 7 / 10
        func contrast(_ pixels: [UInt8], columns: Range<Int>) -> Double {
            let values = columns.map { Double(pixels[(row * width + $0) * 4]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count))
        }
        // Both strips share the same hinge distance, so their base focus is equal.
        // The edge strip starts inside the projected image, away from its dark exterior.
        let edge = 55..<85, body = 420..<540
        let edgeRatio = contrast(soft, columns: edge) / max(1, contrast(sharp, columns: edge))
        let bodyRatio = contrast(soft, columns: body) / max(1, contrast(sharp, columns: body))
        XCTAssertGreaterThan(bodyRatio, 0.4, "The body must retain visible stripe detail")
        XCTAssertLessThan(edgeRatio, bodyRatio * 0.85,
                          "Additional diffusion must concentrate around the perimeter")
    }

    func testCornerRadiusUsesTheSameLogicalSizeAcrossBackingScales() throws {
        let logicalWidth = 360, logicalHeight = 240
        var logicalCutoffs: [Double] = []
        for scale in [1, 2, 3] {
            let width = logicalWidth * scale, height = logicalHeight * scale
            let pixels = try render(width: width, height: height, scale: Float(scale))
            let row = 2 * scale
            let cutoff = try XCTUnwrap((0..<60 * scale).first { pixels[(row * width + $0) * 4] > 110 })
            logicalCutoffs.append(Double(cutoff) / Double(scale))
        }
        XCTAssertGreaterThan(logicalCutoffs[0], 10, "The reference corner must have a visible radius")
        for cutoff in logicalCutoffs.dropFirst() {
            XCTAssertEqual(cutoff, logicalCutoffs[0], accuracy: 1.5,
                           "Retina scaling must preserve the apparent corner radius")
        }
    }
}
