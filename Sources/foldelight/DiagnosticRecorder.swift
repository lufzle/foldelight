// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ScreenCaptureKit
import AVFoundation

/// Explicit, short local recordings, independent from the effect's capture stream.
@MainActor
final class DiagnosticRecorder {
    private var session: AnyObject?
    var active: Bool { session != nil }

    func start() {
        guard !active else { return }
        let recording = DiagnosticRecordingSession { [weak self] result in
            guard let self else { return }
            self.session = nil
            switch result {
            case .success(let url):
                DebugLog.log("Diagnostic recording saved: %@", url.path)
            case .failure(let error):
                DebugLog.log("Diagnostic recording failed: %@", error.localizedDescription)
                self.showAlert("Diagnostic recording could not finish", error.localizedDescription)
            }
        }
        session = recording
        recording.start()
    }

    func stop() {
        (session as? DiagnosticRecordingSession)?.stop()
    }

    private func showAlert(_ title: String, _ detail: String) {
        DebugLog.log("Diagnostic recording: %@ — %@", title, detail)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.beginSheetModal(for: window) { _ in }
    }
}

@MainActor
private final class DiagnosticRecordingSession: NSObject, SCStreamDelegate {
    private enum State { case starting, recording, stopping, finished }
    private var state = State.starting
    private var stream: SCStream?
    private var writer: DiagnosticFrameWriter?
    private var deadline: Task<Void, Never>?
    private let completion: (Result<URL, Error>) -> Void

    init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }

    func start() {
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 15_000_000_000) }
            catch { return }
            self?.finish(.failure(DiagnosticFrameWriter.failure("Screen recording did not start in time.")))
        }
        Task { [self] in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard state == .starting else { return }
                guard let display = content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) ?? content.displays.first else {
                    throw DiagnosticFrameWriter.failure("No display is available to record.")
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = Int(filter.contentRect.width * Double(filter.pointPixelScale))
                configuration.height = Int(filter.contentRect.height * Double(filter.pointPixelScale))
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                configuration.queueDepth = 3
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.showsCursor = true
                configuration.capturesAudio = false
                if #available(macOS 15.0, *) { configuration.captureMicrophone = false }
                let folder = DebugLog.shared.folder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = folder.appendingPathComponent("diagnostic-\(UUID().uuidString).mp4")
                let writer = try DiagnosticFrameWriter(url: url, width: configuration.width, height: configuration.height,
                    started: { [weak self] in
                        Task { @MainActor in
                            guard let self, self.state == .starting else { return }
                            self.state = .recording
                            self.deadline?.cancel(); self.deadline = nil
                            DebugLog.log("Diagnostic recording started; automatic stop in 15 seconds")
                        }
                    }, completed: { [weak self] result in
                        Task { @MainActor in self?.finish(result) }
                    })
                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                self.writer = writer
                self.stream = stream
                try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
                DebugLog.log("Diagnostic recording requested: %dx%d 60 fps fixed wall-clock timeline; audio disabled", configuration.width, configuration.height)
                try await stream.startCapture()
                if state == .stopping || state == .finished { try? await stream.stopCapture() }
            } catch { finish(.failure(error)) }
        }
    }

    func stop() {
        guard state == .starting || state == .recording else { return }
        state = .stopping
        deadline?.cancel(); deadline = nil
        if let writer { writer.stop() }
        else { finish(.failure(DiagnosticFrameWriter.failure("Recording stopped before capture started."))) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard state != .finished else { return }
        state = .finished
        deadline?.cancel(); deadline = nil
        let oldStream = stream
        stream = nil
        if case .failure = result { writer?.cancel() }
        writer = nil
        Task { try? await oldStream?.stopCapture() }
        completion(result)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in self?.finish(.failure(error)) }
    }
}

/// All frame and encoder state lives on one queue. Repeats the most recent
/// IOSurface-backed frame so a static desktop still produces a full-length video.
private final class DiagnosticFrameWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "foldelight.diagnostic.writer", qos: .userInitiated)
    private let url: URL
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let started: () -> Void
    private let completed: (Result<URL, Error>) -> Void
    private var latest: CVPixelBuffer?
    private var timer: DispatchSourceTimer?
    private var startTime: UInt64?
    private var lastPresentation = CMTime.invalid
    private var finished = false
    private var sourceFrames = 0
    private var writtenFrames = 0
    private var skippedFrames = 0
    private static let duration = 15.0

    init(url: URL, width: Int, height: Int, started: @escaping () -> Void,
         completed: @escaping (Result<URL, Error>) -> Void) throws {
        self.url = url
        self.started = started
        self.completed = completed
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(40_000_000, width * height * 6),
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        super.init()
        guard assetWriter.canAdd(input) else { throw Self.failure("The video encoder is unavailable.") }
        assetWriter.add(input)
        guard assetWriter.startWriting() else { throw assetWriter.error ?? Self.failure("The video encoder could not start.") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finished, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        sourceFrames += 1
        latest = frame
        guard startTime == nil else { return }
        startTime = DispatchTime.now().uptimeNanoseconds
        assetWriter.startSession(atSourceTime: .zero)
        append(at: .zero)
        guard !finished else { return }
        started()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0 / 60.0, repeating: 1.0 / 60.0, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            let elapsed = self.elapsed
            if elapsed >= Self.duration { self.finishWriting(duration: Self.duration) }
            else { self.append(at: CMTime(seconds: elapsed, preferredTimescale: 60_000)) }
        }
        self.timer = timer
        timer.resume()
    }

    private var elapsed: Double {
        guard let startTime else { return 0 }
        return Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000_000
    }

    private func append(at time: CMTime) {
        guard let latest, !finished else { return }
        guard input.isReadyForMoreMediaData else { skippedFrames += 1; return }
        if lastPresentation.isValid && CMTimeCompare(time, lastPresentation) <= 0 { return }
        guard adaptor.append(latest, withPresentationTime: time) else {
            fail(assetWriter.error ?? Self.failure("The encoder rejected a video frame.")); return
        }
        lastPresentation = time
        writtenFrames += 1
    }

    func stop() { queue.async { [self] in finishWriting(duration: min(Self.duration, elapsed)) } }
    func cancel() {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            timer?.cancel(); timer = nil; latest = nil
            assetWriter.cancelWriting()
        }
    }

    private func finishWriting(duration: Double) {
        guard !finished else { return }
        guard startTime != nil, writtenFrames > 0 else {
            fail(Self.failure("No screen frames were available to record.")); return
        }
        finished = true
        timer?.cancel(); timer = nil; latest = nil
        assetWriter.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000))
        input.markAsFinished()
        DebugLog.log("Diagnostic frames: source=%d written=%d encoder-busy=%d wall-duration=%.3f seconds", sourceFrames, writtenFrames, skippedFrames, duration)
        assetWriter.finishWriting { [self] in
            if assetWriter.status == .completed { completed(.success(url)) }
            else { completed(.failure(assetWriter.error ?? Self.failure("The recording could not be finalized."))) }
        }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil; latest = nil
        assetWriter.cancelWriting()
        completed(.failure(error))
    }

    static func failure(_ message: String) -> Error {
        NSError(domain: "foldelight.recording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
