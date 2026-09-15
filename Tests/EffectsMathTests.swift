import XCTest
@testable import VibeStudio

final class EffectsMathTests: XCTestCase {
    // MARK: - Click ripples

    func testRippleLifecycle() {
        XCTAssertNil(ClickRipple.state(age: -0.01))
        XCTAssertNil(ClickRipple.state(age: ClickRipple.lifetime + 0.01))
        let birth = ClickRipple.state(age: 0)!
        XCTAssertEqual(birth.progress, 0, accuracy: 1e-9)
        XCTAssertEqual(birth.alpha, ClickRipple.peakAlpha, accuracy: 1e-9)
        let end = ClickRipple.state(age: ClickRipple.lifetime)!
        XCTAssertEqual(end.alpha, 0, accuracy: 1e-9)
        XCTAssertEqual(end.progress, 1, accuracy: 1e-9)
    }

    func testRippleExpandsMonotonicallyAndFades() {
        var previousProgress = -1.0
        var previousAlpha = Double.greatestFiniteMagnitude
        var age = 0.0
        while age <= ClickRipple.lifetime {
            let state = ClickRipple.state(age: age)!
            XCTAssertGreaterThanOrEqual(state.progress, previousProgress)
            XCTAssertLessThanOrEqual(state.alpha, previousAlpha + 1e-9)
            previousProgress = state.progress
            previousAlpha = state.alpha
            age += 0.02
        }
    }

    // MARK: - Keystroke badges

    func testBadgeTextFormatting() {
        XCTAssertEqual(KeystrokeBadges.badgeText(modifiers: ["cmd"], key: "c"), "⌘C")
        XCTAssertEqual(KeystrokeBadges.badgeText(modifiers: ["cmd", "shift"], key: "z"), "⇧⌘Z")
        XCTAssertEqual(KeystrokeBadges.badgeText(modifiers: ["control", "option", "shift", "cmd"], key: "b"), "⌃⌥⇧⌘B")
        XCTAssertEqual(KeystrokeBadges.badgeText(modifiers: [], key: "a"), "A")
        XCTAssertEqual(KeystrokeBadges.badgeText(modifiers: ["cmd"], key: " "), "⌘Space")
        XCTAssertNil(KeystrokeBadges.badgeText(modifiers: ["cmd"], key: ""))
        XCTAssertNil(KeystrokeBadges.badgeText(modifiers: nil, key: nil))
    }

    func testBadgeLifecycleAndStacking() {
        let events = [(t: 1.0, text: "⌘C"), (t: 1.2, text: "⌘V"), (t: 1.4, text: "⌘Z"), (t: 1.6, text: "A")]
        // All four live at t=2, but capped at 3 most recent.
        let at2 = KeystrokeBadges.active(at: 2.0, events: events)
        XCTAssertEqual(at2.count, 3)
        XCTAssertEqual(at2.map(\.text), ["⌘V", "⌘Z", "A"])
        // Fade-in: at t=1.02 the first badge is partially transparent.
        let fading = KeystrokeBadges.active(at: 1.05, events: events)
        XCTAssertEqual(fading.first?.alpha ?? 1, 0.5, accuracy: 0.01)
        // After visibility + fadeOut, everything is gone.
        XCTAssertTrue(KeystrokeBadges.active(at: 4.0, events: events).isEmpty)
        // Fade-out near end of visibility.
        let late = KeystrokeBadges.active(at: 1.0 + KeystrokeBadges.visibility - 0.15, events: [(t: 1.0, text: "A")])
        XCTAssertEqual(late.first?.alpha ?? 0, 0.5, accuracy: 0.02)
    }

    // MARK: - Hide static cursor

    private func path(_ points: [(Double, Double, Double)]) -> [CursorPoint] {
        points.map { CursorPoint(t: $0.0, x: $0.1, y: $0.2) }
    }

    func testStaticCursorFadesAfterDwell() {
        // Move until t=1, then park at (100,100) for 3s (60Hz grid-ish).
        var points: [(Double, Double, Double)] = [(0, 0, 0), (0.5, 50, 50), (1.0, 100, 100)]
        for i in 1...180 { points.append((1.0 + Double(i) / 60.0, 100, 100)) }
        let p = path(points)
        XCTAssertEqual(CursorVisibility.alpha(at: 1.5, path: p), 1, accuracy: 1e-9)
        let mid = CursorVisibility.alpha(at: 1.0 + CursorVisibility.dwell + CursorVisibility.fade / 2, path: p)
        XCTAssertEqual(mid, 0.5, accuracy: 0.05)
        XCTAssertEqual(CursorVisibility.alpha(at: 3.9, path: p), 0, accuracy: 1e-9)
    }

    func testMovingCursorStaysVisible() {
        var points: [(Double, Double, Double)] = []
        for i in 0...300 { points.append((Double(i) / 60.0, Double(i) * 2, 100)) }
        XCTAssertEqual(CursorVisibility.alpha(at: 4.5, path: path(points)), 1)
    }

    func testMicroJitterCountsAsStatic() {
        var points: [(Double, Double, Double)] = [(0, 100, 100)]
        for i in 1...240 {
            let j: Double = i % 2 == 0 ? 1.0 : -1.0
            points.append((Double(i) / 60.0, 100 + j, 100 - j))
        }
        // ±1px jitter is below the 4px threshold -> considered static.
        XCTAssertEqual(CursorVisibility.alpha(at: 3.9, path: path(points)), 0, accuracy: 1e-9)
    }

    // MARK: - Loop cursor end

    func testLoopProgress() {
        XCTAssertNil(LoopCursorEnd.progress(at: 10, duration: 10))
        XCTAssertNil(LoopCursorEnd.progress(at: 5, duration: 10))
        XCTAssertEqual(LoopCursorEnd.progress(at: 10.75, duration: 10)!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(LoopCursorEnd.progress(at: 99, duration: 10)!, 1, accuracy: 1e-9)
    }

    func testLoopEasingEndpoints() {
        XCTAssertEqual(LoopCursorEnd.eased(0), 0, accuracy: 1e-9)
        XCTAssertEqual(LoopCursorEnd.eased(1), 1, accuracy: 1e-9)
        XCTAssertEqual(LoopCursorEnd.eased(0.5), 0.5, accuracy: 1e-9)
        // smoothstep is monotonic.
        var previous = 0.0
        var p = 0.0
        while p <= 1 {
            XCTAssertGreaterThanOrEqual(LoopCursorEnd.eased(p), previous - 1e-9)
            previous = LoopCursorEnd.eased(p)
            p += 0.05
        }
    }
}
