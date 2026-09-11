// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

/// Real IOSurface mapping and Metal submission with an offscreen presentation
/// sink. These tests check renderer state, not WindowServer presentation timing.
final class RendererSubmissionTests: XCTestCase {
    func testChangesDuringZeroBlurSurviveAndMappingRejectionPreservesNewestSource() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try DamageFixture(device: device, width: 131, height: 99)
        let renderer = try BendRenderer(device: device)
        let full = try BendRenderer(device: device)
        renderer.angle = 55
        renderer.settings.blur = 1
        let drawable = SubmissionDrawable(texture: fixture.output)
        XCTAssertTrue(renderer.setFrame(try buffer(fixture)))
        try drawAndWait(renderer, drawable)
        let first = CGRect(x: 0, y: 4, width: 9, height: 13)
        fixture.change([first], frame: 17)
        XCTAssertTrue(renderer.setFrame(try buffer(fixture), damage: [first]))
        renderer.settings.blur = 0
        try drawAndWait(renderer, drawable)
        let second = CGRect(x: 95, y: 71, width: 19, height: 17)
        fixture.change([second], frame: 28)
        XCTAssertTrue(renderer.setFrame(try buffer(fixture), damage: [second]))
        var invalid: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 17, 13, kCVPixelFormatType_OneComponent8,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &invalid), kCVReturnSuccess)
        XCTAssertFalse(renderer.setFrame(try XCTUnwrap(invalid), damage: nil))
        XCTAssertEqual(renderer.sourcePixelWidth, 131)
        renderer.settings.blur = 1
        try drawAndWait(renderer, drawable)
        let partialPixels = fixture.readOutput()
        let settings = renderer.settings
        let uniforms = BendUniforms(progress: Float(EffectSettings.progress(angle: renderer.angle, clearAngle: settings.clearAngle)),
            blur: Float(settings.blur), shadow: Float(settings.shadow), pixelScale: 2,
            tiltRadians: Float(EffectSettings.tiltRadians(angle: renderer.angle, clearAngle: settings.clearAngle)))
        XCTAssertEqual(partialPixels, try fixture.render(full, uniforms: uniforms))
        XCTAssertEqual(try mipBytes(renderer), try mipBytes(full))
        XCTAssertEqual(drawable.requests, 3)
    }

    func testBusySubmissionDoesNotQueueAnotherFrameAndRecovers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try DamageFixture(device: device, width: 64, height: 48)
        let renderer = try BendRenderer(device: device)
        let drawable = SubmissionDrawable(texture: fixture.output)
        let event = try XCTUnwrap(device.makeSharedEvent())
        let hold = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        hold.encodeWaitForEvent(event, value: 1)
        hold.commit()
        defer { event.signaledValue = 1 }
        renderer.angle = 70
        XCTAssertTrue(renderer.setFrame(try buffer(fixture)))
        XCTAssertTrue(renderer.draw(drawable: drawable, pixelScale: 1))
        let started = CACurrentMediaTime()
        XCTAssertFalse(renderer.draw(drawable: drawable, pixelScale: 1))
        XCTAssertLessThan(CACurrentMediaTime() - started, 0.05, "Backpressure must not wait for GPU completion")
        XCTAssertEqual(drawable.requests, 1)
        event.signaledValue = 1
        try drain(renderer)
        XCTAssertTrue(renderer.draw(drawable: drawable, pixelScale: 1))
        try drain(renderer)
        XCTAssertEqual(drawable.requests, 2)
    }

    func testCapturesDuringBlackoutRebuildCorrectBlurWhenReopened() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try DamageFixture(device: device, width: 131, height: 99)
        let renderer = try BendRenderer(device: device)
        let full = try BendRenderer(device: device)
        renderer.angle = 30
        let drawable = SubmissionDrawable(texture: fixture.output)
        XCTAssertTrue(renderer.setFrame(try buffer(fixture)))
        try drawAndWait(renderer, drawable)
        let before = try mipBytes(renderer)
        renderer.blackout = 1
        for (frame, damage) in [(12, CGRect(x: 0, y: 0, width: 17, height: 40)),
                                 (31, CGRect(x: 85, y: 60, width: 45, height: 38))] {
            fixture.change([damage], frame: frame)
            XCTAssertTrue(renderer.setFrame(try buffer(fixture), damage: [damage]))
            try drawAndWait(renderer, drawable)
            XCTAssertEqual(try mipBytes(renderer), before, "Fully black output must not recompute invisible blur")
            let output = fixture.readOutput()
            XCTAssertTrue(output.indices.allSatisfy { output[$0] == ($0 % 4 == 3 ? 255 : 0) })
        }
        renderer.blackout = 0.5
        try drawAndWait(renderer, drawable)
        let reopened = fixture.readOutput()
        let settings = renderer.settings
        let uniforms = BendUniforms(progress: Float(EffectSettings.progress(angle: 30, clearAngle: settings.clearAngle)),
            blur: Float(settings.blur), shadow: Float(settings.shadow), pixelScale: 2,
            tiltRadians: Float(EffectSettings.tiltRadians(angle: 30, clearAngle: settings.clearAngle)), blackout: 0.5)
        XCTAssertEqual(reopened, try fixture.render(full, uniforms: uniforms))
        XCTAssertEqual(try mipBytes(renderer), try mipBytes(full))
    }

    private func drawAndWait(_ renderer: BendRenderer, _ drawable: SubmissionDrawable) throws {
        XCTAssertTrue(renderer.draw(drawable: drawable, pixelScale: 2))
        try drain(renderer)
    }

    private func drain(_ renderer: BendRenderer) throws {
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
    }

    private func buffer(_ fixture: DamageFixture) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, fixture.width, fixture.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &result), kCVReturnSuccess)
        let buffer = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        fixture.pixels.withUnsafeBytes { bytes in
            for row in 0..<fixture.height {
                base.advanced(by: row * stride).copyMemory(from: bytes.baseAddress!.advanced(by: row * fixture.width * 4),
                    byteCount: fixture.width * 4)
            }
        }
        return buffer
    }

    private func mipBytes(_ renderer: BendRenderer) throws -> [[UInt8]] {
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
        XCTAssertEqual(command.status, .completed)
        return copies.map { copy in
            var bytes = [UInt8](repeating: 0, count: copy.width * copy.height * 4)
            bytes.withUnsafeMutableBytes {
                copy.getBytes($0.baseAddress!, bytesPerRow: copy.width * 4,
                    from: MTLRegionMake2D(0, 0, copy.width, copy.height), mipmapLevel: 0)
            }
            return bytes
        }
    }
}

private final class SubmissionDrawable: NSObject, CAMetalDrawable {
    let texture: MTLTexture
    let layer = CAMetalLayer()
    let drawableID = 0
    let presentedTime: CFTimeInterval = 0
    private(set) var requests = 0
    init(texture: MTLTexture) { self.texture = texture }
    func present() { requests += 1 }
    func present(at presentationTime: CFTimeInterval) { present() }
    func present(afterMinimumDuration duration: CFTimeInterval) { present() }
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {}
}
