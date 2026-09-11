// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

/// Image-space checks of a fixed desktop viewed through a moving glass plane.
/// The oracle projects desktop landmarks onto the pane in the forward direction.
/// It does not repeat the fragment shader's pane-to-desktop sampling equation.
final class FixedPlaneTests: XCTestCase {
    private let size = 512

    private struct Point {
        var x: Double
        var y: Double
    }

    private func onPane(_ desktop: Point, degrees: Double) -> Point {
        let theta = degrees * .pi / 180
        let eyeHeight = 0.7, eyeDistance = 2.0
        // Intersect E + lambda * (Q - E) with the rotated pane. Its normal is
        // (0, -sin(theta), cos(theta)) and its origin is the bottom hinge.
        let worldHeight = 1 - desktop.y
        let eyeDotNormal = eyeDistance * cos(theta) - eyeHeight * sin(theta)
        let rayDotNormal = -(worldHeight - eyeHeight) * sin(theta) - eyeDistance * cos(theta)
        let lambda = -eyeDotNormal / rayDotNormal
        let pointHeight = eyeHeight + lambda * (worldHeight - eyeHeight)
        let pointDepth = eyeDistance * (1 - lambda)
        let alongPane = pointHeight * cos(theta) + pointDepth * sin(theta)
        return Point(x: 0.5 + lambda * (desktop.x - 0.5), y: 1 - alongPane)
    }

