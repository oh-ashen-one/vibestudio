import Foundation

/// Synchronous smoke check for headless/SSH sessions where SwiftUI never
/// renders: `VibeStudio -open <bundle-or-loose-folder> -smokeTest` imports (if
/// needed), loads the bundle, computes cursor paths, prints, and exits.
enum DevSmokeTest {
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
            fflush(nil)
            return 0
        } catch {
            print("[smoke] failed: \(error.localizedDescription)")
            fflush(nil)
            return 1
        }
    }
}
