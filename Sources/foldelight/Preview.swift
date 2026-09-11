// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI
import MetalKit

enum PreviewArtwork {
    static let imageSize = NSSize(width: 960, height: 600)
    static func image() throws -> NSImage {
        let resources = Bundle.main.url(forResource: "foldelight_foldelight", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        guard let url = resources.url(forResource: "LockScreen", withExtension: "png", subdirectory: "Preview"),
              let image = NSImage(contentsOf: url) else { throw ArtworkError.unavailable }
        // Keep the file's native bitmap pixels. Its point size only determines
        // layout; the renderer uploads and caches the original resolution.
        image.size = imageSize
        return image
    }

    enum ArtworkError: LocalizedError {
        case unavailable
        var errorDescription: String? { "The bundled lock screen could not be loaded." }
    }
}

/// Geometry participates in preview invalidation even when controls do not change.
struct PreviewGeometry: Equatable {
    var displayID: UInt32
    var screenWidth: Double
    var backingScale: Double
    var drawableWidth: Double
    var drawableHeight: Double
    var refreshRate: Int

    func pixelScale(sourcePixelWidth: Int) -> Float {
        guard screenWidth > 0, screenWidth.isFinite, sourcePixelWidth > 0 else { return 1 }
        return Float(Double(sourcePixelWidth) / screenWidth)
    }
}

struct PreviewFrameInputs: Equatable {
    var angle: Double
    var settings: EffectSettings
    var geometry: PreviewGeometry
}

/// Shared by the real preview and deterministic submission/lifecycle tests.
struct PreviewPlaybackState {
    private(set) var inputs: PreviewFrameInputs?
    private(set) var isRunning = false

    @discardableResult mutating func configure(_ inputs: PreviewFrameInputs,
        sourcePixelWidth: Int?, configureClock: (PreviewGeometry) -> Void = { _ in }) -> Bool {
        guard let sourcePixelWidth, sourcePixelWidth > 0, self.inputs != inputs else { return false }
        let geometryChanged = self.inputs?.geometry != inputs.geometry
        self.inputs = inputs
        isRunning = true
        if geometryChanged { configureClock(inputs.geometry) }
        return true
    }
    mutating func submit(settled: Bool, using submission: () -> Bool) {
        guard inputs != nil, isRunning else { return }
        if submission(), settled { isRunning = false }
    }
    mutating func submissionFailed() {
        guard inputs != nil else { return }
        isRunning = true
    }
    mutating func dismantle() { inputs = nil; isRunning = false }
}

/// SwiftUI does not update a representable merely because its backing screen
/// changes. Forward native geometry events to the same configuration path.
final class PreviewMetalView: MTKView {
    var geometryChanged: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                name: NSWindow.didChangeScreenNotification, object: window)
        }
        geometryChanged?()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        geometryChanged?()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        geometryChanged?()
    }
    override func layout() {
        super.layout()
        geometryChanged?()
    }
    @objc private func screenChanged(_ notification: Notification) { geometryChanged?() }
    deinit { NotificationCenter.default.removeObserver(self) }
}

struct MetalPreview: NSViewRepresentable {
    var angle: Double
    var settings: EffectSettings
    @MainActor final class Coordinator {
        var renderer: BendRenderer?
        let clock = MetalFrameClock()
        var target: Double?
        var smoother = AngleSmoother(105)
        var playback = PreviewPlaybackState()
        weak var view: PreviewMetalView?

