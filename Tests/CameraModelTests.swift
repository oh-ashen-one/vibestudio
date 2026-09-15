import XCTest
@testable import VibeStudio

final class CameraModelTests: XCTestCase {
    private let videoSize = CGSize(width: 1920, height: 1080)

    private func keyframe(_ t0: Double, _ t1: Double, center: CGPoint, zoom: Double) -> CameraKeyframe {
        let size = CGSize(width: videoSize.width / zoom, height: videoSize.height / zoom)
        return CameraKeyframe(tStart: t0, tEnd: t1,
                              focusRect: CGRect(origin: CGPoint(x: center.x - size.width / 2,
                                                                y: center.y - size.height / 2),
                                                size: size),
                              zoom: zoom)
    }

    func testEmptyTimelineIsFullFrame() {
        let model = CameraModel(keyframes: [], style: .focused)
        let state = model.state(at: 5, videoSize: videoSize)
        XCTAssertEqual(state.zoom, 1)
        XCTAssertEqual(state.center, CGPoint(x: 960, y: 540))
    }

    func testHoldInsideKeyframe() {
        let model = CameraModel(keyframes: [keyframe(2, 4, center: CGPoint(x: 400, y: 300), zoom: 2)],
                                style: .focused)
        XCTAssertEqual(model.state(at: 3, videoSize: videoSize),
                       CameraState(center: CGPoint(x: 400, y: 300), zoom: 2))
    }

    func testHoldAfterLastKeyframe() {
        let model = CameraModel(keyframes: [keyframe(2, 4, center: CGPoint(x: 400, y: 300), zoom: 2)],
                                style: .focused)
        XCTAssertEqual(model.state(at: 99, videoSize: videoSize).zoom, 2)
    }

    func testZoomOutSegmentReturnsFullFrame() {
        let model = CameraModel(keyframes: [
            keyframe(2, 4, center: CGPoint(x: 400, y: 300), zoom: 2),
            keyframe(5, 10, center: CGPoint(x: 960, y: 540), zoom: 1),
        ], style: .focused)
        XCTAssertEqual(model.state(at: 7, videoSize: videoSize).zoom, 1)
    }

    func testTransitionEndpointsMatchHolds() {
        let zoomed = keyframe(2, 4, center: CGPoint(x: 400, y: 300), zoom: 2)
        let full = keyframe(6, 10, center: CGPoint(x: 960, y: 540), zoom: 1)
        for style in [ZoomStyle.focused, .smooth] {
            let model = CameraModel(keyframes: [zoomed, full], style: style)
            let atStart = model.state(at: 4.0001, videoSize: videoSize)
            let atEnd = model.state(at: 5.9999, videoSize: videoSize)
            XCTAssertEqual(atStart.zoom, 2, accuracy: 0.02)
            XCTAssertEqual(atEnd.zoom, 1, accuracy: 0.02)
            XCTAssertEqual(atStart.center.x, 400, accuracy: 5)
            XCTAssertEqual(atEnd.center.x, 960, accuracy: 5)
        }
    }

    func testTransitionIsMonotonicInZoom() {
        let model = CameraModel(keyframes: [
            keyframe(2, 4, center: CGPoint(x: 400, y: 300), zoom: 2),
            keyframe(6, 10, center: CGPoint(x: 960, y: 540), zoom: 1),
        ], style: .focused)
        var previous = Double.greatestFiniteMagnitude
        var t = 4.0
        while t <= 6.0 {
            let zoom = model.state(at: t, videoSize: videoSize).zoom
            XCTAssertLessThanOrEqual(zoom, previous + 1e-9, "zoom increased during zoom-out at t=\(t)")
            XCTAssertFalse(zoom.isNaN)
            previous = zoom
            t += 0.05
        }
    }

    func testFocusedSettlesFasterThanSmooth() {
        let zoomed = keyframe(2, 4, center: CGPoint(x: 400, y: 300), zoom: 2)
        let full = keyframe(8, 10, center: CGPoint(x: 960, y: 540), zoom: 1)
        let focused = CameraModel(keyframes: [zoomed, full], style: .focused)
        let smooth = CameraModel(keyframes: [zoomed, full], style: .smooth)
        // 25% into the transition, focused is further along (lower zoom).
        let focusedZoom = focused.state(at: 5.0, videoSize: videoSize).zoom
        let smoothZoom = smooth.state(at: 5.0, videoSize: videoSize).zoom
        XCTAssertLessThan(focusedZoom, smoothZoom)
    }

    func testSpringCurveBoundaries() {
        for curve in [SpringCurve.focused, .smooth] {
            XCTAssertEqual(curve.evaluate(elapsed: 0, duration: 1), 0, accuracy: 1e-9)
            XCTAssertEqual(curve.evaluate(elapsed: 1, duration: 1), 1, accuracy: 1e-9)
            XCTAssertEqual(curve.evaluate(elapsed: -1, duration: 1), 0, accuracy: 1e-9)
            XCTAssertEqual(curve.evaluate(elapsed: 99, duration: 1), 1, accuracy: 1e-9)
            var previous = 0.0
            var t = 0.0
            while t <= 1.0 {
                let value = curve.evaluate(elapsed: t, duration: 1)
                XCTAssertGreaterThanOrEqual(value, previous - 1e-9)
                XCTAssertTrue((0...1).contains(value))
                previous = value
                t += 0.02
            }
        }
    }

    func testSpringCurveZeroDurationIsSafe() {
        XCTAssertEqual(SpringCurve.focused.evaluate(elapsed: 0.5, duration: 0), 1)
    }

    func testSourceRectClampedToVideo() {
        let state = CameraState(center: CGPoint(x: 10, y: 10), zoom: 1)
        XCTAssertEqual(state.sourceRect(videoSize: videoSize), CGRect(origin: .zero, size: videoSize))
        let zoomed = CameraState(center: CGPoint(x: 0, y: 0), zoom: 2)
        let rect = zoomed.sourceRect(videoSize: videoSize)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, videoSize.width)
        XCTAssertLessThanOrEqual(rect.maxY, videoSize.height)
        XCTAssertEqual(rect.width, 960, accuracy: 1e-9)
    }

    func testUnorderedKeyframesAreSorted() {
        let model = CameraModel(keyframes: [
            keyframe(6, 8, center: CGPoint(x: 960, y: 540), zoom: 1),
            keyframe(2, 4, center: CGPoint(x: 400, y: 300), zoom: 2),
        ], style: .focused)
        XCTAssertEqual(model.state(at: 3, videoSize: videoSize).zoom, 2)
    }
}
