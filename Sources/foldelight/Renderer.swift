// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import MetalKit
import CoreVideo

struct BendUniforms {
    var progress: Float
    var pixelScale: Float = 1
    var sinTilt: Float
    var cosTilt: Float
    var blurAmount: Float
    var vignetteAmount: Float
    var edgeShadeAmount: Float
    var blackout: Float

    var needsDiffusion: Bool { progress > 0 && blurAmount > 0 && blackout < 1 }

    init(progress: Float, blur: Float, shadow: Float, pixelScale: Float = 1,
         tiltRadians: Float? = nil, blackout: Float = 0) {
        let boundedProgress = max(0, min(1, progress))
        let maximumTilt = Float(EffectSettings.maximumTiltDegrees * .pi / 180)
        let theta = max(0, min(maximumTilt, tiltRadians ?? boundedProgress * maximumTilt))
        let boundedShadow = max(0, min(1, shadow))
        let sinTilt = sin(theta)
        self.progress = boundedProgress
        self.pixelScale = pixelScale
        self.sinTilt = sinTilt
        self.cosTilt = cos(theta)
        self.blurAmount = sinTilt * blur
        self.vignetteAmount = 0.60 * sqrt(boundedProgress) * boundedShadow
        self.edgeShadeAmount = 0.95 * sinTilt * boundedShadow
        self.blackout = blackout.isFinite ? max(0, min(1, blackout)) : 0
    }
}

enum GaussianPyramidPlan {
    static let maximumLevels = 8
    static let maximumPerimeterGain: Float = 1.85
    static let threadgroupWidth = 8
    static let threadgroupHeight = 8

    static func requiredLevelCount(for uniforms: BendUniforms, available: Int) -> Int {
        guard available > 0, uniforms.needsDiffusion else { return 0 }
        let maximumSigma = uniforms.blurAmount * 48 * uniforms.pixelScale * maximumPerimeterGain
        let maximumLOD = 0.5 * log2(1 + 3 * maximumSigma * maximumSigma)
        let highestCompactLevel = Int(ceil(max(0, maximumLOD - 1)))
        return min(available, max(1, highestCompactLevel + 1))
    }

    /// Enclose accumulated source damage. Invalid metadata requires a full rebuild.
    static func sourceDamage(_ damage: [CGRect], width: Int, height: Int) -> CGRect {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var affected = CGRect.null
        for rect in damage {
            guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return bounds }
            if !rect.isEmpty { affected = affected.union(rect.intersection(bounds)) }
        }
        return affected.isNull ? .zero : affected.integral.intersection(bounds)
    }

    /// The extreme bilinear sample touches source texel centers within 2.2 pixels
    /// of the output center. Expand by two source pixels plus one destination
    /// pixel, including odd-size resampling and clamped texture edges.
    static func downstreamDamage(_ damage: CGRect, sourceWidth: Int, sourceHeight: Int,
                                 width: Int, height: Int) -> CGRect {
        guard !damage.isEmpty else { return .zero }
        let scaleX = Double(width) / Double(sourceWidth)
        let scaleY = Double(height) / Double(sourceHeight)
        let expanded = damage.insetBy(dx: -2, dy: -2)
        let mapped = CGRect(x: expanded.minX * scaleX, y: expanded.minY * scaleY,
                            width: expanded.width * scaleX, height: expanded.height * scaleY)
            .insetBy(dx: -1, dy: -1).integral
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let clipped = mapped.intersection(bounds)
        return clipped.width * clipped.height > Double(width * height) * 0.65 ? bounds : clipped
    }
}

private final class SubmissionTimestamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    func mark(_ time: Double) { lock.lock(); value = time; lock.unlock() }
    func read() -> Double? { lock.lock(); defer { lock.unlock() }; return value }
}

