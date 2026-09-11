// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
import ImageIO
import UniformTypeIdentifiers
@testable import foldelight

final class GlassQualityTests: XCTestCase {
    func testGlassKeepsBodyDetailAndDiffusesTheLiftedEdge() throws {
        let width = 768, height = 512
        let source = (0..<width * height).flatMap { index -> [UInt8] in
            let value: UInt8 = (index % width / 24) % 2 == 0 ? 25 : 230
            return [value, value, value, 255]
        }
        let sharp = try render(source, width: width, height: height, progress: 0.7, blur: 0, shadow: 0)
        let glass = try render(source, width: width, height: height, progress: 0.7, blur: 0.5, shadow: 0)
        func contrast(_ pixels: [UInt8], row: Int) -> Double {
            let values = (width / 3..<width * 2 / 3).map { Double(pixels[(row * width + $0) * 4]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count))
        }
        let body = height * 3 / 5, edge = height / 10
        XCTAssertGreaterThan(contrast(glass, row: body), contrast(sharp, row: body) * 0.65,
            "The body must keep most of its detail instead of becoming uniformly frosted.")
        XCTAssertLessThan(contrast(glass, row: edge), contrast(sharp, row: edge) * 0.25,
            "The lifted edge must still have visible diffusion.")
    }

    func testDiffusionDoesNotAddAPaleVeil() throws {
        let width = 256, height = 192
        for pixel: [UInt8] in [[0, 0, 0, 255], [30, 80, 130, 255], [200, 200, 200, 255]] {
            let source = Array(repeating: pixel, count: width * height).flatMap { $0 }
            let output = try render(source, width: width, height: height, progress: 0.7, blur: 1, shadow: 0)
            let center = (height / 10 * width + width / 2) * 4
            for channel in 0..<3 {
                XCTAssertEqual(Int(output[center + channel]), Int(pixel[channel]), accuracy: 1,
                    "Diffusion must preserve flat colors and black levels away from the boundary.")
            }
        }
    }

    func testLiftedEdgeShadeFadesBeforeTheHinge() throws {
        let width = 512, height = 320
        let source = Array(repeating: [UInt8](arrayLiteral: 200, 200, 200, 255), count: width * height).flatMap { $0 }
        let clear = try render(source, width: width, height: height, progress: 0.7, blur: 0, shadow: 0)
        let glass = try render(source, width: width, height: height, progress: 0.7,
                               blur: 0, shadow: Float(EffectSettings.defaultVignette))
        let top = (height / 20 * width + width / 2) * 4
        let bottom = (height * 4 / 5 * width + width / 2) * 4
        XCTAssertGreaterThan(Int(clear[top]) - Int(glass[top]), 20,
            "The default vignette must give the lifted glass a visible neutral shade.")
        XCTAssertEqual(glass[bottom], clear[bottom], "The hinge-side center must retain its brightness.")
    }

