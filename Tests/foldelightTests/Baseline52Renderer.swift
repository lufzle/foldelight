// Benchmark snapshot of 52bf1ef. Only type names, test import, and shader lookup differ.
// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import MetalKit
import CoreVideo
@testable import foldelight

struct Baseline52BendUniforms {
    var progress: Float
    var pixelScale: Float = 1
    var sinTilt: Float
    var cosTilt: Float
    var blurAmount: Float
    var vignetteAmount: Float
    var edgeShadeAmount: Float
    private var padding: Float = 0

    init(progress: Float, blur: Float, shadow: Float, pixelScale: Float = 1,
         tiltRadians: Float? = nil) {
        let boundedProgress = max(0, min(1, progress))
        let theta = max(0, min(68 * .pi / 180,
            tiltRadians ?? boundedProgress * (68 * .pi / 180)))
        let boundedShadow = max(0, min(1, shadow))
        let sinTilt = sin(theta)
        self.progress = boundedProgress
        self.pixelScale = pixelScale
        self.sinTilt = sinTilt
        self.cosTilt = cos(theta)
        self.blurAmount = sinTilt * blur
        self.vignetteAmount = 0.60 * sqrt(boundedProgress) * boundedShadow
        self.edgeShadeAmount = 0.95 * sinTilt * boundedShadow
    }
}

enum Baseline52GaussianPyramidPlan {
    static let maximumLevels = 8
    static let maximumPerimeterGain: Float = 1.85
    static let threadgroupWidth = 8
    static let threadgroupHeight = 8

    static func requiredLevelCount(for uniforms: Baseline52BendUniforms, available: Int) -> Int {
        guard available > 0, uniforms.progress > 0, uniforms.blurAmount > 0 else { return 0 }
        let maximumSigma = uniforms.blurAmount * 48 * uniforms.pixelScale * maximumPerimeterGain
        let maximumLOD = 0.5 * log2(1 + 3 * maximumSigma * maximumSigma)
        let highestCompactLevel = Int(ceil(max(0, maximumLOD - 1)))
        return min(available, max(1, highestCompactLevel + 1))
    }
}

