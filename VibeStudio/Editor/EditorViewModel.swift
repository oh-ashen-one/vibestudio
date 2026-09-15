import AVFoundation
import Foundation

/// Loads a project bundle, owns the AVPlayer, and precomputes the raw and
/// smoothed cursor paths in video pixel space for the debug overlay.
@MainActor
final class EditorViewModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var showRawPath = true
    @Published var showSmoothedPath = true
    @Published var videoSize: CGSize = .zero
    @Published var loadError: String?
    @Published var didLoad = false

    let player = AVPlayer()
    private(set) var rawPath: [CursorPoint] = []
    private(set) var smoothedPath: [CursorPoint] = []
    private(set) var clicks: [CursorPoint] = []
    private var timeObserver: Any?

    init(url: URL) {
        Task { await load(url: url) }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(url: URL) async {
        do {
            let bundleURL: URL
            if url.pathExtension == ProjectStore.bundleExtension {
                bundleURL = url
            } else {
                bundleURL = try ProjectStore.importLooseFolder(url, to: nil)
            }
            let project = try ProjectStore.load(bundleURL: bundleURL)

            let projector = EventProjector(meta: project.meta)
            let rawCGPath = CursorSmoother.cursorPath(from: project.events)
            rawPath = rawCGPath.map { point in
                let pixel = projector.videoPoint(forGlobalCGPoint: point.position)
                return CursorPoint(t: point.t, x: Double(pixel.x), y: Double(pixel.y))
            }
            let dt = 1.0 / max(Double(project.meta.frameRate), 1)
            smoothedPath = CursorSmoother.smooth(CursorSmoother.resample(rawPath, interval: dt),
                                                 interval: dt,
                                                 stiffness: SmoothnessPreset.standard.stiffness)
            clicks = project.events.compactMap { event in
                guard event.kind == .click, let pixel = projector.videoPoint(for: event) else { return nil }
                return CursorPoint(t: event.t, x: Double(pixel.x), y: Double(pixel.y))
            }

            let item = AVPlayerItem(url: project.recordingURL)
            player.replaceCurrentItem(with: item)
            let asset = item.asset
            duration = (try? await asset.load(.duration).seconds) ?? 0
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                videoSize = size
            }
            addTimeObserver()
            didLoad = true
            print("[VibeStudio] editor loaded \(bundleURL.lastPathComponent): "
                  + "\(rawPath.count) raw / \(smoothedPath.count) smoothed points, "
                  + "\(clicks.count) clicks, duration \(duration)s")
        } catch {
            loadError = error.localizedDescription
            print("[VibeStudio] editor load failed: \(error.localizedDescription)")
        }
    }

    private func addTimeObserver() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.currentTime = time.seconds
            }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
