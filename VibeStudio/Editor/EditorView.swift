import AVKit
import SwiftUI

// Force a direct symbol reference to AVKit's AVPlayerView so the linker keeps
// the AVKit framework: without it, SwiftUI's VideoPlayer crashes at runtime
// ("failed to demangle superclass of VideoPlayerView from mangled name
// 'So12AVPlayerViewC'") because its ObjC superclass was dead-stripped.
private let _forceAVKitLinkage: AnyClass = AVPlayerView.self

struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel
    @State private var showExportPanel = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                previewArea
                    .layoutPriority(1)
                transportBar
                    .padding(10)
                TrimRangeView(viewModel: viewModel)
                    .frame(height: 18)
                    .padding(.horizontal, 10)
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
        .sheet(isPresented: $showExportPanel) {
            ExportPanelView(viewModel: viewModel)
        }
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
        // The Metal composer draws the ENTIRE canvas (background, padding,
        // rounded corners, shadow, video, webcam, cursor) — identical to
        // export. SwiftUI only hosts the view and the debug overlay.
        let aspect = viewModel.videoSize.height > 0
            ? viewModel.videoSize.width / viewModel.videoSize.height : 16.0 / 9.0
        return Group {
            if viewModel.renderer.isReady {
                PreviewMetalView(renderer: viewModel.renderer)
                    .overlay {
                        GeometryReader { geometry in
                            let pad = geometry.size.width * viewModel.settings.padding
                            let quad = CGRect(origin: .zero, size: geometry.size).insetBy(dx: pad, dy: pad)
                            let src = viewModel.cameraModel.state(
                                at: viewModel.currentTime,
                                videoSize: viewModel.videoSize
                            ).sourceRect(videoSize: viewModel.videoSize)
                            CursorOverlayView(quadRect: quad,
                                              currentTime: viewModel.currentTime,
                                              sourceRect: src,
                                              rawPath: viewModel.rawPath,
                                              smoothedPath: viewModel.smoothedPath,
                                              clicks: viewModel.clicks,
                                              showRaw: viewModel.showRawPath,
                                              showSmoothed: viewModel.showSmoothedPath)
                            ManualZoomEditOverlay(viewModel: viewModel,
                                                  quadRect: quad,
                                                  sourceRect: src)
                        }
                    }
            } else {
                VideoPlayer(player: viewModel.player)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipped()
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
                   in: 0...max(viewModel.timelineEnd, 0.01))

            Text(EditorViewModel.timeString(viewModel.duration))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            Divider().frame(height: 16)

            Toggle("Raw path", isOn: $viewModel.showRawPath)
                .toggleStyle(.checkbox)
            Toggle("Smoothed path", isOn: $viewModel.showSmoothedPath)
                .toggleStyle(.checkbox)

            Divider().frame(height: 16)

            Button {
                showExportPanel = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
            .help("Export")
        }
        .foregroundStyle(.white)
    }
}

/// Debug overlay: raw cursor path (thin red), smoothed path (thick green),
/// click dots — drawn up to the playhead, mapped through the current camera
/// source rect onto the video quad inside the canvas.
struct CursorOverlayView: View {
    let quadRect: CGRect
    let currentTime: Double
    let sourceRect: CGRect
    let rawPath: [CursorPoint]
    let smoothedPath: [CursorPoint]
    let clicks: [CursorPoint]
    let showRaw: Bool
    let showSmoothed: Bool

    var body: some View {
        Canvas { context, _ in
            guard sourceRect.width > 0, sourceRect.height > 0, quadRect.width > 0 else { return }

            func viewPoint(_ point: CursorPoint) -> CGPoint {
                CGPoint(x: quadRect.minX + (point.x - sourceRect.minX) / sourceRect.width * quadRect.width,
                        y: quadRect.minY + (point.y - sourceRect.minY) / sourceRect.height * quadRect.height)
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