private final class Baseline52RenderMetrics {
    private let lock = NSLock()
    private var epoch = 0
    func currentEpoch() -> Int { lock.lock(); defer { lock.unlock() }; return epoch }
    private var frames = 0
    private var gpuMilliseconds = 0.0
    private var maximumMilliseconds = 0.0
    private var presentations = 0
    private var firstPresentation = 0.0
    private var lastPresentation = 0.0
    private var intervals: [Double] = []
    private var intervalIndex = 0
    private var sensorAges: [Double] = []
    private var sensorAgeIndex = 0
    private var lastSensorSampledAt = 0.0
    private var submissionMargins: [Double] = []
    private var submissionMarginIndex = 0
    func recordPresentation(_ time: Double, sensorSampledAt: Double?, epoch: Int) {
        guard time > 0 else { return }
        lock.lock()
        guard epoch == self.epoch else { lock.unlock(); return }
        if firstPresentation == 0 { firstPresentation = time }
        if lastPresentation > 0 && time > lastPresentation {
            let interval = (time - lastPresentation) * 1000
            if intervals.count < 4096 { intervals.append(interval) }
            else { intervals[intervalIndex] = interval; intervalIndex = (intervalIndex + 1) % 4096 }
        }
        if let sensorSampledAt, sensorSampledAt > lastSensorSampledAt, time >= sensorSampledAt {
            let age = (time - sensorSampledAt) * 1000
            if sensorAges.count < 4096 { sensorAges.append(age) }
            else { sensorAges[sensorAgeIndex] = age; sensorAgeIndex = (sensorAgeIndex + 1) % 4096 }
            lastSensorSampledAt = sensorSampledAt
        }
        lastPresentation = max(lastPresentation, time)
        presentations += 1
        lock.unlock()
    }
    func record(_ command: MTLCommandBuffer, epoch: Int) {
        guard command.status == .completed else { return }
        let duration = (command.gpuEndTime - command.gpuStartTime) * 1000
        lock.lock()
        guard epoch == self.epoch else { lock.unlock(); return }
        frames += 1
        gpuMilliseconds += duration
        maximumMilliseconds = max(maximumMilliseconds, duration)
        lock.unlock()
    }
    func recordSubmission(at time: Double, deadline: Double, epoch: Int) {
        lock.lock()
        guard epoch == self.epoch else { lock.unlock(); return }
        let margin = (deadline - time) * 1_000
        if submissionMargins.count < 4096 { submissionMargins.append(margin) }
        else {
            submissionMargins[submissionMarginIndex] = margin
            submissionMarginIndex = (submissionMarginIndex + 1) % 4096
        }
        lock.unlock()
    }
    func reportAndReset() {
        lock.lock()
        epoch += 1
        let count = frames, total = gpuMilliseconds, maximum = maximumMilliseconds
        let presented = presentations
        let duration = lastPresentation - firstPresentation
        let sortedIntervals = intervals.sorted()
        let sortedSensorAges = sensorAges.sorted()
        let sortedSubmissionMargins = submissionMargins.sorted()
        presentations = 0
        firstPresentation = 0
        lastPresentation = 0
        intervals.removeAll(keepingCapacity: true)
        sensorAges.removeAll(keepingCapacity: true)
        sensorAgeIndex = 0
        lastSensorSampledAt = 0
        submissionMargins.removeAll(keepingCapacity: true)
        submissionMarginIndex = 0
        intervalIndex = 0
        frames = 0
        gpuMilliseconds = 0
        maximumMilliseconds = 0
        lock.unlock()
        if presented > 1 && duration > 0 && !sortedIntervals.isEmpty {
            let p95 = sortedIntervals[min(sortedIntervals.count - 1, Int(ceil(Double(sortedIntervals.count) * 0.95)) - 1)]
            DebugLog.log("foldelight presentation: %d frames; average %.2f fps; recent interval p95 %.3f ms", presented,
                Double(presented - 1) / duration, p95)
        }
        if count > 0 {
            DebugLog.log("foldelight render: %d completed frames; GPU average %.3f ms, maximum %.3f ms", count, total / Double(count), maximum)
        }
        if !sortedSensorAges.isEmpty {
            let p95 = sortedSensorAges[min(sortedSensorAges.count - 1, Int(ceil(Double(sortedSensorAges.count) * 0.95)) - 1)]
            DebugLog.log("foldelight motion latency: %d changed samples; sensor-to-present p95 %.3f ms, maximum %.3f ms",
                sortedSensorAges.count, p95, sortedSensorAges.last!)
        }
        if !sortedSubmissionMargins.isEmpty {
            let p05 = sortedSubmissionMargins[Int(Double(sortedSubmissionMargins.count - 1) * 0.05)]
            let missed = sortedSubmissionMargins.filter { $0 < 0 }.count
            DebugLog.log("foldelight submission: %d frames; deadline misses %d; margin p05 %.3f ms",
                         sortedSubmissionMargins.count, missed, p05)
        }
    }
}

final class Baseline52BendRenderer: NSObject {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private static let resourceLock = NSLock()
    private static var pipelines: [UInt64: (MTLRenderPipelineState, MTLComputePipelineState)] = [:]
    private static var previews: [UInt64: MTLTexture] = [:]
    private let metrics = Baseline52RenderMetrics()
    private let drawablePass: MTLRenderPassDescriptor = {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        return pass
    }()
    // CAMetalDisplayLink requests one-frame latency. Do not queue an older
    // angle behind a frame that has not finished on the GPU.
    private let inFlight = DispatchSemaphore(value: 1)
    private let gaussianPipeline: MTLComputePipelineState
    private let gaussianThreadgroupSize: MTLSize
    private var pyramidLevels: [MTLTexture] = []
    private var pyramidTexture: MTLTexture?
    private var validPyramidLevelCount = 0
    private var needsPyramid = true
    private var firstPresentationPending = false
    private var cache: CVMetalTextureCache?
    private var backing: CVMetalTexture?
    private var texture: MTLTexture?
    var settings = EffectSettings()
    var angle = 105.0
    var collectsMetrics = false
    var onFirstPresentation: (() -> Void)?
    var onSubmissionFailure: (() -> Void)?
    private var reportedPresentation = false

