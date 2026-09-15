import SwiftUI

/// Right-side inspector: cursor, smoothing, zoom style, blur, framing,
/// background gallery, camera layout. Everything live-updates the preview.
struct InspectorView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cursorSection
                zoomSection
                framingSection
                backgroundSection
                layoutSection
                Divider()
                Button("Regenerate auto-zoom") {
                    viewModel.regenerateKeyframes()
                }
            }
            .padding(14)
        }
        .foregroundStyle(.white)
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Cursor")
            labeledSlider("Size", value: $viewModel.settings.cursorSize, range: 0.5...3)
            Picker("Smoothing", selection: $viewModel.settings.smoothnessPreset) {
                Text("Rapid").tag(SmoothnessPreset.rapid)
                Text("Quick").tag(SmoothnessPreset.quick)
                Text("Default").tag(SmoothnessPreset.standard)
                Text("Slow").tag(SmoothnessPreset.slow)
            }
            .pickerStyle(.menu)
        }
    }

    private var zoomSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Zoom & motion")
            Picker("Style", selection: $viewModel.settings.zoomStyle) {
                Text("Focused").tag(ZoomStyle.focused)
                Text("Smooth").tag(ZoomStyle.smooth)
            }
            .pickerStyle(.segmented)
            labeledSlider("Motion blur", value: $viewModel.settings.motionBlurStrength, range: 0...1)
        }
    }

    private var framingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Frame")
            labeledSlider("Padding", value: $viewModel.settings.padding, range: 0...0.2)
            labeledSlider("Corners", value: $viewModel.settings.cornerRadius, range: 0...0.15)
            Toggle("Drop shadow", isOn: $viewModel.settings.shadowEnabled)
        }
    }

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Background")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Backgrounds.presets) { preset in
                    BackgroundThumbnail(preset: preset,
                                        isSelected: viewModel.settings.background == .preset(preset.id))
                        .onTapGesture {
                            viewModel.settings.background = .preset(preset.id)
                        }
                }
            }
            HStack {
                Text("Custom")
                Spacer()
                ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private var layoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Camera layout")
            Picker("Layout", selection: $viewModel.settings.cameraLayout) {
                Text("Screen").tag(CameraLayout.screenOnly)
                Text("Bubble").tag(CameraLayout.screenPlusWebcamBubble)
                Text("Webcam").tag(CameraLayout.webcamFull)
            }
            .pickerStyle(.segmented)
            .disabled(!viewModel.hasWebcam)
            if !viewModel.hasWebcam {
                Text("No webcam track in this project.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var customColorBinding: Binding<Color> {
        Binding(get: {
            if case let .custom(startHex, _) = viewModel.settings.background {
                return Color(nsColor: Backgrounds.color(hex: startHex))
            }
            return .black
        }, set: { newColor in
            let nsColor = NSColor(newColor)
            let startHex = Backgrounds.hex(nsColor)
            let endHex = Backgrounds.hex(nsColor.usingColorSpace(.deviceRGB)?
                .shadow(withLevel: 0.55) ?? nsColor)
            viewModel.settings.background = .custom(startHex: startHex, endHex: endHex)
        })
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 76, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}

private struct BackgroundThumbnail: View {
    let preset: Backgrounds.Preset
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(.clear)
            .background {
                if let kind = preset.wallpaper {
                    Image(nsImage: Backgrounds.cachedWallpaper(kind,
                                                               size: NSSize(width: 96, height: 64),
                                                               startHex: preset.startHex,
                                                               endHex: preset.endHex))
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [Color(nsColor: Backgrounds.color(hex: preset.startHex)),
                                            Color(nsColor: Backgrounds.color(hex: preset.endHex))],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.2),
                              lineWidth: isSelected ? 2 : 1))
            .aspectRatio(1.5, contentMode: .fit)
            .help(preset.name)
    }
}
