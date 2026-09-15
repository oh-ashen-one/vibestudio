import CoreGraphics
import Foundation

struct CursorPoint: Equatable {
    var t: Double
    var x: Double
    var y: Double

    var position: CGPoint { CGPoint(x: x, y: y) }
}

enum SmoothnessPreset: String, Codable, CaseIterable {
    case rapid
    case quick
    case standard
    case slow

    /// Spring stiffness k; damping is always critical (c = 2√k).
    var stiffness: Double {
        switch self {
        case .rapid: return 500
        case .quick: return 250
        case .standard: return 120
        case .slow: return 60
        }
    }
}

/// §3.2 cursor smoothing: extract the raw path from events, resample onto a
/// uniform frame grid with micro-jitter suppression, then run a
/// critically-damped spring per axis. Pure functions — unit-tested headlessly.
enum CursorSmoother {
    /// Sub-2px deltas within a dwell are suppressed (spec §3.2).
    static let jitterThreshold: Double = 2.0

    static func cursorPath(from events: [RecordedEvent]) -> [CursorPoint] {
        events.compactMap { event in
            guard event.kind == .cursorMove, let x = event.x, let y = event.y else { return nil }
            return CursorPoint(t: event.t, x: x, y: y)
        }.sorted { $0.t < $1.t }
    }

    /// Uniform resampling via linear interpolation. Output stays pinned to the
    /// last accepted anchor until the raw path moves more than the jitter
    /// threshold away from it, so slow drifts still accumulate and pass
    /// through once they exceed the threshold.
    static func resample(_ points: [CursorPoint], interval dt: Double) -> [CursorPoint] {
        guard let first = points.first, let last = points.last,
              points.count > 1, dt > 0, last.t > first.t else { return points }
        var output: [CursorPoint] = []
        var segment = 0
        var anchor = first
        var t = first.t
        while t <= last.t + 1e-9 {
            let sampleTime = min(t, last.t)
            while segment + 1 < points.count - 1 && points[segment + 1].t < sampleTime {
                segment += 1
            }
            let a = points[segment]
            let b = points[min(segment + 1, points.count - 1)]
            let span = b.t - a.t
            let fraction = span > 0 ? (sampleTime - a.t) / span : 0
            let candidate = CursorPoint(t: sampleTime,
                                        x: a.x + (b.x - a.x) * fraction,
                                        y: a.y + (b.y - a.y) * fraction)
            let dx = candidate.x - anchor.x
            let dy = candidate.y - anchor.y
            if output.isEmpty || dx * dx + dy * dy >= jitterThreshold * jitterThreshold {
                anchor = candidate
            }
            output.append(CursorPoint(t: sampleTime, x: anchor.x, y: anchor.y))
            t += dt
        }
        return output
    }

    /// Critically-damped spring per axis: p'' = -k(p - target) - 2√k·p',
    /// integrated with semi-implicit Euler on the resample grid.
    static func smooth(_ points: [CursorPoint], interval dt: Double, stiffness k: Double) -> [CursorPoint] {
        guard let first = points.first else { return [] }
        let damping = 2 * k.squareRoot()
        var px = first.x
        var py = first.y
        var vx = 0.0
        var vy = 0.0
        var output: [CursorPoint] = [first]
        for target in points.dropFirst() {
            vx += (-k * (px - target.x) - damping * vx) * dt
            vy += (-k * (py - target.y) - damping * vy) * dt
            px += vx * dt
            py += vy * dt
            output.append(CursorPoint(t: target.t, x: px, y: py))
        }
        return output
    }

    static func smoothedPath(from events: [RecordedEvent],
                             frameRate: Double,
                             preset: SmoothnessPreset = .standard) -> [CursorPoint] {
        let dt = 1.0 / max(frameRate, 1)
        return smooth(resample(cursorPath(from: events), interval: dt),
                      interval: dt,
                      stiffness: preset.stiffness)
    }
}