final class BendRenderer: NSObject {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    private static let resourceLock = NSLock()
    private static var pipelines: [UInt64: (MTLRenderPipelineState, MTLComputePipelineState, MTLComputePipelineState)] = [:]
    private static var previews: [UInt64: MTLTexture] = [:]
    let metrics = PerformanceMetrics()
    private let drawablePass: MTLRenderPassDescriptor = {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        return pass
    }()
    // CAMetalDisplayLink requests one-frame latency. Do not queue an older
    // angle behind a frame that has not finished on the GPU.
    private let inFlight: DispatchSemaphore
    private let gaussianPipeline: MTLComputePipelineState
    private let gaussianRegionPipeline: MTLComputePipelineState
    private let gaussianThreadgroupSize: MTLSize
    private var pyramidLevels: [MTLTexture] = []
    private var pyramidTexture: MTLTexture?
    private var validPyramidLevelCount = 0
    private var pyramidSourceWidth = 0
    private var pyramidSourceHeight = 0
    private var pyramidUpdate = PyramidUpdateState()
    private var firstPresentationPending = false
    private var cache: CVMetalTextureCache?
    private var backing: CVMetalTexture?
    private var texture: MTLTexture?
    var settings = EffectSettings()
    var angle = 105.0
    var blackout = 0.0
    var collectsMetrics = false {
        didSet { if oldValue != collectsMetrics { metrics.setEnabled(collectsMetrics) } }
    }
    // Mutable renderer state and callbacks share one serial owner. Preview uses
    // main by default; the desktop installs its dedicated render executor.
    var callbackExecutor: RenderCallbackExecutor = { work in MainRunLoop.perform { work() }; return true }
    var onFirstPresentation: (() -> Void)?
    var onSubmissionFailure: (() -> Void)?
    private var reportedPresentation = false

    var pyramidAllocatedBytesForTesting: Int { pyramidTexture?.allocatedSize ?? 0 }
    var pyramidTextureForTesting: MTLTexture? { pyramidTexture }
    var sourcePixelWidth: Int? { texture?.width }
    var pyramidValidLevelCountForTesting: Int { validPyramidLevelCount }
    var gaussianPipelineForTesting: MTLComputePipelineState { gaussianPipeline }

