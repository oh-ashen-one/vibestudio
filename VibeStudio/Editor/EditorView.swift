import AVKit
import SwiftUI

struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VideoPlayer(player: viewModel.player)
                GeometryReader { geometry in
                    CursorOverlayView(videoSize: viewModel.videoSize,
                                      viewSize: geometry.size,
                                      currentTime: viewModel.currentTime,
                                      rawPath: viewModel.rawPath,
                                      smoothedPath: viewModel.smoothedPath,
                                      clicks: viewModel.clicks,
                                      showRaw: viewModel.showRawPath,
                                      showSmoothed: viewModel.showSmoothedPath)
                }
            }
            .layoutPriority(1)

            timelineBar
                .padding(10)
                .background(Color(white: 0.12))
        }
        .frame(minWidth: 800, minHeight: 540)
        .background(Color(white: 0.08))
        .overlay {
            if let error = viewModel.loadError {
                Text("Failed to load project: \(error)")
                    .foregroundStyle(.red)
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var timelineBar: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            Text(EditorViewModel.timeString(viewModel.currentTime))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            Slider(value: Binding(get: { viewModel.currentTime },
                                  set: { viewModel.seek(to: $0) }),
                   in: 0...max(viewModel.duration, 0.01))

            Text(EditorViewModel.timeString(viewModel.duration))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            Divider().frame(height: 16)

            Toggle("Raw path", isOn: $viewModel.showRawPath)
                .toggleStyle(.checkbox)
            Toggle("Smoothed path", isOn: $viewModel.showSmoothedPath)
                .toggleStyle(.checkbox)
        }
        .foregroundStyle(.white)
    }
}

/// Debug overlay: raw cursor path (thin red), smoothed path (thick green),
/// click dots — drawn up to the current playhead, in video pixel space mapped
/// onto the aspect-fitted display rect.
struct CursorOverlayView: View {
    let videoSize: CGSize
    let viewSize: CGSize
    let currentTime: Double
    let rawPath: [CursorPoint]
    let smoothedPath: [CursorPoint]
    let clicks: [CursorPoint]
    let showRaw: Bool
    let showSmoothed: Bool

    var body: some View {
        Canvas { context, size in
            guard videoSize.width > 0, videoSize.height > 0 else { return }
            let rect = Self.fittedRect(videoSize: videoSize, in: size)

            func viewPoint(_ point: CursorPoint) -> CGPoint {
                CGPoint(x: rect.minX + point.x / videoSize.width * rect.width,
                        y: rect.minY + point.y / videoSize.height * rect.height)
            }

            func stroke(_ points: [CursorPoint], color: Color, width: CGFloat) {
                let visible = points.filter { $0.t <= currentTime }
                guard let first = visible.first else { return }
                var path = Path()
                path.move(to: viewPoint(first))
                for point in visible.dropFirst() {
                    path.addLine(to: viewPoint(point))
                }
                context.stroke(path, with: .color(color), lineWidth: width)
            }

            if showRaw {
                stroke(rawPath, color: .red.opacity(0.7), width: 1)
            }
            if showSmoothed {
                stroke(smoothedPath, color: .green, width: 2.5)
            }
            for click in clicks where click.t <= currentTime {
                let center = viewPoint(click)
                let radius: CGFloat = 4
                let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(.red))
            }
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .allowsHitTesting(false)
    }

    static func fittedRect(videoSize: CGSize, in size: CGSize) -> CGRect {
        let scale = min(size.width / videoSize.width, size.height / videoSize.height)
        let width = videoSize.width * scale
        let height = videoSize.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}
