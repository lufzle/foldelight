// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import MetalKit
@testable import foldelight

final class BlackoutRenderTests: XCTestCase {
    func testActualShaderFadesEveryPixelIncludingMenuRowsAndGlassSurround() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try DamageFixture(device: device, width: 192, height: 128)
        let renderer = try BendRenderer(device: device)
        for progress: Float in [0, 0.0001, 0.3, 0.8, 1] {
            var uniforms = BendUniforms(progress: progress, blur: 0.5, shadow: 0.3, pixelScale: 2)
            let original = try fixture.render(renderer, uniforms: uniforms)
            var previous = original
            for opacity: Float in [0.25, 0.5, 0.75, 1] {
                uniforms.blackout = opacity
                let result = try fixture.render(renderer, uniforms: uniforms)
                var maximumError = 0.0
                for i in result.indices {
                    if i % 4 == 3 { XCTAssertEqual(result[i], 255); continue }
                    maximumError = max(maximumError, abs(Double(result[i]) - Double(original[i]) * Double(1 - opacity)))
                    XCTAssertLessThanOrEqual(result[i], previous[i])
                    if opacity == 1 { XCTAssertEqual(result[i], 0) }
                }
                XCTAssertLessThanOrEqual(maximumError, 1.1, "Fade changes brightness without moving glass pixels")
                previous = result
            }
            uniforms.blackout = 0
            XCTAssertEqual(try fixture.render(renderer, uniforms: uniforms), original,
                "Reopening must restore the exact glass, blur and rounded contour")
        }
    }

    func testFullBlackAvoidsPyramidAllocationAndInvalidOpacityFailsClear() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try BendRenderer(device: device)
        let fixture = try DamageFixture(device: device, width: 3024, height: 1964)
        let uniforms = BendUniforms(progress: 1, blur: 1, shadow: 1, pixelScale: 2, blackout: 1)
        let output = try fixture.render(renderer, uniforms: uniforms)
        XCTAssertEqual(renderer.pyramidAllocatedBytesForTesting, 0)
        XCTAssertEqual(GaussianPyramidPlan.requiredLevelCount(for: uniforms, available: 8), 0)
        XCTAssertTrue(stride(from: 0, to: output.count, by: 4).allSatisfy {
            output[$0] == 0 && output[$0 + 1] == 0 && output[$0 + 2] == 0 && output[$0 + 3] == 255
        })
        XCTAssertEqual(MemoryLayout<BendUniforms>.stride, 32)
        for invalid: Float in [.nan, .infinity, -.infinity] {
            XCTAssertEqual(BendUniforms(progress: 1, blur: 1, shadow: 1, blackout: invalid).blackout, 0)
        }
        XCTAssertEqual(BendUniforms(progress: 1, blur: 1, shadow: 1, blackout: -1).blackout, 0)
        XCTAssertEqual(BendUniforms(progress: 1, blur: 1, shadow: 1, blackout: 2).blackout, 1)
    }

    func testNativeResolutionBlackoutGPUCost() throws {
        guard ProcessInfo.processInfo.environment["FOLDELIGHT_GPU_BENCHMARK"] == "1" else {
            throw XCTSkip("Set FOLDELIGHT_GPU_BENCHMARK=1 for native GPU timings")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let fixture = try DamageFixture(device: device, width: 3024, height: 1964, readableOutput: false)
        let renderer = try BendRenderer(device: device)
        for opacity: Float in [0, 0.5, 1] {
            var durations: [Double] = []
            for iteration in 0..<30 {
                let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
                try renderer.encode(command: command, pass: fixture.pass, source: fixture.source,
                    uniforms: BendUniforms(progress: 0.8, blur: 0.5, shadow: 0.3, pixelScale: 2, blackout: opacity),
                    refreshPyramid: iteration == 0)
                command.commit(); command.waitUntilCompleted()
                XCTAssertEqual(command.status, .completed)
                if iteration >= 5 { durations.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
            }
            durations.sort()
            print("BLACKOUT_GPU opacity=\(opacity) median_ms=\(durations[durations.count / 2]) max_ms=\(durations.last!)")
        }
    }
}
