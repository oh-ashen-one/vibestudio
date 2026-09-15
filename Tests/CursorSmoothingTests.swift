import XCTest
@testable import VibeStudio

final class CursorSmoothingTests: XCTestCase {
    private func constantPath(x: Double, y: Double, duration: Double, rate: Double = 120) -> [CursorPoint] {
        stride(from: 0.0, through: duration, by: 1.0 / rate).map {
            CursorPoint(t: $0, x: x, y: y)
        }
    }

    func testResampleProducesUniformGrid() {
        // Irregularly spaced input 0...1s -> 61 samples at 60 Hz.
        let input = [CursorPoint(t: 0, x: 0, y: 0),
                     CursorPoint(t: 0.3, x: 30, y: 60),
                     CursorPoint(t: 1.0, x: 100, y: 200)]
        let output = CursorSmoother.resample(input, interval: 1.0 / 60)
        XCTAssertEqual(output.count, 61)
        XCTAssertEqual(output.first?.t ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(output.last?.t ?? -1, 1.0, accuracy: 1e-9)
        // Linear interpolation at t=0.3 lands exactly on the anchor point.
        let at03 = output.first { abs($0.t - 0.3) < 1e-6 }
        XCTAssertEqual(at03?.x ?? -1, 30, accuracy: 1e-6)
    }

    func testResamplePreservesEndpoints() {
        let input = [CursorPoint(t: 0, x: 5, y: 7),
                     CursorPoint(t: 0.5, x: 50, y: 70),
                     CursorPoint(t: 1.0, x: 500, y: 700)]
        let output = CursorSmoother.resample(input, interval: 1.0 / 60)
        XCTAssertEqual(output.first, CursorPoint(t: 0, x: 5, y: 7))
        XCTAssertEqual(output.last?.x ?? 0, 500, accuracy: 1e-9)
        XCTAssertEqual(output.last?.y ?? 0, 700, accuracy: 1e-9)
    }

    func testJitterSuppressionPinsDwell() {
        // ±1px oscillation around (100,100) never exceeds the 2px threshold.
        var input: [CursorPoint] = [CursorPoint(t: 0, x: 100, y: 100)]
        for i in 1...240 {
            let offset: Double = i % 2 == 0 ? 1.0 : -1.0
            input.append(CursorPoint(t: Double(i) / 120.0, x: 100 + offset, y: 100 - offset * 0.5))
        }
        let output = CursorSmoother.resample(input, interval: 1.0 / 60)
        for point in output {
            XCTAssertEqual(point.x, 100, accuracy: 1e-9)
            XCTAssertEqual(point.y, 100, accuracy: 1e-9)
        }
    }

    func testSlowDriftAccumulatesPastThreshold() {
        // 1.5px per 1/120s step: each 60Hz frame moves 3px from the anchor.
        let input = stride(from: 0.0, through: 1.0, by: 1.0 / 120.0).map {
            CursorPoint(t: $0, x: 100 + 1.5 * $0 * 120, y: 100)
        }
        let output = CursorSmoother.resample(input, interval: 1.0 / 60)
        XCTAssertGreaterThan(output.last?.x ?? 0, 250)
        XCTAssertLessThan(output.first?.x ?? 999, 101)
    }

    func testSpringConvergesOnStep() {
        // Step from x=0 to x=100 at t=0.25, held 2s.
        var input = constantPath(x: 0, y: 0, duration: 0.25, rate: 60)
        input += stride(from: 0.25 + 1.0 / 60.0, through: 2.25, by: 1.0 / 60.0).map {
            CursorPoint(t: $0, x: 100, y: 0)
        }
        let output = CursorSmoother.smooth(input, interval: 1.0 / 60,
                                           stiffness: SmoothnessPreset.standard.stiffness)
        XCTAssertEqual(output.last?.x ?? 0, 100, accuracy: 1.0)
        // Critically damped: no meaningful overshoot past the target.
        XCTAssertLessThanOrEqual(output.map(\.x).max() ?? 0, 101)
    }

    func testSpringStartsExactlyAtFirstPoint() {
        let input = constantPath(x: 42, y: 24, duration: 1.0, rate: 60)
        let output = CursorSmoother.smooth(input, interval: 1.0 / 60, stiffness: 120)
        XCTAssertEqual(output.first, input.first)
    }

    func testStifferPresetTracksTargetFaster() {
        var input = constantPath(x: 0, y: 0, duration: 0.1, rate: 60)
        input += stride(from: 0.1 + 1.0 / 60.0, through: 1.1, by: 1.0 / 60.0).map {
            CursorPoint(t: $0, x: 100, y: 0)
        }
        let rapid = CursorSmoother.smooth(input, interval: 1.0 / 60, stiffness: SmoothnessPreset.rapid.stiffness)
        let slow = CursorSmoother.smooth(input, interval: 1.0 / 60, stiffness: SmoothnessPreset.slow.stiffness)
        // Mid-flight (t=0.2) the rapid spring is further along toward 100.
        func x(at t: Double, in path: [CursorPoint]) -> Double {
            path.min(by: { abs($0.t - t) < abs($1.t - t) })?.x ?? 0
        }
        XCTAssertGreaterThan(x(at: 0.2, in: rapid), x(at: 0.2, in: slow))
    }

    func testFullPipelineJitterCollapses() {
        // Full pipeline: dwell with jitter -> smoothed path stays put.
        var events: [RecordedEvent] = (0...120).map { i in
            let jx: Double = i % 2 == 0 ? 0.7 : -0.7
            return .cursorMove(t: Double(i) / 120.0, x: 500 + jx, y: 300 - jx)
        }
        events.append(.click(t: 1.0, x: 500, y: 300, button: "left"))
        let smoothed = CursorSmoother.smoothedPath(from: events, frameRate: 60)
        for point in smoothed {
            XCTAssertEqual(point.x, 500, accuracy: 2.0)
            XCTAssertEqual(point.y, 300, accuracy: 2.0)
        }
    }
}