        func geometryChanged() {
            guard let view, let target, let renderer else { return }
            update(view, angle: target, settings: renderer.settings)
        }
        func update(_ view: PreviewMetalView, angle: Double, settings: EffectSettings) {
            guard let renderer, let sourcePixelWidth = renderer.sourcePixelWidth,
                  let layer = view.layer as? CAMetalLayer,
                  let screen = view.window?.screen ?? NSScreen.main else { return }
            self.view = view
            let geometry = PreviewGeometry(
                displayID: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 ?? 0,
                screenWidth: Double(screen.frame.width), backingScale: Double(view.window?.backingScaleFactor ?? screen.backingScaleFactor),
                drawableWidth: Double(view.drawableSize.width), drawableHeight: Double(view.drawableSize.height),
                refreshRate: screen.maximumFramesPerSecond)
            let first = target == nil
            guard playback.configure(PreviewFrameInputs(angle: angle, settings: settings, geometry: geometry),
                sourcePixelWidth: sourcePixelWidth, configureClock: { [clock] _ in
                    clock.configure(layer: layer, screen: screen)
                }) else { return }
            target = angle
            renderer.settings = settings
            if first { smoother = AngleSmoother(angle); renderer.angle = angle }
            let pixelScale = geometry.pixelScale(sourcePixelWidth: sourcePixelWidth)
            renderer.onSubmissionFailure = { [weak self] in
                guard let self else { return }
                self.playback.submissionFailed()
                if self.playback.isRunning { self.clock.start() }
            }
            clock.tick = { [weak self] update in
                guard let self, let target = self.target else { return }
                renderer.angle = self.smoother.advance(to: target, at: update.targetPresentationTimestamp)
                renderer.blackout = FoldBlackout.opacity(angle: renderer.angle, clearAngle: renderer.settings.clearAngle)
                self.playback.submit(settled: renderer.angle == target) {
                    autoreleasepool {
                        renderer.draw(drawable: update.drawable, pixelScale: pixelScale,
                                      targetDeadline: update.targetTimestamp)
                    }
                }
                if !self.playback.isRunning { self.clock.stop() }
            }
            clock.start()
        }
        func dismantle() {
            playback.dismantle()
            view?.geometryChanged = nil
            renderer?.onSubmissionFailure = nil
            clock.stop()
            clock.invalidate()
            view = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PreviewMetalView {
        let view = PreviewMetalView()
        view.isPaused = true; view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.colorPixelFormat = .bgra8Unorm
        view.geometryChanged = { [weak coordinator = context.coordinator] in coordinator?.geometryChanged() }
        if let device = MTLCreateSystemDefaultDevice() {
            view.device = device
            do {
                let renderer = try BendRenderer(device: device)
                try renderer.loadPreview()
                context.coordinator.renderer = renderer
            } catch {
                let label = NSTextField(labelWithString: "Preview unavailable: \(error.localizedDescription)")
                label.frame = NSRect(x: 15, y: 25, width: 300, height: 50)
                view.addSubview(label)
            }
        }
        return view
    }
    func updateNSView(_ view: PreviewMetalView, context: Context) {
        context.coordinator.update(view, angle: angle, settings: settings)
    }
    static func dismantleNSView(_ view: PreviewMetalView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}

struct LaptopPreview: View {
    var angle: Double
    var settings: EffectSettings
    var articulatesLid = false
    var body: some View {
        VStack(spacing: 0) {
            MetalPreview(angle: angle, settings: settings)
                .aspectRatio(1.6, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 11))
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 17).fill(Color(white: 0.055)))
                .overlay(alignment: .top) { UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4).fill(Color(white: 0.055)).frame(width: 58, height: 12) }
                .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.15), lineWidth: 1))
                .padding(.horizontal, 18)
                .rotation3DEffect(.degrees(articulatesLid ? PreviewLidDrag.hingeRotation(angle: angle) : 0),
                    axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.2)
            UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7)
                .fill(LinearGradient(colors: [Color(white: 0.65), Color(white: 0.32)], startPoint: .top, endPoint: .bottom))
                .frame(height: 8)
                .overlay(alignment: .top) { Capsule().fill(.black.opacity(0.3)).frame(width: 66, height: 3) }
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 12)
    }
}

struct InteractiveLaptopPreview: View {
    var angle: Double
    var settings: EffectSettings
    var beginInteraction: () -> Double
    var changeAngle: (Double) -> Void
    @State private var drag: PreviewLidDrag?
    @GestureState private var isDragging = false
    @FocusState private var isFocused: Bool

    var body: some View {
        LaptopPreview(angle: angle, settings: settings, articulatesLid: true)
            .overlay {
                // The hit region never folds with the lid. A fully closed
                // laptop remains easy to grab and reopen.
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .updating($isDragging) { _, active, _ in active = true }
                            .onChanged { value in
                                if drag == nil {
                                    isFocused = true
                                    drag = PreviewLidDrag(angle: beginInteraction())
                                }
                                guard var current = drag else { return }
                                changeAngle(current.update(translation: Double(value.translation.height),
                                    travel: Double(geometry.size.height)))
                                drag = current
                            }
                            .onEnded { _ in drag = nil })
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay(alignment: .bottom) {
                Capsule().fill(Color.accentColor.opacity(isFocused ? 0.7 : 0))
                    .frame(width: 54, height: 2).offset(y: 10)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .onKeyPress(.upArrow) { adjust(by: 5); return .handled }
            .onKeyPress(.downArrow) { adjust(by: -5); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Mini MacBook lid")
            .accessibilityValue("\(Int(angle.rounded())) degrees")
            .accessibilityHint("Drag up to open and down to close, or use the arrow keys.")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(by: 5)
                case .decrement: adjust(by: -5)
                @unknown default: break
                }
            }
            .help("Drag up to open the lid. Drag down to close it.")
            .onChange(of: isDragging) { _, active in
                // GestureState also resets if the system cancels the gesture.
                if !active { drag = nil }
            }
            .onDisappear { drag = nil }
    }

    private func adjust(by degrees: Double) {
        var current = drag ?? PreviewLidDrag(angle: beginInteraction())
        changeAngle(current.adjust(by: degrees))
        if drag != nil { drag = current }
    }
}
