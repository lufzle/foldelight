// Copyright (C) 2026 Dario Farzati
// SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

private enum Palette {
    static let cyan = Color(red: 0.48, green: 0.75, blue: 0.77)
    static let pink = Color(red: 0.78, green: 0.52, blue: 0.65)
    static let gold = Color(red: 0.79, green: 0.67, blue: 0.43)
    static let ink = Color(red: 0.16, green: 0.17, blue: 0.19)
    static let text = Color(red: 0.90, green: 0.89, blue: 0.85)
    static let muted = Color(red: 0.64, green: 0.65, blue: 0.65)
}

/// A static, deterministic grain: no timer, animation, or random work per frame.
private struct PaperGrain: View {
    var body: some View {
        Canvas { context, size in
            for row in stride(from: 0, to: Int(size.height), by: 4) {
                for column in stride(from: 0, to: Int(size.width), by: 4) {
                    let seed = (row * 73 + column * 137) % 23
                    let rect = CGRect(x: CGFloat(column) + CGFloat(seed % 3), y: CGFloat(row), width: 1, height: 1)
                    context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(Double(seed) / 650)))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct FoldMark: View {
    var body: some View {
        ZStack {
            Path { p in p.move(to: CGPoint(x: 2, y: 7)); p.addLine(to: CGPoint(x: 18, y: 12)); p.addLine(to: CGPoint(x: 17, y: 35)); p.addLine(to: CGPoint(x: 2, y: 29)); p.closeSubpath() }.fill(Palette.cyan)
            Path { p in p.move(to: CGPoint(x: 18, y: 12)); p.addLine(to: CGPoint(x: 34, y: 3)); p.addLine(to: CGPoint(x: 32, y: 26)); p.addLine(to: CGPoint(x: 17, y: 35)); p.closeSubpath() }.fill(Palette.pink)
            Path { p in p.move(to: CGPoint(x: 17, y: 35)); p.addLine(to: CGPoint(x: 32, y: 26)); p.addLine(to: CGPoint(x: 42, y: 32)); p.addLine(to: CGPoint(x: 27, y: 41)); p.closeSubpath() }.fill(Palette.gold)
        }.frame(width: 44, height: 44).accessibilityHidden(true)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    private var selected: Color { Palette.cyan }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.text.opacity(0.09)).frame(height: 1)
            if model.section == "About" { about }
            else { settingsContent }
            footer
        }
        .padding(.horizontal, 30).padding(.top, 38).padding(.bottom, 22)
        .frame(width: 1000, height: 760)
        .background { Palette.ink.overlay(PaperGrain()) }
        .foregroundStyle(Palette.text)
        .font(BrandFont.text(13))
        .preferredColorScheme(.dark).tint(selected)
    }

    private var header: some View {
        HStack(spacing: 12) {
            FoldMark()
            VStack(alignment: .leading, spacing: 0) {
                Text("foldelight").font(BrandFont.text(30, weight: .semibold)).tracking(-1.1)
                Text("A little fold. A little delight.").font(BrandFont.text(11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            HStack(spacing: 4) {
                tab("Settings", section: "Settings")
                tab("About", section: "About")
            }.padding(4).background(.white.opacity(0.035), in: Capsule())
        }.padding(.bottom, 23)
    }
    private func tab(_ title: String, section: String) -> some View {
        Button { model.section = section } label: {
            Text(title).font(BrandFont.text(12, weight: .medium))
                .foregroundStyle(model.section == section ? Palette.text : Palette.muted)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .background(model.section == section ? Palette.text.opacity(0.09) : .clear, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private var settingsContent: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.025))
                    RadialGradient(colors: [selected.opacity(0.13), .clear], center: .center, startRadius: 15, endRadius: 260)
                    VStack(spacing: 25) {
                        interactiveLaptop(width: 425)
                        Button { model.playPreview() } label: {
                            Label("Play the fold", systemImage: "play.fill").font(BrandFont.text(12, weight: .medium))
                                .padding(.horizontal, 17).padding(.vertical, 10).background(.white.opacity(0.06), in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel("Animate preview")
                    }
                }.frame(height: 335).clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.055)))
                HStack(alignment: .firstTextBaseline) {
                    Text("Lid angle").font(BrandFont.text(13, weight: .medium))
                    Spacer()
                    Text(String(format: "%.0f°", model.displayedAngle)).font(BrandFont.text(26)).monospacedDigit().foregroundStyle(selected)
                }
                LidAngleSlider(previewAngle: Binding(get: { model.displayedAngle }, set: { model.previewAngle = $0 }),
                    clearAngle: $model.settings.clearAngle, followsPhysicalLid: model.followLid,
                    beginPreviewInteraction: model.beginManualPreview,
                    previewColor: Palette.cyan, activationColor: Palette.gold)
                HStack {
                    Label("Clears at \(Int(model.settings.clearAngle))°", systemImage: "diamond.fill")
                        .font(BrandFont.text(11)).foregroundStyle(Palette.gold)
                    Spacer()
                    Toggle("Match lid angle", isOn: Binding(get: { model.followLid }, set: { matchesLid in
                        if matchesLid {
                            model.stopPreviewAnimation()
                            model.followLid = true
                        } else {
                            _ = model.beginManualPreview()
                        }
                    }))
                        .toggleStyle(.switch).controlSize(.small).disabled(model.lidAngle == nil && !model.followLid)
                        .help("Match the miniature to your MacBook’s lid. Drag the miniature to take control.")
                }
            }.frame(width: 510)
            VStack(alignment: .leading, spacing: 18) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 12)
                effectSlider("Blur", detail: "Soft glass, with a clear hinge", value: $model.settings.blur, color: Palette.pink)
                effectSlider("Vignette", detail: "Soft shading along the sides", value: $model.settings.shadow, color: Palette.gold)
                HStack {
                    Button("Reset effect") { model.resetAppearance() }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("Try on desktop ↗") { model.testDesktop() }.buttonStyle(.plain).foregroundStyle(selected).disabled(!model.enabled || model.testing)
                }.font(BrandFont.text(11)).padding(.top, 5)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 7)
                HStack(alignment: .firstTextBaseline) {
                    Text("Current lid angle").font(BrandFont.text(13, weight: .medium))
                    Spacer()
                    Text(model.lidAngle.map { String(format: "%.0f°", $0) } ?? "—")
                        .font(BrandFont.text(26)).monospacedDigit().foregroundStyle(Palette.cyan)
                        .accessibilityLabel("Current lid angle")
                        .accessibilityValue(model.lidAngle.map { String(format: "%.0f degrees", $0) } ?? "Unavailable")
                }
                if model.lidAngle == nil {
                    Text(model.sensorStatus).font(BrandFont.text(11)).foregroundStyle(Palette.muted)
                }
                Button("Screen Recording settings ↗") { model.openPermissions() }
                    .buttonStyle(.plain).font(BrandFont.text(12)).foregroundStyle(Palette.cyan)
                Button("Reconnect lid sensor") { model.retrySensor() }
                    .buttonStyle(.plain).font(BrandFont.text(11)).foregroundStyle(Palette.muted)
                    .help("Close and reopen the lid sensor connection to restart angle readings.")
            }.frame(maxWidth: .infinity)
        }.padding(.top, 25).frame(maxHeight: .infinity, alignment: .top)
    }

    private var about: some View {
        HStack(spacing: 60) {
            VStack(alignment: .leading, spacing: 22) {
                FoldMark().scaleEffect(1.8).frame(width: 80, height: 80, alignment: .leading)
                Text("A softer edge\nto your everyday.").font(BrandFont.text(39, weight: .medium)).tracking(-1.2)
                Text("Version 0.1.0\nTypography: IBM Plex Sans · SIL Open Font License\nCreated by Dario Farzati · AGPL-3.0").font(BrandFont.text(11)).foregroundStyle(Palette.muted).lineSpacing(6)
            }
            interactiveLaptop(width: 390)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func interactiveLaptop(width: CGFloat) -> some View {
        InteractiveLaptopPreview(angle: PreviewLidDrag.clamped(model.displayedAngle), settings: model.settings,
            beginInteraction: model.beginManualPreview,
            changeAngle: { model.previewAngle = $0 })
            .frame(width: width)
    }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let error = model.error { Text(error).font(BrandFont.text(11)).foregroundStyle(Palette.gold).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                Circle().fill(model.enabled ? Palette.cyan : Palette.gold).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.starting ? "Connecting…" : model.enabled ? "Ready to follow your lead" : "A moment of stillness").font(BrandFont.text(12, weight: .medium))
                    Text(model.status).font(BrandFont.text(10)).foregroundStyle(Palette.muted).lineLimit(2)
                }
                Spacer()
                Button { model.toggle() } label: {
                    HStack(spacing: 9) { Image(systemName: model.enabled || model.starting ? "pause.fill" : "power"); Text(model.enabled || model.starting ? "Pause effect" : "Enable foldelight") }
                        .font(BrandFont.text(13, weight: .medium)).padding(.horizontal, 22).padding(.vertical, 12)
                        .foregroundStyle(Palette.ink).background(Palette.cyan, in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(.top, 17).overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.09)).frame(height: 1) }
    }
    private func effectSlider(_ title: String, detail: String, value: Binding<Double>, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).font(BrandFont.text(13, weight: .medium)); Spacer(); Text("\(Int(value.wrappedValue * 100))%").font(BrandFont.text(12)).monospacedDigit().foregroundStyle(color) }
            Text(detail).font(BrandFont.text(10)).foregroundStyle(Palette.muted)
            Slider(value: value, in: 0...1).tint(color).controlSize(.small).accessibilityLabel(title)
        }
    }
}