    private func source(_ paint: (Double, Double) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let (red, green, blue) = paint((Double(x) + 0.5) / Double(size),
                                               (Double(y) + 0.5) / Double(size))
                let offset = (y * size + x) * 4
                pixels[offset] = blue
                pixels[offset + 1] = green
                pixels[offset + 2] = red
                pixels[offset + 3] = 255
            }
        }
        return pixels
    }

    private func render(_ pixels: [UInt8], degrees: Double) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Fixed-plane checks require host Metal access")
        let renderer = try BendRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: size, height: size, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        pixels.withUnsafeBytes {
            input.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: size * 4)
        }
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        let uniforms = BendUniforms(progress: Float(degrees / 90), blur: 0, shadow: 0,
                                    tiltRadians: Float(degrees * .pi / 180))
        try renderer.encode(command: command, pass: pass, source: input, uniforms: uniforms)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        var result = [UInt8](repeating: 0, count: pixels.count)
        result.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                            from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
        }
        return result
    }

    func testForwardProjectedLandmarksStayOnTheFixedDesktopPlane() throws {
        var checked = 0
        for degrees in [12.0, 28, 45, 60] {
            for landmark in [Point(x: 0.25, y: 0.35), Point(x: 0.5, y: 0.55),
                             Point(x: 0.75, y: 0.75), Point(x: 0.3, y: 0.9)] {
                let expected = onPane(landmark, degrees: degrees)
                guard expected.x > 0.04, expected.x < 0.96,
                      expected.y > 0.04, expected.y < 0.96 else { continue }
                let pixels = source { x, y in
                    hypot(x - landmark.x, y - landmark.y) < 0.009 ? (255, 0, 0) : (0, 0, 0)
                }
                let output = try render(pixels, degrees: degrees)
                var weight = 0.0, sumX = 0.0, sumY = 0.0
                for y in 0..<size {
                    for x in 0..<size {
                        let value = Double(output[(y * size + x) * 4 + 2])
                        guard value > 20 else { continue }
                        weight += value
                        sumX += (Double(x) + 0.5) * value
                        sumY += (Double(y) + 0.5) * value
                    }
                }
                XCTAssertGreaterThan(weight, 255, "Landmark disappeared at \(degrees) degrees")
                guard weight > 0 else { continue }
                XCTAssertEqual(sumX / weight, expected.x * Double(size), accuracy: 1.5)
                XCTAssertEqual(sumY / weight, expected.y * Double(size), accuracy: 1.5)
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 12)
    }

    func testStraightDesktopLineRemainsStraightThroughTheGlass() throws {
        let lineX = 0.3
        let pixels = source { x, _ in abs(x - lineX) < 0.004 ? (255, 0, 0) : (0, 0, 0) }
        for degrees in [15.0, 35, 55] {
            let output = try render(pixels, degrees: degrees)
            var checked = 0
            for desktopY in stride(from: 0.1, through: 0.9, by: 0.1) {
                let expected = onPane(Point(x: lineX, y: desktopY), degrees: degrees)
                guard expected.y > 0.03, expected.y < 0.97 else { continue }
                let row = Int(expected.y * Double(size))
                var weight = 0.0, sumX = 0.0
                for x in 0..<size {
                    let value = Double(output[(row * size + x) * 4 + 2])
                    if value > 20 { weight += value; sumX += (Double(x) + 0.5) * value }
                }
                XCTAssertGreaterThan(weight, 100)
                guard weight > 0 else { continue }
                XCTAssertEqual(sumX / weight, expected.x * Double(size), accuracy: 1.5,
                               "A plane must not bow a straight desktop line")
                checked += 1
            }
            XCTAssertGreaterThanOrEqual(checked, 4)
        }
    }

    func testClosingGlassCropsUpperContentInsteadOfFittingTheDesktop() throws {
        let pixels = source { _, y in
            if y < 0.25 { return (255, 0, 0) }
            if y > 0.75 { return (0, 255, 0) }
            return (0, 0, 0)
        }
        let output = try render(pixels, degrees: 60)
        XCTAssertLessThan(onPane(Point(x: 0.5, y: 0.125), degrees: 60).y, 0,
                          "The upper landmark must lie beyond the physical glass")
        XCTAssertLessThan(output.enumerated().filter { $0.offset % 4 == 2 }.map(\.element).max() ?? 255, 8,
                          "The upper desktop must disappear instead of scaling to fit")
        let greenPixels = stride(from: 1, to: output.count, by: 4).filter { output[$0] > 200 }.count
        XCTAssertGreaterThan(greenPixels, size * size / 5, "The visible lower desktop must remain present")
    }

    func testBottomHingeKeepsItsSourceDetailAcrossAngles() throws {
        let pixels = source { x, _ in Int(x * 8) % 2 == 0 ? (210, 85, 40) : (35, 160, 220) }
        for degrees in [0.0, 15, 35, 55, 65] {
            let output = try render(pixels, degrees: degrees)
            for stripe in 1..<7 {
                let x = Int((Double(stripe) + 0.5) * Double(size) / 8)
                let offset = ((size - 1) * size + x) * 4
                for channel in 0..<3 {
                    XCTAssertEqual(Int(output[offset + channel]), Int(pixels[offset + channel]), accuracy: 1,
                                   "The physical hinge must stay attached at \(degrees) degrees")
                }
            }
        }
    }

    func testOpenGlassIsPixelIdenticalToTheDesktop() throws {
        let pixels = source { x, y in
            (UInt8(Int(x * 255)), UInt8(Int(y * 255)), UInt8((Int(x * 31) + Int(y * 47)) % 2 * 255))
        }
        let output = try render(pixels, degrees: 0)
        XCTAssertTrue(zip(output, pixels).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    func testGrazingAnglesStopBeforeProjectionCanInvert() throws {
        let pixels = source { _, y in (UInt8(Int(y * 255)), 0, 0) }
        let safeFrame = try render(pixels, degrees: 68)
        for degrees in [70.71, 85, 120] {
            let output = try render(pixels, degrees: degrees)
            let maximumDifference = zip(output, safeFrame).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThanOrEqual(maximumDifference, 1,
                "The safe projection must hold within one quantization level at its antialiased boundary")
        }
        let top = ((size / 4) * size + size / 2) * 4 + 2
        let bottom = ((size * 3 / 4) * size + size / 2) * 4 + 2
        XCTAssertGreaterThan(safeFrame[bottom], safeFrame[top], "Desktop vertical orientation must remain positive")
    }
}