    private func render(_ pixels: [UInt8], width: Int, height: Int, progress: Float,
                        blur: Float = 1,
                        shadow: Float = 0.45, tiltRadians: Float? = nil,
                        pixelScale: Float = 1) throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "GPU checks require host Metal access.")
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
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        try renderer.encode(command: command, pass: pass, source: source,
            uniforms: BendUniforms(progress: progress, blur: blur,
                                   shadow: shadow, pixelScale: pixelScale, tiltRadians: tiltRadians))
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        var result = [UInt8](repeating: 0, count: pixels.count)
        result.withUnsafeMutableBytes {
            destination.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                 from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return result
    }

    func testWholeScreenIncludingTopRowsBendsAndBlurs() throws {
        let width = 256, height = 200
        let source = (0..<width * height).flatMap { index -> [UInt8] in
            let value: UInt8 = (index % width / 4) % 2 == 0 ? 25 : 230
            return [value, value, value, 255]
        }
        let neutral = try render(source, width: width, height: height, progress: 0)
        XCTAssertEqual(neutral, source, "An open lid must preserve the entire screen.")
        let sharp = try render(source, width: width, height: height, progress: 0.7, blur: 0)
        let blurred = try render(source, width: width, height: height, progress: 0.7, blur: 1)
        func contrast(_ pixels: [UInt8], row: Int) -> Double {
            let values = (80..<176).map { Double(pixels[(row * width + $0) * 4]) }
            let mean = values.reduce(0, +) / Double(values.count)
            return sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
        }
        for row in [0, 1, 5, 9] {
            XCTAssertGreaterThan(contrast(sharp, row: row), 40)
            XCTAssertLessThan(contrast(blurred, row: row), contrast(sharp, row: row) * 0.3,
                "Blur must affect the top center, including the macOS menu bar rows.")
            let edge = row * width * 4
            XCTAssertLessThan(blurred[edge], source[edge],
                "The top side edge must bend with the desktop instead of remaining protected.")
        }
    }

    func testGlassKeepsTopCenterVisible() throws {
        let width = 256, height = 192
        let source = Array(repeating: [UInt8](arrayLiteral: 160, 190, 220, 255), count: width * height).flatMap { $0 }
        do {
            let output = try render(source, width: width, height: height, progress: 0.7)
            let index = (5 * width + width / 2) * 4
            XCTAssertGreaterThan(output[index + 2], 80, "The reference keeps desktop content at the top center.")
            XCTAssertTrue(stride(from: 3, to: output.count, by: 4).allSatisfy { output[$0] == 255 })
        }
    }

    func testBottomDetailSurvivesWhileTopDiffuses() throws {
        let width = 256, height = 192
        let source = (0..<width * height).flatMap { index -> [UInt8] in
            let value: UInt8 = (index % width / 4) % 2 == 0 ? 25 : 230
            return [value, value, value, 255]
        }
        do {
            let output = try render(source, width: width, height: height, progress: 0.7)
            func contrast(row: Int) -> Double {
                let values = (80..<176).map { Double(output[(row * width + $0) * 4]) }
                let mean = values.reduce(0, +) / Double(values.count)
                return sqrt(values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count))
            }
            let top = contrast(row: height / 5), bottom = contrast(row: height - 4)
            XCTAssertGreaterThan(bottom, 45, "The hinge and dock must retain visible fine detail.")
            XCTAssertGreaterThan(bottom, top * 2.5, "Diffusion must increase toward the top across the surface.")
        }
    }

    func testVignetteDarkensBothSidesWhilePreservingCenter() throws {
        let width = 512, height = 320
        let source = Array(repeating: [UInt8](arrayLiteral: 200, 200, 200, 255), count: width * height).flatMap { $0 }
        let clear = try render(source, width: width, height: height, progress: 0.7, blur: 0, shadow: 0)
        let shaded = try render(source, width: width, height: height, progress: 0.7, blur: 0, shadow: 1)
        for row in [height / 2, height - 16] {
            for x in [width / 8, width * 7 / 8] {
                let index = (row * width + x) * 4
                XCTAssertGreaterThan(Int(clear[index]) - Int(shaded[index]), 30,
                    "Maximum vignette must visibly darken both lateral regions, including near the hinge.")
            }
            let center = (row * width + width / 2) * 4
            XCTAssertEqual(shaded[center], clear[center], "The center must stay clear.")
        }
        let neutral = try render(source, width: width, height: height, progress: 0, blur: 0, shadow: 1)
        XCTAssertEqual(neutral, source, "Vignette must disappear when the lid is open.")
    }

    func testBlurDoesNotTranslateCenteredFeature() throws {
        for width in [256, 3024] {
            let height = 192
            let black = Array(repeating: [UInt8](arrayLiteral: 0, 0, 0, 255), count: width * height).flatMap { $0 }
            var stripe = black
            for y in 0..<height {
                for x in (width / 2 - 4)..<(width / 2 + 4) {
                    for channel in 0..<3 { stripe[(y * width + x) * 4 + channel] = 255 }
                }
            }
            let background = try render(black, width: width, height: height, progress: 0.7, shadow: 0)
            let output = try render(stripe, width: width, height: height, progress: 0.7, shadow: 0)
            for y in [height / 5, height / 2] {
                var mass = 0.0, moment = 0.0
                for x in 32..<(width - 32) {
                    let index = (y * width + x) * 4
                    let value = max(0, Double(output[index]) - Double(background[index]))
                    mass += value
                    moment += Double(x) * value
                }
                XCTAssertGreaterThan(mass, 100)
                XCTAssertEqual(moment / max(1, mass), Double(width - 1) / 2, accuracy: 1.5,
                               "Gaussian mip levels must not introduce a directional phase shift at width \(width).")
            }
        }
    }

    func testExportVisualReviewFramesWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_EXPORT_GLASS"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_EXPORT_GLASS=1 to export actual GPU renderings.")
        }
        let width = 960, height = 600
        let source = (0..<width * height).flatMap { index -> [UInt8] in
            let x = index % width, y = index / width
            if y > 548 && y < 588 && x > 280 && x < 680 {
                let icon = (x - 280) / 40
                return [UInt8(60 + icon * 17), UInt8(220 - icon * 12), UInt8(90 + icon * 15), 255]
            }
            if x > 110 && x < 850 && y > 160 && y < 440 {
                if y % 30 < 3 { return [70, 75, 90, 255] }
                if x % 90 < 3 { return [150, 150, 160, 255] }
                return [235, 230, 225, 255]
            }
            return [UInt8(90 + y / 5), UInt8(75 + y / 5), UInt8(55 + y / 6), 255]
        }
        let directory = URL(fileURLWithPath: "/tmp/foldelight-glass-review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func save(_ pixels: [UInt8], name: String) throws {
            let data = Data(pixels) as CFData
            let provider = try XCTUnwrap(CGDataProvider(data: data))
            let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little), provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent))
            let target = try XCTUnwrap(CGImageDestinationCreateWithURL(directory.appendingPathComponent(name + ".png") as CFURL,
                UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(target, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(target))
        }
        try save(source, name: "source")
        let artwork = try PreviewArtwork.image()
        let cgArtwork = try XCTUnwrap(artwork.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var artworkPixels = [UInt8](repeating: 0, count: width * height * 4)
        try artworkPixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.draw(cgArtwork, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        try save(artworkPixels, name: "artwork-source")
        for shadow in [Float(0), 1] {
            let output = try render(source, width: width, height: height, progress: 0.7, shadow: shadow)
            try save(output, name: "vignette-\(Int(shadow))")
        }
        for angle in [100, 90, 75, 60, 45, 35] {
            let output = try render(source, width: width, height: height,
                progress: Float(EffectSettings.progress(angle: Double(angle), clearAngle: 100)),
                blur: 0.5, shadow: 0.3,
                tiltRadians: Float(EffectSettings.tiltRadians(angle: Double(angle), clearAngle: 100)),
                pixelScale: Float(width) / 1512)
            try save(output, name: "fold-\(angle)")
            let artworkOutput = try render(artworkPixels, width: width, height: height,
                progress: Float(EffectSettings.progress(angle: Double(angle), clearAngle: 100)),
                blur: 0.5, shadow: 0.3,
                tiltRadians: Float(EffectSettings.tiltRadians(angle: Double(angle), clearAngle: 100)),
                pixelScale: Float(width) / 1512)
            try save(artworkOutput, name: "artwork-fold-\(angle)")
        }
    }
}
