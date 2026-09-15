import AppKit
import AVFoundation
import Foundation

/// Owns the editor state: playback, cursor paths, zoom keyframe timeline,
/// inspector settings, persistence, and the per-tick render state for the
/// Metal preview. All derived project data comes from ProjectAnalysis and all
/// frame state from FrameStateBuilder — the same code the exporter uses.
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
    @Published var exportProgress: Double?
    @Published var exportError: String?
    @Published var presets: [SettingsPreset] = []
    @Published var presetError: String?

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
    private(set) var keyBadges: [(t: Double, text: String)] = []
    private var analysis: ProjectAnalysis?
    private var bundleURL: URL?
    private var timeObserver: Any?
    private var persistWorkItem: DispatchWorkItem?
    private var exportCancel: CancelToken?
    private var isLoading = false

    private var frameDT: Double { 1.0 / max(analysis?.frameRate ?? 60, 1) }

    var cameraModel: CameraModel {
        CameraModel(keyframes: keyframes, style: settings.zoomStyle)
    }

    var exportRange: ClosedRange<Double> {
        let start = min(max(settings.trimStart ?? 0, 0), duration)
        let end = min(max(settings.trimEnd ?? timelineEnd, start), timelineEnd)
        return start...max(end, start + 0.1)
    }

    /// Scrubber upper bound: recording duration plus the loop segment when on.
    var timelineEnd: Double {
        duration + (settings.loopCursorEnd == true ? LoopCursorEnd.loopSeconds : 0)
    }

    init(url: URL) {
        renderer.frameStateProvider = { [weak self] in
            self?.currentFrameState() ?? CompositorFrameState()
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
            let analysis = try await ProjectAnalysis.load(bundleURL: bundleURL)
            self.analysis = analysis
            rawPath = analysis.rawPath
            clicks = analysis.clicks
            keyBadges = analysis.project.events.compactMap { event in
                guard event.kind == .key else { return nil }
                return KeystrokeBadges.badgeText(modifiers: event.modifiers, key: event.key)
                    .map { (event.t, $0) }
            }
            duration = analysis.duration
            videoSize = analysis.videoSize
            renderer.screenVideoSize = analysis.videoSize

            player.replaceCurrentItem(with: AVPlayerItem(url: analysis.project.recordingURL))
            if let webcamURL = analysis.webcamURL {
                hasWebcam = true
                webcamPlayer.replaceCurrentItem(with: AVPlayerItem(url: webcamURL))
                webcamPlayer.isMuted = true
                if let item = webcamPlayer.currentItem,
                   let tracks = try? await item.asset.loadTracks(withMediaType: .video),
                   let size = try? await tracks.first?.load(.naturalSize) {
                    renderer.webcamVideoSize = size
                }
            }
            renderer.attachPlayers(screen: player, webcam: hasWebcam ? webcamPlayer : nil)

            keyframes = analysis.resolvedKeyframes
            settings = analysis.resolvedSettings
            recomputeSmoothedPath()

            addTimeObserver()
            refreshPresets()
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
        smoothedPath = analysis?.smoothedPath(preset: settings.smoothnessPreset) ?? []
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
        guard let analysis else { return }
        keyframes = AutoZoomEngine.keyframes(from: analysis.project.events,
                                             projector: analysis.projector,
                                             videoSize: analysis.videoSize,
                                             duration: analysis.duration)
        selectedKeyframeID = nil
    }

    // MARK: - Presets

    func refreshPresets() {
        presets = (try? PresetStore.list(in: PresetStore.defaultDirectory())) ?? []
    }

    func savePreset(name: String) {
        let preset = SettingsPreset(name: name, settings: settings, createdAt: Date())
        do {
            try PresetStore.save(preset, in: PresetStore.defaultDirectory())
            presetError = nil
            refreshPresets()
        } catch {
            presetError = error.localizedDescription
        }
    }

    func applyPreset(_ preset: SettingsPreset) {
        settings = preset.settings
    }

    func copyPresetJSON() {
        guard let json = try? PresetStore.json(for: settings) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    func importPresetJSON() {
        guard let string = NSPasteboard.general.string(forType: .string),
              let imported = PresetStore.settings(fromJSON: string) else {
            presetError = "Clipboard does not contain preset JSON."
            return
        }
        presetError = nil
        settings = imported
    }

    // MARK: - Export

    func startExport(preset: ExportPreset, aspect: ExportAspect, format: ExportFormat = .mp4, outputURL: URL) {
        guard let bundleURL, exportProgress == nil else { return }
        let cancel = CancelToken()
        exportCancel = cancel
        exportProgress = 0
        exportError = nil
        let config = ExportConfiguration(bundleURL: bundleURL,
                                         outputURL: outputURL,
                                         preset: preset,
                                         aspect: aspect,
                                         format: format,
                                         trimRange: exportRange)
        Task.detached { [self] in
            do {
                let result = try await ExportRenderer.run(configuration: config,
                                                          progress: { fraction in
                    Task { @MainActor in self.exportProgress = fraction }
                }, cancel: cancel)
                await MainActor.run {
                    self.exportProgress = nil
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
            } catch {
                await MainActor.run {
                    self.exportProgress = nil
                    if (error as? ExportError) != .cancelled {
                        self.exportError = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelExport() {
        exportCancel?.cancel()
        exportCancel = nil
    }

    // MARK: - Render state

    private func currentFrameState() -> CompositorFrameState {
        guard didLoad, let analysis else { return CompositorFrameState() }
        // Loop-end preview: when the slider is dragged past the recording end
        // with loop enabled, render the synthetic loop segment.
        let playerT = player.currentTime().seconds
        let t = settings.loopCursorEnd == true && currentTime > duration && playerT >= duration - 0.05
            ? currentTime : playerT
        return FrameStateBuilder.make(t: t,
                                      cameraModel: cameraModel,
                                      smoothedPath: smoothedPath,
                                      videoSize: analysis.videoSize,
                                      settings: settings,
                                      frameDT: frameDT,
                                      clicks: clicks,
                                      keyBadges: keyBadges,
                                      duration: duration)
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
