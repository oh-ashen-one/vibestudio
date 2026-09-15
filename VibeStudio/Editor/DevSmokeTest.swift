import Foundation

/// Synchronous smoke check for headless/SSH sessions where SwiftUI never
/// renders: `VibeStudio -open <bundle-or-loose-folder> -smokeTest` imports (if
/// needed), loads the bundle, computes cursor paths, prints, and exits.
enum DevSmokeTest {
    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func run(url: URL) -> Int32 {
        do {
            let bundleURL = url.pathExtension == ProjectStore.bundleExtension
                ? url
                : try ProjectStore.importLooseFolder(url, to: nil)
            let project = try ProjectStore.load(bundleURL: bundleURL)
            let projector = EventProjector(meta: project.meta)
            let raw = CursorSmoother.cursorPath(from: project.events)
            let smoothed = CursorSmoother.smoothedPath(from: project.events,
                                                       frameRate: Double(project.meta.frameRate))
            let clicks = project.events.filter { $0.kind == .click }
            print("[smoke] bundle=\(bundleURL.lastPathComponent)")
            print("[smoke] events=\(project.events.count) raw=\(raw.count) smoothed=\(smoothed.count) clicks=\(clicks.count)")
            print("[smoke] video=\(Int(project.meta.outputPixelSize.width))x\(Int(project.meta.outputPixelSize.height)) scale=\(project.meta.scaleFactor)")
            if let first = clicks.first, let pixel = projector.videoPoint(for: first) {
                print("[smoke] firstClick t=\(first.t) -> pixel (\(Int(pixel.x)), \(Int(pixel.y)))")
            }

            // Phase 3: exercise auto-zoom generation + camera evaluation.
            let videoSize = project.meta.outputPixelSize
            let duration = project.events.map(\.t).max() ?? 0
            let keyframes = AutoZoomEngine.keyframes(from: project.events,
                                                     projector: projector,
                                                     videoSize: videoSize,
                                                     duration: duration)
            print("[smoke] keyframes=\(keyframes.count)")
            for keyframe in keyframes.prefix(8) {
                let rect = keyframe.focusRect
                print("[smoke]   kf [\(fmt(keyframe.tStart))-\(fmt(keyframe.tEnd))] "
                      + "zoom=\(fmt(keyframe.zoom)) focus=(\(Int(rect.minX)),\(Int(rect.minY)) "
                      + "\(Int(rect.width))x\(Int(rect.height)))"
                      + "\(keyframe.isManual ? " manual" : "")")
            }
            let model = CameraModel(keyframes: keyframes, style: .focused)
            for probe in [0.0, 1.7, 2.0, 4.7, 10.0, 20.0] {
                let state = model.state(at: probe, videoSize: videoSize)
                print("[smoke]   camera t=\(fmt(probe)) center=(\(Int(state.center.x)),\(Int(state.center.y))) zoom=\(fmt(state.zoom))")
            }
            fflush(nil)
            return 0
        } catch {
            print("[smoke] failed: \(error.localizedDescription)")
            fflush(nil)
            return 1
        }
    }
}
