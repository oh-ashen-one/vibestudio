import SwiftUI

/// Export panel: preset + aspect pickers, trim summary, progress, cancel.
struct ExportPanelView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var preset: ExportPreset = .sourceNative
    @State private var aspect: ExportAspect = .a16x9
    @State private var format: ExportFormat = .mp4

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export")
                .font(.headline)

            Picker("Preset", selection: $preset) {
                Text("Source native").tag(ExportPreset.sourceNative)
                Text("1080p 60 fps").tag(ExportPreset.p1080_60)
                Text("1080p 30 fps").tag(ExportPreset.p1080_30)
                Text("4K 60 fps").tag(ExportPreset.p4k_60)
            }
            .pickerStyle(.menu)

            Picker("Format", selection: $format) {
                Text("MP4").tag(ExportFormat.mp4)
                Text("GIF (480p, ≤30 fps)").tag(ExportFormat.gif)
            }
            .pickerStyle(.segmented)

            Picker("Aspect", selection: $aspect) {
                Text("16:9").tag(ExportAspect.a16x9)
                Text("9:16").tag(ExportAspect.a9x16)
                Text("1:1").tag(ExportAspect.a1x1)
            }
            .pickerStyle(.segmented)

            if !preset.isAllowed(sourceSize: viewModel.videoSize) {
                Text("4K requires a source of at least 2160px height.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            let range = viewModel.exportRange
            Text("Range \(EditorViewModel.timeString(range.lowerBound)) – \(EditorViewModel.timeString(range.upperBound)) · \(String(format: "%.1f", range.upperBound - range.lowerBound))s")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let progress = viewModel.exportProgress {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                    Button("Cancel", role: .cancel) {
                        viewModel.cancelExport()
                    }
                }
            } else {
                if let error = viewModel.exportError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                    Button("Export…") {
                        exportTapped()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!preset.isAllowed(sourceSize: viewModel.videoSize))
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func exportTapped() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.nameFieldStringValue = "VibeStudio-\(aspect.rawValue).\(format == .gif ? "gif" : "mp4")"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            viewModel.startExport(preset: preset, aspect: aspect, format: format, outputURL: url)
        }
    }
}
