import CoreGraphics
import Foundation

/// Camera state at a point in time: center of the visible window in video
/// pixel space plus the zoom factor.
struct CameraState: Equatable {
    var center: CGPoint
    var zoom: Double

    /// Source rect in video pixels currently visible, clamped to the video.
    func sourceRect(videoSize: CGSize) -> CGRect {
        let size = CGSize(width: videoSize.width / max(zoom, 0.01),
                          height: videoSize.height / max(zoom, 0.01))
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        origin.x = min(max(origin.x, 0), max(videoSize.width - size.width, 0))
        origin.y = min(max(origin.y, 0), max(videoSize.height - size.height, 0))
        return CGRect(origin: origin, size: size)
    }
}

/// Normalized spring easing used for camera transitions (§3.3.5).
/// Critically-damped response s(t) = 1 - (1 + ωt)·e^(−ωt), normalized so
/// evaluate(0) = 0 and evaluate(duration) = 1 exactly — no discontinuity when
/// entering the next hold segment. Focused settles fast, Smooth is fluid.
struct SpringCurve: Equatable {
    var omega: Double

    static let focused = SpringCurve(omega: 12)
    static let smooth = SpringCurve(omega: 5)

    static func curve(for style: ZoomStyle) -> SpringCurve {
        switch style {
        case .focused: return .focused
        case .smooth: return .smooth
        }
    }

    func evaluate(elapsed: Double, duration: Double) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(max(elapsed, 0), duration)
        let denom = 1 - (1 + omega * duration) * exp(-omega * duration)
        guard denom > 1e-6 else { return t / duration }
        return (1 - (1 + omega * t) * exp(-omega * t)) / denom
    }
}

/// Evaluates the camera over a sorted keyframe timeline: holds inside
/// segments, spring-eased interpolation in the gaps. Zoom interpolates in log
/// space so multiplicative zoom feels uniform.
struct CameraModel: Equatable {
    var keyframes: [CameraKeyframe]
    var style: ZoomStyle

    private var sorted: [CameraKeyframe] {
        keyframes.sorted { $0.tStart < $1.tStart }
    }

    func state(at t: Double, videoSize: CGSize) -> CameraState {
        let full = CameraState(center: CGPoint(x: videoSize.width / 2, y: videoSize.height / 2), zoom: 1)
        let segments = sorted
        guard let first = segments.first else { return full }
        if t <= first.tStart {
            return t < first.tStart && first.zoom > 1
                ? transition(from: full, to: Self.state(of: first), t0: 0, t1: first.tStart, t: t)
                : Self.state(of: first)
        }
        for (index, segment) in segments.enumerated() {
            if t <= segment.tEnd {
                return Self.state(of: segment)
            }
            let next = segments.indices.contains(index + 1) ? segments[index + 1] : nil
            if let next, t < next.tStart {
                return transition(from: Self.state(of: segment), to: Self.state(of: next),
                                  t0: segment.tEnd, t1: next.tStart, t: t)
            }
        }
        return Self.state(of: segments[segments.count - 1])
    }

    static func state(of keyframe: CameraKeyframe) -> CameraState {
        CameraState(center: keyframe.center, zoom: keyframe.zoom)
    }

    private func transition(from: CameraState, to: CameraState, t0: Double, t1: Double, t: Double) -> CameraState {
        let progress = SpringCurve.curve(for: style).evaluate(elapsed: t - t0, duration: t1 - t0)
        let center = CGPoint(x: from.center.x + (to.center.x - from.center.x) * progress,
                             y: from.center.y + (to.center.y - from.center.y) * progress)
        let logFrom = log(max(from.zoom, 0.01))
        let logTo = log(max(to.zoom, 0.01))
        return CameraState(center: center, zoom: exp(logFrom + (logTo - logFrom) * progress))
    }
}
