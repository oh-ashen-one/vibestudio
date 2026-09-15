import CoreGraphics
import Foundation

/// Click ripple envelope (§Phase 5): quick expanding ring fading out.
enum ClickRipple {
    static let lifetime: Double = 0.5
    /// Ring radius grows from this to 1.0 (fraction of the ripple quad).
    static let startRadius = 0.15
    static let peakAlpha = 0.85

    /// progress 0...1 and alpha for a ripple `age` seconds old; nil when dead.
    static func state(age: Double) -> (progress: Double, alpha: Double)? {
        guard age >= 0, age <= lifetime else { return nil }
        let progress = age / lifetime
        // ease-out expansion, quadratic fade
        let eased = 1 - (1 - progress) * (1 - progress)
        let alpha = (1 - progress) * (1 - progress) * peakAlpha
        return (eased, alpha)
    }
}

/// Keystroke badge lifecycle: visible briefly, up to 3 stacked.
enum KeystrokeBadges {
    static let visibility: Double = 1.5
    static let fadeIn: Double = 0.1
    static let fadeOut: Double = 0.3
    static let maxVisible = 3

    struct ActiveBadge: Equatable {
        var text: String
        var alpha: Double
    }

    static func active(at t: Double, events: [(t: Double, text: String)]) -> [ActiveBadge] {
        events
            .filter { t >= $0.t && t - $0.t <= visibility }
            .suffix(maxVisible)
            .map { event in
                let age = t - event.t
                let fadeInAlpha = min(age / fadeIn, 1)
                let fadeOutAlpha = age > visibility - fadeOut
                    ? max((visibility - age) / fadeOut, 0) : 1
                return ActiveBadge(text: event.text, alpha: fadeInAlpha * fadeOutAlpha)
            }
    }

    /// ["cmd","shift"] + "z" -> "⇧⌘Z" (standard ⌃⌥⇧⌘ ordering regardless of
    /// the input array order).
    static func badgeText(modifiers: [String]?, key: String?) -> String? {
        guard let key, !key.isEmpty, key != "\0" else { return nil }
        let set = Set(modifiers ?? [])
        var text = ""
        if set.contains("control") { text += "⌃" }
        if set.contains("option") { text += "⌥" }
        if set.contains("shift") { text += "⇧" }
        if set.contains("cmd") { text += "⌘" }
        let named: String
        switch key {
        case " ": named = "Space"
        case "\r", "\n": named = "↩"
        case "\t": named = "⇥"
        default: named = key.count == 1 ? key.uppercased() : key.capitalized
        }
        return text + named
    }
}

/// Hide-static-cursor: fade the cursor out when it has stayed within a small
/// radius for longer than the dwell time, fading over `fade` seconds.
enum CursorVisibility {
    static let thresholdPx: Double = 4
    static let dwell: Double = 1.0
    static let fade: Double = 0.3

    static func alpha(at t: Double,
                      path: [CursorPoint],
                      thresholdPx: Double = thresholdPx,
                      dwell: Double = dwell,
                      fade: Double = fade) -> Double {
        guard let last = path.last, path.count > 1, t >= path[0].t else { return 1 }
        // Index of the sample at or before t (path is a uniform grid).
        var lo = 0
        var hi = path.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if path[mid].t <= t { lo = mid } else { hi = mid }
        }
        let anchor = path[lo]
        // Walk back while points stay within the threshold of the anchor.
        var dwellStart = anchor.t
        var index = lo
        while index > 0 {
            let point = path[index - 1]
            let dx = point.x - anchor.x
            let dy = point.y - anchor.y
            if dx * dx + dy * dy > thresholdPx * thresholdPx { break }
            dwellStart = point.t
            index -= 1
        }
        _ = last
        let dwellTime = t - dwellStart
        guard dwellTime > dwell else { return 1 }
        return max(1 - (dwellTime - dwell) / fade, 0)
    }
}

/// Loop cursor end: synthetic post-segment returning the cursor to its start
/// position and the camera to full frame for seamless loops.
enum LoopCursorEnd {
    static let loopSeconds: Double = 1.5

    /// Loop progress 0...1 for t past the recording duration; nil otherwise.
    static func progress(at t: Double, duration: Double) -> Double? {
        guard t > duration, duration > 0 else { return nil }
        return min((t - duration) / loopSeconds, 1)
    }

    static func eased(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)   // smoothstep
    }
}
