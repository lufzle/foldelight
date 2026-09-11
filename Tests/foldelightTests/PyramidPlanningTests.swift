// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import foldelight

final class PyramidPlanningTests: XCTestCase {
    func testUniformsPrecomputePerFrameOptics() {
        let theta = Float(37 * Double.pi / 180)
        let uniforms = BendUniforms(progress: 0.64, blur: 0.5, shadow: 0.3,
                                    pixelScale: 2, tiltRadians: theta)
        XCTAssertEqual(uniforms.progress, 0.64, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.sinTilt, sin(theta), accuracy: 0.000_001)
        XCTAssertEqual(uniforms.cosTilt, cos(theta), accuracy: 0.000_001)
        XCTAssertEqual(uniforms.blurAmount, sin(theta) * 0.5, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.vignetteAmount, 0.60 * sqrt(0.64) * 0.3, accuracy: 0.000_001)
        XCTAssertEqual(uniforms.edgeShadeAmount, 0.95 * sin(theta) * 0.3, accuracy: 0.000_001)
        XCTAssertEqual(MemoryLayout<BendUniforms>.stride, 32)
    }

    func testPyramidPlanDoesNoWorkForClearOrUnblurredFrames() {
        XCTAssertEqual(GaussianPyramidPlan.requiredLevelCount(
            for: BendUniforms(progress: 0, blur: 1, shadow: 0), available: 8), 0)
        XCTAssertEqual(GaussianPyramidPlan.requiredLevelCount(
            for: BendUniforms(progress: 1, blur: 0, shadow: 0), available: 8), 0)
        XCTAssertEqual(GaussianPyramidPlan.requiredLevelCount(
            for: BendUniforms(progress: 1, blur: 1, shadow: 0), available: 0), 0)
        XCTAssertEqual(GaussianPyramidPlan.threadgroupWidth, 8)
        XCTAssertEqual(GaussianPyramidPlan.threadgroupHeight, 8)
    }

    func testSlightFoldUsesOneLevelAndDeepFoldCanUseAllLevels() {
        let slight = BendUniforms(
            progress: Float(EffectSettings.progress(angle: 99.4, clearAngle: 100)),
            blur: 0.5, shadow: 0.3, pixelScale: 2,
            tiltRadians: Float(EffectSettings.tiltRadians(angle: 99.4, clearAngle: 100)))
        XCTAssertEqual(GaussianPyramidPlan.requiredLevelCount(for: slight, available: 8), 1)

        let deep = BendUniforms(progress: 1, blur: 0.5, shadow: 0.3,
                                pixelScale: 2, tiltRadians: 68 * .pi / 180)
        XCTAssertEqual(GaussianPyramidPlan.requiredLevelCount(for: deep, available: 8), 8)
    }

    func testGeneratedPyramidPlansAreBoundedAndMonotonic() {
        for scale in [Float(1), 2, 3] {
            var previous = 0
            for step in 0...1_000 {
                let blur = Float(step) / 1_000
                let uniforms = BendUniforms(progress: 1, blur: blur, shadow: 0.3,
                                            pixelScale: scale, tiltRadians: 55 * .pi / 180)
                let count = GaussianPyramidPlan.requiredLevelCount(for: uniforms, available: 8)
                XCTAssertGreaterThanOrEqual(count, previous, "scale=\(scale), blur=\(blur)")
                XCTAssertTrue(0...8 ~= count)
                previous = count
            }
        }
    }

    func testPlanCoversEveryMipTheShaderCanSample() {
        for degrees in stride(from: 0.1, through: 68.0, by: 0.7) {
            for blur in stride(from: Float(0.01), through: 1, by: 0.03) {
                let uniforms = BendUniforms(progress: 1, blur: blur, shadow: 0.3,
                                            pixelScale: 2, tiltRadians: Float(degrees * .pi / 180))
                let count = GaussianPyramidPlan.requiredLevelCount(for: uniforms, available: 8)
                for height in stride(from: Float(0), through: 1, by: 0.025) {
                    for perimeter in [Float(0), 0.5, 1] {
                        let depth = pow(height, 1.8)
                        let sigma = uniforms.blurAmount * 48 * depth * uniforms.pixelScale * (1 + 0.85 * perimeter)
                        let lod = 0.5 * log2(1 + 3 * sigma * sigma)
                        guard lod >= 0.001 else { continue }
                        let compactLOD = max(0, lod - 1)
                        let lower = Int(floor(compactLOD))
                        let highestNeeded = min(7, lower + (compactLOD - Float(lower) > 1e-5 ? 1 : 0))
                        XCTAssertLessThan(highestNeeded, count,
                                          "degrees=\(degrees), blur=\(blur), height=\(height)")
                    }
                }
            }
        }
    }
}