    var pyramidAllocatedBytesForTesting: Int { pyramidTexture?.allocatedSize ?? 0 }
    var pyramidValidLevelCountForTesting: Int { validPyramidLevelCount }
    var gaussianPipelineForTesting: MTLComputePipelineState { gaussianPipeline }

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderError.unavailable }
        self.queue = queue
        let resources = try Self.cachedPipeline(device: device)
        pipeline = resources.0
        gaussianPipeline = resources.1
        gaussianThreadgroupSize = MTLSize(width: Baseline52GaussianPyramidPlan.threadgroupWidth,
                                          height: Baseline52GaussianPyramidPlan.threadgroupHeight, depth: 1)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    private static func cachedPipeline(device: MTLDevice) throws -> (MTLRenderPipelineState, MTLComputePipelineState) {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        if let pipeline = pipelines[device.registryID] { return pipeline }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Bend52bf1ef.metal")
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "bendVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "bendFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let function = library.makeFunction(name: "gaussianDownsample") else { throw RenderError.unavailable }
        let compute = try device.makeComputePipelineState(function: function)
        pipelines[device.registryID] = (pipeline, compute)
        return (pipeline, compute)
    }

    func setFrame(_ buffer: CVPixelBuffer) {
        guard let cache else { return }
        var output: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &output)
        guard status == kCVReturnSuccess, let output, let metal = CVMetalTextureGetTexture(output) else { return }
        backing = output
        texture = metal
        needsPyramid = true
        validPyramidLevelCount = 0
    }

    func reportPerformance() { metrics.reportAndReset() }

    func clear() {
        reportPerformance()
        texture = nil
        backing = nil
        pyramidTexture = nil
        pyramidLevels.removeAll()
        needsPyramid = true
        validPyramidLevelCount = 0
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    func loadPreview() throws {
        Self.resourceLock.lock()
        defer { Self.resourceLock.unlock() }
        if let cached = Self.previews[device.registryID] {
            texture = cached
            needsPyramid = true
            validPyramidLevelCount = 0
            return
        }
        let image = try PreviewArtwork.image()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw RenderError.unavailable }
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let converted = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard converted else { throw RenderError.unavailable }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable }
        pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        Self.previews[device.registryID] = texture
        self.texture = texture
        needsPyramid = true
        validPyramidLevelCount = 0
    }

    /// Encode preprocessing and rendering together on this renderer's serial command queue.
    /// Refresh once for each new capture, then reuse its pyramid while the lid animates.
    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, source: MTLTexture,
                uniforms: Baseline52BendUniforms, refreshPyramid: Bool = true) throws {
        var sampled = source
        if uniforms.progress > 0 && uniforms.blurAmount > 0 {
            // Level zero is the first half-resolution Gaussian image. The live
            // IOSurface remains the sharp source, so reserving a full-resolution
            // level in this private texture only wastes memory and cache capacity.
            let pyramidWidth = max(1, source.width / 2)
            let pyramidHeight = max(1, source.height / 2)
            let changedSize = pyramidTexture?.width != pyramidWidth || pyramidTexture?.height != pyramidHeight
                || pyramidTexture?.pixelFormat != source.pixelFormat
            if changedSize {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
                    width: pyramidWidth, height: pyramidHeight, mipmapped: true)
                descriptor.mipmapLevelCount = min(descriptor.mipmapLevelCount, Baseline52GaussianPyramidPlan.maximumLevels)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead, .shaderWrite, .pixelFormatView]
                guard let allocated = device.makeTexture(descriptor: descriptor) else { throw RenderError.unavailable }
                pyramidTexture = allocated
                pyramidLevels = try (0..<allocated.mipmapLevelCount).map { level in
                    guard let view = allocated.makeTextureView(pixelFormat: source.pixelFormat, textureType: .type2D,
                        levels: level..<(level + 1), slices: 0..<1) else { throw RenderError.unavailable }
                    return view
                }
                validPyramidLevelCount = 0
            }
            guard let pyramid = pyramidTexture else { throw RenderError.unavailable }
            let requiredLevels = Baseline52GaussianPyramidPlan.requiredLevelCount(for: uniforms, available: pyramidLevels.count)
            let firstInvalidLevel = refreshPyramid || changedSize ? 0 : min(validPyramidLevelCount, requiredLevels)
            if firstInvalidLevel < requiredLevels {
                guard let encoder = command.makeComputeCommandEncoder() else { throw RenderError.unavailable }
                encoder.setComputePipelineState(gaussianPipeline)
                for level in firstInvalidLevel..<requiredLevels {
                    let output = pyramidLevels[level]
                    encoder.setTexture(level == 0 ? source : pyramidLevels[level - 1], index: 0)
                    encoder.setTexture(output, index: 1)
                    encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                        threadsPerThreadgroup: gaussianThreadgroupSize)
                    encoder.memoryBarrier(resources: [output])
                }
                encoder.endEncoding()
            }
            validPyramidLevelCount = refreshPyramid || changedSize
                ? requiredLevels : max(validPyramidLevelCount, requiredLevels)
            sampled = pyramid
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.unavailable }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(sampled, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Baseline52BendUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Submit to the drawable supplied by CAMetalDisplayLink. No call in this
    /// path can wait for the layer's drawable pool.
    @discardableResult
    func draw(drawable: CAMetalDrawable, pixelScale: Float, sensorSampledAt: Double? = nil,
              targetDeadline: Double? = nil) -> Bool {
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        return submit(drawable: drawable, pixelScale: pixelScale, sensorSampledAt: sensorSampledAt,
                      targetDeadline: targetDeadline, permitHeld: true)
    }

    private func submit(drawable: CAMetalDrawable, pixelScale: Float, sensorSampledAt: Double? = nil,
                        targetDeadline: Double? = nil, permitHeld: Bool) -> Bool {
        guard let texture, let command = queue.makeCommandBuffer() else {
            if permitHeld { inFlight.signal() }
            return false
        }
        drawablePass.colorAttachments[0].texture = drawable.texture
        let uniforms = Baseline52BendUniforms(progress: Float(EffectSettings.progress(angle: angle, clearAngle: settings.clearAngle)),
            blur: Float(settings.blur), shadow: Float(settings.shadow),
            pixelScale: pixelScale,
            tiltRadians: Float(EffectSettings.tiltRadians(angle: angle, clearAngle: settings.clearAngle)))
        do {
            try encode(command: command, pass: drawablePass, source: texture,
                       uniforms: uniforms, refreshPyramid: needsPyramid)
            drawablePass.colorAttachments[0].texture = nil
        } catch {
            drawablePass.colorAttachments[0].texture = nil
            inFlight.signal()
            return false
        }
        if uniforms.progress > 0 && uniforms.blurAmount > 0 { needsPyramid = false }
        let retainedBacking = backing
        let semaphore = inFlight
        let metrics = metrics
        let epoch = collectsMetrics ? metrics.currentEpoch() : nil
        let reportPresentation = !reportedPresentation && !firstPresentationPending
        if reportPresentation { firstPresentationPending = true }
        command.addCompletedHandler { [weak self] command in
            _ = retainedBacking
            if let epoch { metrics.record(command, epoch: epoch) }
            semaphore.signal()
            guard command.status != .completed else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.firstPresentationPending = false
                self.needsPyramid = true
                self.validPyramidLevelCount = 0
                self.onSubmissionFailure?()
            }
        }
        if epoch != nil || reportPresentation {
            drawable.addPresentedHandler { [weak self] drawable in
                if let epoch { metrics.recordPresentation(drawable.presentedTime, sensorSampledAt: sensorSampledAt, epoch: epoch) }
                guard reportPresentation else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.firstPresentationPending = false
                    guard !self.reportedPresentation else { return }
                    self.reportedPresentation = true
                    self.onFirstPresentation?()
                }
            }
        }
        command.present(drawable)
        command.commit()
        if let epoch, let targetDeadline {
            metrics.recordSubmission(at: CACurrentMediaTime(), deadline: targetDeadline, epoch: epoch)
        }
        return true
    }
    enum RenderError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Metal could not create the desktop renderer." }
    }
}
