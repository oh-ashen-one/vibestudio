import CoreGraphics
import Foundation

/// First-class editable zoom object on the timeline (spec §3.3.6).
/// focusRect is in video pixel space so Phase 4 can re-target aspect ratios.
struct CameraKeyframe: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var tStart: Double
    var tEnd: Double
    var focusRect: CGRect
    var zoom: Double
    var isManual: Bool = false

    var center: CGPoint { CGPoint(x: focusRect.midX, y: focusRect.midY) }
}

enum ZoomStyle: String, Codable, CaseIterable {
    case focused
    case smooth
}

/// §3.3 auto-zoom keyframe generation. Pure and deterministic: same events in,
/// same keyframes out. Weak activities (keys/scrolls) use the cursor position
/// at their timestamp.
enum AutoZoomEngine {
    /// Activities closer in time than this merge into one cluster.
    static let mergeWindow: Double = 1.5
    /// Activities farther than this from the cluster center start a new cluster.
    static let spatialRadiusFactor: Double = 0.25 // of video width
    /// Zoom-in begins this long before the cluster's first click.
    static let anticipation: Double = 0.3
    /// Inactivity after a cluster before the camera zooms back out.
    static let zoomOutDelay: Double = 1.0
    /// Default zoom target for a cluster.
    static let defaultZoom: Double = 2.0
    static let minZoom: Double = 1.5
    /// The zoom window never shows less than this fraction of screen width.
    static let minVisibleWidthFactor: Double = 0.35
    /// A cluster whose spread covers more than this fraction of the screen in
    /// either axis is treated as full-screen activity (camera stays at 1x).
    static let fullScreenFactor: Double = 0.6
    /// Centers closer than this (and similar zoom) pan instead of zooming out.
    static let panRadiusFactor: Double = 0.4 // of video width
    /// Strength threshold: clusters with no click and only sparse weak
    /// activity are ignored.
    static let minClusterActivities: Int = 2

    struct Activity: Equatable {
        var t: Double
        var point: CGPoint
        var isClick: Bool
    }

    struct Cluster {
        var activities: [Activity]
        var start: Double { activities.first?.t ?? 0 }
        var end: Double { activities.last?.t ?? 0 }
        var hasClick: Bool { activities.contains { $0.isClick } }
        var boundingBox: CGRect {
            var box = CGRect.null
            for activity in activities {
                box = box.union(CGRect(origin: activity.point, size: .zero))
            }
            return box
        }
        var center: CGPoint {
            let box = boundingBox
            return CGPoint(x: box.midX, y: box.midY)
        }
    }

    /// Extracts activities from the event stream in video pixel space.
    static func activities(from events: [RecordedEvent], projector: EventProjector) -> [Activity] {
        let cursorPath = CursorSmoother.cursorPath(from: events)
        var result: [Activity] = []
        for event in events {
            switch event.kind {
            case .click:
                if let pixel = projector.videoPoint(for: event) {
                    result.append(Activity(t: event.t, point: pixel, isClick: true))
                }
            case .key, .scroll:
                if let position = cursorPosition(at: event.t, in: cursorPath) {
                    let pixel = projector.videoPoint(forGlobalCGPoint: position)
                    result.append(Activity(t: event.t, point: pixel, isClick: false))
                }
            default:
                break
            }
        }
        return result.sorted { $0.t < $1.t }
    }

