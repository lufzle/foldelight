// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

enum LidAngleHandle: Hashable {
    case preview, activation

    var range: ClosedRange<Double> {
        self == .preview ? PreviewLidDrag.angleRange : EffectSettings.clearAngleRange
    }
    var label: String { self == .preview ? "Preview lid angle" : "Activation angle" }
    func bounded(_ angle: Double) -> Double {
        let fallback = self == .preview ? range.upperBound : EffectSettings.defaultClearAngle
        return angle.isFinite ? min(range.upperBound, max(range.lowerBound, angle)) : fallback
    }
}

/// Both handles use the same physical scale, irrespective of their own limits.
struct LidAngleTrack {
    static let inset = 15.0
    let width: Double
    var travel: Double { width.isFinite ? max(0, width - 2 * Self.inset) : 0 }

    func position(angle: Double) -> Double {
        Self.inset + PreviewLidDrag.clamped(angle) / PreviewLidDrag.angleRange.upperBound * travel
    }
}

/// A handle keeps its identity when it crosses the other handle. Fractional
/// activation movement accumulates before whole-degree values are published.
struct LidAngleSliderDrag {
    let handle: LidAngleHandle
    private var rawAngle: Double
    private var previousTranslation = 0.0
    var value: Double { handle == .activation ? rawAngle.rounded() : rawAngle }

    init(handle: LidAngleHandle, angle: Double) {
        self.handle = handle
        rawAngle = handle.bounded(angle)
    }
    mutating func setValue(_ angle: Double) { rawAngle = handle.bounded(angle) }

    mutating func update(translation: Double, track: LidAngleTrack) -> Double? {
        guard translation.isFinite, track.travel > 0 else { return nil }
        let delta = translation - previousTranslation
        let candidate = rawAngle + delta / track.travel * PreviewLidDrag.angleRange.upperBound
        guard candidate.isFinite else { return nil }
        previousTranslation = translation
        rawAngle = handle.bounded(candidate)
        return value
    }
}

struct LidAngleSlider: View {
    @Binding var previewAngle: Double
    @Binding var clearAngle: Double
    var followsPhysicalLid: Bool
    var beginPreviewInteraction: () -> Double
    var previewColor: Color
    var activationColor: Color
    @State private var drag: LidAngleSliderDrag?
    @GestureState private var draggingHandle: LidAngleHandle?
    @FocusState private var focusedHandle: LidAngleHandle?

    var body: some View {
        GeometryReader { geometry in
            let track = LidAngleTrack(width: Double(geometry.size.width))
            ZStack(alignment: .topLeading) {
                Capsule().fill(.white.opacity(0.12))
                    .frame(width: track.travel, height: 4)
                    .offset(x: LidAngleTrack.inset, y: 13)
                Capsule().fill(activationColor.opacity(0.48))
                    .frame(width: max(0, track.position(angle: clearAngle) - LidAngleTrack.inset), height: 4)
                    .offset(x: LidAngleTrack.inset, y: 13)
                Rectangle().fill(activationColor.opacity(0.65))
                    .frame(width: 1.5, height: 25)
                    .position(x: track.position(angle: clearAngle), y: 29)
                    .allowsHitTesting(false)
                handle(.preview, track: track)
                handle(.activation, track: track)
            }
            .coordinateSpace(name: "lid-angle-track")
        }
        .frame(height: 62)
        .onChange(of: draggingHandle) { _, active in if active == nil { drag = nil } }
        .onDisappear { drag = nil }
    }

    private func handle(_ handle: LidAngleHandle, track: LidAngleTrack) -> some View {
        let isPreview = handle == .preview
        let enabled = !isPreview || !followsPhysicalLid
        let color = isPreview ? previewColor : activationColor
        return ZStack {
            Circle().stroke(color.opacity(focusedHandle == handle ? 0.55 : 0), lineWidth: 1)
                .frame(width: 27, height: 27)
            if isPreview {
                Circle().fill(color).frame(width: 17, height: 17)
                    .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: 14, height: 14).rotationEffect(.degrees(45))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        .opacity(enabled ? 1 : 0.55)
        .frame(width: 30, height: 30).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lid-angle-track"))
            .updating($draggingHandle) { _, active, _ in if enabled { active = handle } }
            .onChanged { event in
                guard enabled else { return }
                if drag == nil {
                    focusedHandle = handle
                    let start = isPreview ? beginPreviewInteraction() : clearAngle
                    drag = LidAngleSliderDrag(handle: handle, angle: start)
                }
                guard var current = drag, current.handle == handle else { return }
                if let value = current.update(translation: Double(event.translation.width), track: track) {
                    write(value, to: handle)
                }
                drag = current
            }
            .onEnded { _ in drag = nil })
        .focusable(enabled).focused($focusedHandle, equals: handle).focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { event in
            guard enabled else { return .ignored }
            let step = event.key == .leftArrow || event.key == .downArrow ? -1.0 : 1.0
            adjust(value(for: handle) + step, handle: handle)
            return .handled
        }
        .accessibilityRepresentation {
            Slider(value: Binding(get: { value(for: handle) }, set: { adjust($0, handle: handle) }),
                in: handle.range, step: 1) { Text(handle.label) }
                .disabled(!enabled)
                .accessibilityValue("\(Int(value(for: handle).rounded())) degrees")
                .accessibilityHint(isPreview ? "Changes only the miniature preview." : "The desktop effect clears at this opening angle.")
        }
        .help(isPreview ? "Drag to preview the lid angle." : "Drag to set when the fold clears.")
        .position(x: track.position(angle: value(for: handle)), y: isPreview ? 15 : 46)
    }

    private func value(for handle: LidAngleHandle) -> Double {
        handle.bounded(handle == .preview ? previewAngle : clearAngle)
    }
    private func write(_ value: Double, to handle: LidAngleHandle) {
        if handle == .preview {
            if previewAngle != value { previewAngle = value }
        } else if clearAngle != value { clearAngle = value }
    }
    private func adjust(_ value: Double, handle: LidAngleHandle) {
        guard handle != .preview || !followsPhysicalLid else { return }
        if handle == .preview, drag?.handle != .preview { _ = beginPreviewInteraction() }
        var current = drag?.handle == handle ? drag! : LidAngleSliderDrag(handle: handle, angle: value)
        current.setValue(value)
        write(current.value, to: handle)
        if drag?.handle == handle { drag = current }
    }
}
