import AVFoundation
import Foundation

/// Everything derived from a project bundle that both the editor and the
/// exporter need: events, paths, resolved keyframes/settings, media facts.
/// One loader, so preview and export see identical inputs.
struct ProjectAnalysis {
    var bundleURL: URL
    var project: LoadedProject
    var projector: EventProjector
    var rawPath: [CursorPoint]      // video pixel space
    var clicks: [CursorPoint]       // video pixel space
    var videoSize: CGSize
    var frameRate: Double
    var duration: Double
    var webcamURL: URL?

    var resolvedKeyframes: [CameraKeyframe] {
        if let stored = project.state.keyframes, !stored.isEmpty { return stored }
        return AutoZoomEngine.keyframes(from: project.events,
                                        projector: projector,
                                        videoSize: videoSize,
                                        duration: duration)
    }

    var resolvedSettings: EditorSettings {
        project.state.editorSettings ?? EditorSettings()
    }

    func smoothedPath(preset: SmoothnessPreset) -> [CursorPoint] {
        let dt = 1.0 / max(frameRate, 1)
        return CursorSmoother.smooth(CursorSmoother.resample(rawPath, interval: dt),
                                     interval: dt,
                                     stiffness: preset.stiffness)
    }

    static func load(bundleURL: URL) async throws -> ProjectAnalysis {
        let project = try ProjectStore.load(bundleURL: bundleURL)
        let projector = EventProjector(meta: project.meta)
        let rawPath = CursorSmoother.cursorPath(from: project.events).map { point in
            let pixel = projector.videoPoint(forGlobalCGPoint: point.position)
            return CursorPoint(t: point.t, x: Double(pixel.x), y: Double(pixel.y))
        }
        let clicks: [CursorPoint] = project.events.compactMap { event -> CursorPoint? in
            guard event.kind == .click, let pixel = projector.videoPoint(for: event) else { return nil }
            return CursorPoint(t: event.t, x: Double(pixel.x), y: Double(pixel.y))
        }

        let asset = AVAsset(url: project.recordingURL)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        var videoSize = project.meta.outputPixelSize
        let videoTracks = try? await asset.loadTracks(withMediaType: .video)
        if let track = videoTracks?.first,
           let size = try? await track.load(.naturalSize), size.width > 0 {
            videoSize = size
        }
        return ProjectAnalysis(bundleURL: bundleURL,
                               project: project,
                               projector: projector,
                               rawPath: rawPath,
                               clicks: clicks,
                               videoSize: videoSize,
                               frameRate: max(Double(project.meta.frameRate), 1),
                               duration: duration,
                               webcamURL: project.webcamURL)
    }
}

/// Builds CompositorFrameState — the ONLY place frame state is computed.
/// Preview calls it with the player time; export calls it per output frame.
enum FrameStateBuilder {
    static func make(t: Double,
                     cameraModel: CameraModel,
                     smoothedPath: [CursorPoint],
                     videoSize: CGSize,
                     settings: EditorSettings,
                     frameDT: Double,
                     sourceAspect: CGFloat? = nil) -> CompositorFrameState {
        var state = CompositorFrameState()
        guard videoSize.width > 0 else { return state }
        let camera = cameraModel.state(at: t, videoSize: videoSize)
        let src = camera.sourceRect(videoSize: videoSize, aspect: sourceAspect)
        state.screenUVRect = CGRect(x: src.minX / videoSize.width, y: src.minY / videoSize.height,
                                    width: src.width / videoSize.width, height: src.height / videoSize.height)
        state.layout = settings.cameraLayout
        state.paddingFraction = settings.padding
        state.cornerRadiusFraction = settings.cornerRadius
        state.shadowEnabled = settings.shadowEnabled
        state.background = settings.background

        let shutter = settings.motionBlurStrength / 60.0
        let previous = cameraModel.state(at: max(0, t - frameDT), videoSize: videoSize)
        let cameraVelocity = CGPoint(x: (camera.center.x - previous.center.x) / frameDT,
                                     y: (camera.center.y - previous.center.y) / frameDT)
        if hypot(cameraVelocity.x, cameraVelocity.y) > 1 {
            state.cameraTaps = 1 + Int(settings.motionBlurStrength * Double(FrameComposer.maxCameraTaps - 1))
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
}
