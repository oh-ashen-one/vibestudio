import AVKit
import SwiftUI

// Force a direct symbol reference to AVKit's AVPlayerView so the linker keeps
// the AVKit framework: without it, SwiftUI's VideoPlayer crashes at runtime
// ("failed to demangle superclass of VideoPlayerView from mangled name
// 'So12AVPlayerViewC'") because its ObjC superclass was dead-stripped.
private let _forceAVKitLinkage: AnyClass = AVPlayerView.self

struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                previewArea
                    .layoutPriority(1)
                transportBar
                    .padding(10)
                ZoomTrackView(viewModel: viewModel)
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            .background(Color(white: 0.12))

            InspectorView(viewModel: viewModel)
                .frame(width: 250)
                .background(Color(white: 0.09))
        }
        .frame(minWidth: 1000, minHeight: 620)
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

    // MARK: - Preview

    private var previewArea: some View {
        GeometryReader { geometry in
            ZStack {
                PreviewBackgroundView(spec: viewModel.settings.background)
                let padding = geometry.size.width * viewModel.settings.padding
                let aspect = viewModel.videoSize.height > 0
                    ? viewModel.videoSize.width / viewModel.videoSize.height : 16.0 / 9.0
                metalContainer(cornerRadius: geometry.size.height * viewModel.settings.cornerRadius)
                    .aspectRatio(aspect, contentMode: .fit)
                    .padding(padding)
            }
        }
        .clipped()
    }

    private func metalContainer(cornerRadius: CGFloat) -> some View {
        Group {
            if viewModel.renderer.isReady {
                PreviewMetalView(renderer: viewModel.renderer)
                    .overlay {
                        GeometryReader { geometry in
                            CursorOverlayView(videoSize: viewModel.videoSize,
                                              viewSize: geometry.size,
                                              currentTime: viewModel.currentTime,
                                              sourceRect: viewModel.cameraModel.state(
                                                  at: viewModel.currentTime,
                                                  videoSize: viewModel.videoSize
                                              ).sourceRect(videoSize: viewModel.videoSize),
                                              rawPath: viewModel.rawPath,
                                              smoothedPath: viewModel.smoothedPath,
                                              clicks: viewModel.clicks,
                                              showRaw: viewModel.showRawPath,
                                              showSmoothed: viewModel.showSmoothedPath)
                        }
                    }
            } else {
                VideoPlayer(player: viewModel.player)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: max(cornerRadius, 2)))
        .shadow(color: .black.opacity(viewModel.settings.shadowEnabled ? 0.55 : 0),
                radius: 30, y: 14)
    }

    // MARK: - Transport

    private var transportBar: some View {
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

/// Renders the background spec behind the preview: preset gradient,
/// procedural wallpaper, or custom gradient.
struct PreviewBackgroundView: View {
    let spec: BackgroundSpec

    var body: some View {
        switch spec {
        case .preset(let id):
            if let preset = Backgrounds.preset(id: id) {
                content(startHex: preset.startHex, endHex: preset.endHex, wallpaper: preset.wallpaper)
            }
        case .custom(let startHex, let endHex):
            content(startHex: startHex, endHex: endHex, wallpaper: nil)
        }
    }

    private func content(startHex: String, endHex: String, wallpaper: Backgrounds.WallpaperKind?) -> some View {
        Group {
            if let wallpaper {
                Image(nsImage: Backgrounds.cachedWallpaper(wallpaper,
                                                           size: NSSize(width: 640, height: 400),
                                                           startHex: startHex, endHex: endHex))
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(nsColor: Backgrounds.color(hex: startHex)),
                                        Color(nsColor: Backgrounds.color(hex: endHex))],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// Debug overlay: raw cursor path (thin red), smoothed path (thick green),
/// click dots — drawn up to the playhead, mapped through the current camera
/// source rect so it aligns with the zoomed preview.
struct CursorOverlayView: View {
    let videoSize: CGSize
    let viewSize: CGSize
    let currentTime: Double
    let sourceRect: CGRect
    let rawPath: [CursorPoint]
    let smoothedPath: [CursorPoint]
    let clicks: [CursorPoint]
    let showRaw: Bool
    let showSmoothed: Bool

    var body: some View {
        Canvas { context, _ in
            guard sourceRect.width > 0, sourceRect.height > 0 else { return }

            func viewPoint(_ point: CursorPoint) -> CGPoint {
                CGPoint(x: (point.x - sourceRect.minX) / sourceRect.width * viewSize.width,
                        y: (point.y - sourceRect.minY) / sourceRect.height * viewSize.height)
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
        .allowsHitTesting(false)
    }
}