    static func cursorPosition(at t: Double, in path: [CursorPoint]) -> CGPoint? {
        guard let first = path.first, let last = path.last else { return nil }
        if t <= first.t { return first.position }
        if t >= last.t { return last.position }
        var lo = 0
        var hi = path.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if path[mid].t <= t { lo = mid } else { hi = mid }
        }
        let a = path[lo]
        let b = path[hi]
        let span = b.t - a.t
        let f = span > 0 ? (t - a.t) / span : 0
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Groups activities: a new activity joins the current cluster when it is
    /// within mergeWindow of the cluster's last activity AND within the
    /// spatial radius of that last activity (so a trail of activity can grow
    /// the cluster and "spans the full screen" stays reachable).
    static func cluster(_ activities: [Activity], videoSize: CGSize) -> [Cluster] {
        let radius = videoSize.width * spatialRadiusFactor
        var clusters: [Cluster] = []
        for activity in activities {
            if var current = clusters.last,
               let lastActivity = current.activities.last,
               activity.t - lastActivity.t <= mergeWindow,
               hypot(activity.point.x - lastActivity.point.x,
                     activity.point.y - lastActivity.point.y) <= radius {
                current.activities.append(activity)
                clusters[clusters.count - 1] = current
            } else {
                clusters.append(Cluster(activities: [activity]))
            }
        }
        return clusters.filter { $0.hasClick || $0.activities.count >= minClusterActivities }
    }

    /// Focus rect for a cluster: centered on the activity bounding box, sized
    /// videoSize/zoom, clamped inside the video bounds.
    static func focusRect(for cluster: Cluster, videoSize: CGSize) -> (rect: CGRect, zoom: Double) {
        let box = cluster.boundingBox
        let maxZoom = 1.0 / minVisibleWidthFactor
        let isFullScreen = box.width > videoSize.width * fullScreenFactor
            || box.height > videoSize.height * fullScreenFactor
        if isFullScreen {
            return (CGRect(origin: .zero, size: videoSize), 1.0)
        }
        let zoom = min(max(defaultZoom, minZoom), maxZoom)
        let size = CGSize(width: videoSize.width / zoom, height: videoSize.height / zoom)
        var origin = CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2)
        origin.x = min(max(origin.x, 0), videoSize.width - size.width)
        origin.y = min(max(origin.y, 0), videoSize.height - size.height)
        return (CGRect(origin: origin, size: size), zoom)
    }

    /// Emits the keyframe timeline: zoomed hold segments plus zoom-out (1x)
    /// segments where the camera should return to the full frame. Transitions
    /// happen in the gaps between segments.
    static func keyframes(from events: [RecordedEvent],
                          projector: EventProjector,
                          videoSize: CGSize,
                          duration: Double) -> [CameraKeyframe] {
        let clusters = cluster(activities(from: events, projector: projector), videoSize: videoSize)
        guard !clusters.isEmpty else { return [] }

        var segments: [CameraKeyframe] = []
        let fullFrame = CGRect(origin: .zero, size: videoSize)
        let panRadius = videoSize.width * panRadiusFactor

        func appendZoomOut(from start: Double, to end: Double) {
            guard end > start else { return }
            segments.append(CameraKeyframe(tStart: start, tEnd: end, focusRect: fullFrame, zoom: 1.0))
        }

        for cluster in clusters {
            let (rect, zoom) = focusRect(for: cluster, videoSize: videoSize)
            let zoomInT = max(0, cluster.start - anticipation)
            let holdEnd = max(cluster.end, zoomInT + 0.1)

            if let previous = segments.last {
                let distance = hypot(cluster.center.x - previous.center.x,
                                     cluster.center.y - previous.center.y)
                let pans = zoom > 1 && previous.zoom > 1
                    && distance <= panRadius
                    && abs(zoom - previous.zoom) < 0.5
                if !pans {
                    let outStart = previous.tEnd + zoomOutDelay
                    if zoom > 1, outStart < zoomInT {
                        appendZoomOut(from: outStart, to: zoomInT)
                    }
                }
            }
            segments.append(CameraKeyframe(tStart: zoomInT, tEnd: holdEnd, focusRect: rect, zoom: zoom))
        }

        if let last = segments.last, duration > last.tEnd + zoomOutDelay, last.zoom > 1 {
            appendZoomOut(from: last.tEnd + zoomOutDelay, to: duration)
        }
        return segments
    }
}
