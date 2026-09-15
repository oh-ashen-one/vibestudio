import AVFoundation
import Foundation

/// Owns the editor state: playback, cursor paths, zoom keyframe timeline,
/// inspector settings, persistence, and the per-tick render state for the
/// Metal preview.
@MainActor
final class EditorViewModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var showRawPath = false
    @Published var showSmoothedPath = true
    @Published var videoSize: CGSize = .zero
    @Published var loadError: String?
    @Published var didLoad = false
    @Published var hasWebcam = false
    @Published var selectedKeyframeID: UUID?

    @Published var keyframes: [CameraKeyframe] = [] {
        didSet { if !isLoading { schedulePersist() } }
    }
    @Published var settings: EditorSettings = EditorSettings() {
        didSet {
            if !isLoading {
                if settings.smoothnessPreset != oldValue.smoothnessPreset {
                    recomputeSmoothedPath()
                }
                schedulePersist()
            }
        }
    }

    let player = AVPlayer()
    let webcamPlayer = AVPlayer()
    let renderer = PreviewRenderer()

    private(set) var rawPath: [CursorPoint] = []
    private(set) var smoothedPath: [CursorPoint] = []
    private(set) var clicks: [CursorPoint] = []
    private var events: [RecordedEvent] = []
    private var projector: EventProjector?
    private var bundleURL: URL?
    private var timeObserver: Any?
    private var persistWorkItem: DispatchWorkItem?
    private var isLoading = false
    private var recordingFrameRate: Double = 60

    private var frameDT: Double { 1.0 / recordingFrameRate }

    var cameraModel: CameraModel {
        CameraModel(keyframes: keyframes, style: settings.zoomStyle)
    }

    init(url: URL) {
        renderer.frameStateProvider = { [weak self] in
            self?.currentFrameState() ?? PreviewFrameState()
        }
        Task { await load(url: url) }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func load(url: URL) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let bundleURL: URL
            if url.pathExtension == ProjectStore.bundleExtension {
                bundleURL = url
            } else {
                bundleURL = try ProjectStore.importLooseFolder(url, to: nil)
            }
            self.bundleURL = bundleURL
            let project = try ProjectStore.load(bundleURL: bundleURL)
            events = project.events

            let projector = EventProjector(meta: project.meta)
            self.projector = projector
            recordingFrameRate = max(Double(project.meta.frameRate), 1)
            let rawCGPath = CursorSmoother.cursorPath(from: project.events)
            rawPath = rawCGPath.map { point in
                let pixel = projector.videoPoint(forGlobalCGPoint: point.position)
                return CursorPoint(t: point.t, x: Double(pixel.x), y: Double(pixel.y))
            }
            recomputeSmoothedPath()
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
            renderer.screenVideoSize = videoSize

            if let webcamURL = project.webcamURL {
                hasWebcam = true
                webcamPlayer.replaceCurrentItem(with: AVPlayerItem(url: webcamURL))
                webcamPlayer.isMuted = true
                if let track = try? await webcamPlayer.currentItem?.asset.loadTracks(withMediaType: .video).first,
                   let size = try? await track.load(.naturalSize) {
                    renderer.webcamVideoSize = size
                }
            }
            renderer.attachPlayers(screen: player, webcam: hasWebcam ? webcamPlayer : nil)

            if let stored = project.state.keyframes, !stored.isEmpty {
                keyframes = stored
            } else {
                keyframes = AutoZoomEngine.keyframes(from: events,
                                                     projector: projector,
                                                     videoSize: videoSize,
                                                     duration: duration)
            }
            if let stored = project.state.editorSettings {
                settings = stored
                recomputeSmoothedPath()
            }

            addTimeObserver()
            didLoad = true
            print("[VibeStudio] editor loaded \(bundleURL.lastPathComponent): "
                  + "\(rawPath.count) raw / \(smoothedPath.count) smoothed points, "
                  + "\(clicks.count) clicks, \(keyframes.count) keyframes, duration \(duration)s, "
                  + "webcam=\(hasWebcam)")
        } catch {
            loadError = error.localizedDescription
            print("[VibeStudio] editor load failed: \(error.localizedDescription)")
        }
    }

    private func recomputeSmoothedPath() {
        let dt = frameDT
        smoothedPath = CursorSmoother.smooth(CursorSmoother.resample(rawPath, interval: dt),
                                             interval: dt,
                                             stiffness: settings.smoothnessPreset.stiffness)
    }

    // MARK: - Persistence

    private func schedulePersist() {
        guard didLoad else { return }
        persistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistNow() }
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func persistNow() {
        guard let bundleURL else { return }
        do {
            try ProjectStore.save(bundleURL: bundleURL, keyframes: keyframes, editorSettings: settings)
        } catch {
            print("[VibeStudio] persist failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Keyframe editing

    func moveKeyframe(id: UUID, toStart start: Double) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        let length = keyframes[index].tEnd - keyframes[index].tStart
        let clamped = min(max(start, 0), max(duration - length, 0))
        keyframes[index].tStart = clamped
        keyframes[index].tEnd = clamped + length
    }

    func trimKeyframe(id: UUID, edge: ZoomTrackView.TrimEdge, toTime time: Double) {
        guard let index = keyframes.firstIndex(where: { $0.id == id }) else { return }
        switch edge {
        case .start:
            keyframes[index].tStart = min(max(time, 0), keyframes[index].tEnd - 0.2)
        case .end:
            keyframes[index].tEnd = max(min(time, duration), keyframes[index].tStart + 0.2)
        }
    }

    func deleteKeyframe(id: UUID) {
        keyframes.removeAll { $0.id == id }
        if selectedKeyframeID == id { selectedKeyframeID = nil }
    }

    func addManualKeyframe(at t: Double) {
        guard videoSize.width > 0 else { return }
        let zoom = AutoZoomEngine.defaultZoom
        let size = CGSize(width: videoSize.width / zoom, height: videoSize.height / zoom)
        let fallback = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
        let center = AutoZoomEngine.cursorPosition(at: t, in: smoothedPath) ?? fallback
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = min(max(origin.x, 0), videoSize.width - size.width)
        origin.y = min(max(origin.y, 0), videoSize.height - size.height)
        let keyframe = CameraKeyframe(tStart: t,
                                      tEnd: min(t + 2, max(duration, t + 0.2)),
                                      focusRect: CGRect(origin: origin, size: size),
                                      zoom: zoom,
                                      isManual: true)
        keyframes.append(keyframe)
        keyframes.sort { $0.tStart < $1.tStart }
        selectedKeyframeID = keyframe.id
    }

    func regenerateKeyframes() {
        guard let projector else { return }
        keyframes = AutoZoomEngine.keyframes(from: events,
                                             projector: projector,
                                             videoSize: videoSize,
                                             duration: duration)
        selectedKeyframeID = nil
    }

    // MARK: - Render state

    private func currentFrameState() -> PreviewFrameState {
        var state = PreviewFrameState()
        guard didLoad, videoSize.width > 0 else { return state }
        let t = player.currentTime().seconds
        let camera = cameraModel.state(at: t, videoSize: videoSize)
        let src = camera.sourceRect(videoSize: videoSize)
        state.screenUVRect = CGRect(x: src.minX / videoSize.width, y: src.minY / videoSize.height,
                                    width: src.width / videoSize.width, height: src.height / videoSize.height)
        state.layout = settings.cameraLayout

        let shutter = settings.motionBlurStrength / 60.0
        let previous = cameraModel.state(at: max(0, t - frameDT), videoSize: videoSize)
        let cameraVelocity = CGPoint(x: (camera.center.x - previous.center.x) / frameDT,
                                     y: (camera.center.y - previous.center.y) / frameDT)
        if hypot(cameraVelocity.x, cameraVelocity.y) > 1 {
            state.cameraTaps = 1 + Int(settings.motionBlurStrength * Double(PreviewRenderer.maxCameraTaps - 1))
            state.cameraBlurStep = CGSize(width: cameraVelocity.x / videoSize.width * shutter / CGFloat(state.cameraTaps),
                                          height: cameraVelocity.y / videoSize.height * shutter / CGFloat(state.cameraTaps))
        }

        if let position = AutoZoomEngine.cursorPosition(at: t, in: smoothedPath) {
            let fx = (position.x - src.minX) / src.width
            let fy = (position.y - src.minY) / src.height
            state.cursorPosition = CGPoint(x: fx, y: fy)
            state.cursorHeightFraction = 0.045 * settings.cursorSize

            let taps = 1 + Int(settings.motionBlurStrength * 11)
            if taps > 1,
               let previousPosition = AutoZoomEngine.cursorPosition(at: max(0, t - frameDT), in: smoothedPath) {
                let vx = (position.x - previousPosition.x) / frameDT / src.width
                let vy = (position.y - previousPosition.y) / frameDT / src.height
                if hypot(vx, vy) > 0.05 {
                    state.cursorBlurOffsets = (1..<taps).reversed().map { i in
                        CGSize(width: -vx * shutter * Double(i) / Double(taps),
                               height: -vy * shutter * Double(i) / Double(taps))
                    } + [.zero]
                }
            }
        }
        return state
    }

    // MARK: - Playback

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
            webcamPlayer.pause()
        } else {
            webcamPlayer.play()
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        if hasWebcam {
            webcamPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