    init(device: MTLDevice, maxFramesInFlight: Int = 1) throws {
        inFlight = DispatchSemaphore(value: max(1, min(2, maxFramesInFlight)))
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderError.unavailable }
        self.queue = queue
        let resources = try Self.cachedPipeline(device: device)
        pipeline = resources.0
        gaussianPipeline = resources.1
        gaussianRegionPipeline = resources.2
        gaussianThreadgroupSize = MTLSize(width: GaussianPyramidPlan.threadgroupWidth,
                                          height: GaussianPyramidPlan.threadgroupHeight, depth: 1)
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    }

    private static func cachedPipeline(device: MTLDevice) throws -> (MTLRenderPipelineState, MTLComputePipelineState, MTLComputePipelineState) {
        resourceLock.lock()
        defer { resourceLock.unlock() }
        if let pipeline = pipelines[device.registryID] { return pipeline }
        let appResources = Bundle.main.url(forResource: "foldelight_foldelight", withExtension: "bundle").flatMap(Bundle.init(url:))
        let resources = appResources ?? Bundle.module
        guard let url = resources.url(forResource: "Bend", withExtension: "metal") else { throw RenderError.unavailable }
        let library = try device.makeLibrary(source: String(contentsOf: url), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "bendVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "bendFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let function = library.makeFunction(name: "gaussianDownsample") else { throw RenderError.unavailable }
        let compute = try device.makeComputePipelineState(function: function)
        guard let regionFunction = library.makeFunction(name: "gaussianDownsampleRegion") else { throw RenderError.unavailable }
        let regionCompute = try device.makeComputePipelineState(function: regionFunction)
        pipelines[device.registryID] = (pipeline, compute, regionCompute)
        return (pipeline, compute, regionCompute)
    }

    @discardableResult
    func setFrame(_ buffer: CVPixelBuffer, damage: [CGRect]? = nil) -> Bool {
        // The capture contract is BGRA. Reject unsupported buffers before
        // Core Video can pass an incompatible IOSurface stride to Metal.
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let cache else { return false }
        var output: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &output)
        guard status == kCVReturnSuccess, let output, let metal = CVMetalTextureGetTexture(output) else { return false }
        pyramidUpdate.accept(damage)
        backing = output
        texture = metal
        return true
    }

    func reportPerformance() { if collectsMetrics { metrics.snapshotAndReset().log() } }

    func clear() {
        reportPerformance()
        texture = nil
        backing = nil
        pyramidTexture = nil
        pyramidLevels.removeAll()
        pyramidUpdate.invalidate()
        validPyramidLevelCount = 0
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
    }

    func loadPreview() throws {
        Self.resourceLock.lock()
        defer { Self.resourceLock.unlock() }
        if let cached = Self.previews[device.registryID] {
            texture = cached
            pyramidUpdate.invalidate()
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
        pyramidUpdate.invalidate()
        validPyramidLevelCount = 0
    }

    /// Encode preprocessing and rendering together on this renderer's serial command queue.
    /// Refresh once for each new capture, then reuse its pyramid while the lid animates.
    func encode(command: MTLCommandBuffer, pass: MTLRenderPassDescriptor, source: MTLTexture,
                uniforms: BendUniforms, refreshPyramid: Bool = true, damage: [CGRect]? = nil) throws {
        var sampled = source
        if uniforms.needsDiffusion {
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
                descriptor.mipmapLevelCount = min(descriptor.mipmapLevelCount, GaussianPyramidPlan.maximumLevels)
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
            let requiredLevels = GaussianPyramidPlan.requiredLevelCount(for: uniforms, available: pyramidLevels.count)
            let sameSourceSize = pyramidSourceWidth == source.width && pyramidSourceHeight == source.height
            let fullSource = CGRect(x: 0, y: 0, width: source.width, height: source.height)
            let sourceDamage: CGRect
            if changedSize || !sameSourceSize || validPyramidLevelCount == 0 {
                sourceDamage = fullSource
            } else if refreshPyramid {
                sourceDamage = damage.map { GaussianPyramidPlan.sourceDamage($0, width: source.width, height: source.height) }
                    ?? fullSource
            } else {
                sourceDamage = .zero
            }
            var affected = sourceDamage
            var inputWidth = source.width, inputHeight = source.height
            var regions: [CGRect] = []
            for level in 0..<requiredLevels {
                let output = pyramidLevels[level]
                if changedSize || !sameSourceSize || level >= validPyramidLevelCount {
                    affected = CGRect(x: 0, y: 0, width: output.width, height: output.height)
                } else {
                    affected = GaussianPyramidPlan.downstreamDamage(affected, sourceWidth: inputWidth,
                        sourceHeight: inputHeight, width: output.width, height: output.height)
                }
                regions.append(affected)
                inputWidth = output.width
                inputHeight = output.height
            }
            if regions.contains(where: { !$0.isEmpty }) {
                guard let encoder = command.makeComputeCommandEncoder() else { throw RenderError.unavailable }
                for level in 0..<requiredLevels where !regions[level].isEmpty {
                    let output = pyramidLevels[level]
                    let region = regions[level]
                    let complete = region.width == Double(output.width) && region.height == Double(output.height)
                    encoder.setComputePipelineState(complete ? gaussianPipeline : gaussianRegionPipeline)
                    encoder.setTexture(level == 0 ? source : pyramidLevels[level - 1], index: 0)
                    encoder.setTexture(output, index: 1)
                    if !complete {
                        var origin = SIMD2<UInt32>(UInt32(region.minX), UInt32(region.minY))
                        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
                    }
                    encoder.dispatchThreads(MTLSize(width: Int(region.width), height: Int(region.height), depth: 1),
                        threadsPerThreadgroup: gaussianThreadgroupSize)
                    encoder.memoryBarrier(resources: [output])
                }
                encoder.endEncoding()
            }
            validPyramidLevelCount = !sourceDamage.isEmpty
                ? requiredLevels : max(validPyramidLevelCount, requiredLevels)
            pyramidSourceWidth = source.width
            pyramidSourceHeight = source.height
            sampled = pyramid
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError.unavailable }
        var uniforms = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(sampled, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BendUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Submit to the drawable supplied by CAMetalDisplayLink. No call in this
    /// path can wait for the layer's drawable pool.
    @discardableResult
    func draw(drawable: CAMetalDrawable, pixelScale: Float, sensorSampledAt: Double? = nil,
              targetDeadline: Double? = nil, timing: PerformanceFrameTiming? = nil) -> Bool {
        let epoch = collectsMetrics ? metrics.currentEpoch() : nil
        guard inFlight.wait(timeout: .now()) == .success else {
            if let epoch { metrics.record(.skippedBusy, epoch: epoch) }
            return false
        }
        let started = epoch == nil ? nil : CACurrentMediaTime()
        guard let texture, let command = queue.makeCommandBuffer() else {
            inFlight.signal()
            if let epoch { metrics.record(.failed, epoch: epoch) }
            return false
        }
        drawablePass.colorAttachments[0].texture = drawable.texture
        let uniforms = BendUniforms(progress: Float(EffectSettings.progress(angle: angle, clearAngle: settings.clearAngle)),
            blur: Float(settings.blur), shadow: Float(settings.shadow), pixelScale: pixelScale,
            tiltRadians: Float(EffectSettings.tiltRadians(angle: angle, clearAngle: settings.clearAngle)),
            blackout: Float(blackout))
        do {
            try encode(command: command, pass: drawablePass, source: texture,
                       uniforms: uniforms, refreshPyramid: pyramidUpdate.needsRefresh, damage: pyramidUpdate.damage)
            drawablePass.colorAttachments[0].texture = nil
        } catch {
            drawablePass.colorAttachments[0].texture = nil
            // An encoder may already have changed cache bookkeeping before a
            // later encoder failed. Its commands never reached the queue.
            pyramidUpdate.invalidate(); validPyramidLevelCount = 0
            inFlight.signal()
            if let epoch { metrics.record(.failed, epoch: epoch) }
            return false
        }
        pyramidUpdate.didSubmit(usedPyramid: uniforms.needsDiffusion)
        let retainedBacking = backing
        let commitTimestamp = epoch == nil ? nil : SubmissionTimestamp()
        let semaphore = inFlight, metrics = metrics
        let executeCallback = callbackExecutor
        let frameTiming = timing ?? PerformanceFrameTiming(sensorReadEnd: sensorSampledAt)
        let reportPresentation = !reportedPresentation && !firstPresentationPending
        if reportPresentation { firstPresentationPending = true }
        command.addCompletedHandler { [weak self] command in
            _ = retainedBacking
            if command.status == .completed {
                if let epoch {
                    metrics.record(.gpu(seconds: command.gpuEndTime - command.gpuStartTime), epoch: epoch)
                    if let commit = commitTimestamp?.read() {
                        metrics.record(.gpuQueueDelay(seconds: command.gpuStartTime - commit), epoch: epoch)
                    }
                }
                semaphore.signal()
            } else {
                if let epoch { metrics.record(.failed, epoch: epoch) }
                RenderCompletionDelivery.schedule(on: executeCallback, work: {
                    guard let self else { return }
                    self.firstPresentationPending = false
                    self.pyramidUpdate.invalidate()
                    self.validPyramidLevelCount = 0
                    self.onSubmissionFailure?()
                }, release: { semaphore.signal() })
            }
        }
        if epoch != nil || reportPresentation {
            drawable.addPresentedHandler { [weak self] drawable in
                if let epoch { metrics.record(.presentation(at: drawable.presentedTime, frame: frameTiming), epoch: epoch) }
                guard reportPresentation else { return }
                _ = executeCallback {
                    guard let self else { return }
                    self.firstPresentationPending = false
                    guard !self.reportedPresentation else { return }
                    self.reportedPresentation = true
                    self.onFirstPresentation?()
                }
            }
        }
        if let epoch, let started { metrics.record(.cpuEncode(seconds: CACurrentMediaTime() - started), epoch: epoch) }
        commitTimestamp?.mark(CACurrentMediaTime())
        command.commit()
        if let epoch, let targetDeadline {
            metrics.record(.commit(at: CACurrentMediaTime(), deadline: targetDeadline), epoch: epoch)
        }
        // CAMetalDisplayLink's deadline applies to this present call, not to
        // the earlier commit or a scheduled command-buffer convenience handler.
        drawable.present()
        if let epoch {
            metrics.record(.submitted, epoch: epoch)
            if let targetDeadline {
                metrics.record(.presentRequested(at: CACurrentMediaTime(), deadline: targetDeadline), epoch: epoch)
            }
        }
        return true
    }
    enum RenderError: LocalizedError {
        case unavailable
        var errorDescription: String? { "Metal could not create the desktop renderer." }
    }
}
