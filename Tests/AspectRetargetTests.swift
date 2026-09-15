import XCTest
@testable import VibeStudio

final class AspectRetargetTests: XCTestCase {
    private let source = CGSize(width: 1920, height: 1080)

    private func keyframe(center: CGPoint, zoom: Double) -> CameraKeyframe {
        let size = CGSize(width: source.width / zoom, height: source.height / zoom)
        return CameraKeyframe(tStart: 0, tEnd: 2,
                              focusRect: CGRect(origin: CGPoint(x: center.x - size.width / 2,
                                                                y: center.y - size.height / 2),
                                                size: size),
                              zoom: zoom)
    }

    func testZoomPreservedAndWindowAspectChanges() {
        let retargeted = AspectRetarget.retarget(keyframe(center: CGPoint(x: 960, y: 540), zoom: 2),
                                                 sourceSize: source, targetAspect: 9.0 / 16.0)
        XCTAssertEqual(retargeted.zoom, 2, accuracy: 1e-9)
        // Window keeps 1/zoom of the frame HEIGHT, aspect = target.
        XCTAssertEqual(retargeted.focusRect.height, 540, accuracy: 1e-6)
        XCTAssertEqual(retargeted.focusRect.width, 540 * 9.0 / 16.0, accuracy: 1e-6)
        XCTAssertEqual(retargeted.focusRect.width / retargeted.focusRect.height, 9.0 / 16.0, accuracy: 1e-6)
    }

    func testCenterPreservedWhenInsideBounds() {
        let retargeted = AspectRetarget.retarget(keyframe(center: CGPoint(x: 960, y: 540), zoom: 2),
                                                 sourceSize: source, targetAspect: 1)
        XCTAssertEqual(retargeted.focusRect.midX, 960, accuracy: 1e-6)
        XCTAssertEqual(retargeted.focusRect.midY, 540, accuracy: 1e-6)
        XCTAssertEqual(retargeted.focusRect.width, retargeted.focusRect.height, accuracy: 1e-6)
    }

    func testCenterClampedAtSourceEdge() {
        // Action at the far right edge: the vertical window must clamp inside.
        let retargeted = AspectRetarget.retarget(keyframe(center: CGPoint(x: 1900, y: 540), zoom: 2),
                                                 sourceSize: source, targetAspect: 9.0 / 16.0)
        XCTAssertLessThanOrEqual(retargeted.focusRect.maxX, source.width + 1e-6)
        XCTAssertGreaterThanOrEqual(retargeted.focusRect.minX, 0)
        // Center shifted left so the window fits — but action is still inside.
        XCTAssertTrue(retargeted.focusRect.contains(CGPoint(x: 1900, y: 540)))
    }

    func testZoomOutSegmentBecomesCenteredBestFit() {
        let full = keyframe(center: CGPoint(x: 960, y: 540), zoom: 1)
        let retargeted = AspectRetarget.retarget(full, sourceSize: source, targetAspect: 9.0 / 16.0)
        XCTAssertEqual(retargeted.focusRect.height, source.height, accuracy: 1e-6)
        XCTAssertEqual(retargeted.focusRect.width, source.height * 9.0 / 16.0, accuracy: 1e-6)
        XCTAssertEqual(retargeted.focusRect.midX, source.width / 2, accuracy: 1e-6)
        XCTAssertEqual(retargeted.zoom, 1, accuracy: 1e-9)
    }

    func testSourceAspectIsNoOp() {
        let original = keyframe(center: CGPoint(x: 400, y: 300), zoom: 2)
        let retargeted = AspectRetarget.retarget(original, sourceSize: source,
                                                 targetAspect: 16.0 / 9.0)
        XCTAssertEqual(retargeted, original)
    }

    func testWindowNeverExceedsSource() {
        for aspect in [9.0 / 16.0, 1.0, 16.0 / 9.0] {
            for center in [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 1080), CGPoint(x: 960, y: 540)] {
                for zoom in [1.0, 1.5, 2.0, 2.8] {
                    let rect = AspectRetarget.window(center: center, zoom: zoom,
                                                     sourceSize: source, targetAspect: aspect)
                    XCTAssertGreaterThanOrEqual(rect.minX, 0)
                    XCTAssertGreaterThanOrEqual(rect.minY, 0)
                    XCTAssertLessThanOrEqual(rect.maxX, source.width + 1e-9)
                    XCTAssertLessThanOrEqual(rect.maxY, source.height + 1e-9)
                }
            }
        }
    }

    func testCameraStateAspectSourceRectMatchesRetarget() {
        // The retargeted hold window must equal what CameraState.sourceRect
        // produces with the target aspect — no drift between the two paths.
        let keyframe = AspectRetarget.retarget(keyframe(center: CGPoint(x: 700, y: 400), zoom: 2),
                                               sourceSize: source, targetAspect: 9.0 / 16.0)
        let state = CameraState(center: keyframe.center, zoom: keyframe.zoom)
        let rect = state.sourceRect(videoSize: source, aspect: 9.0 / 16.0)
        XCTAssertEqual(rect.width, keyframe.focusRect.width, accuracy: 1e-6)
        XCTAssertEqual(rect.height, keyframe.focusRect.height, accuracy: 1e-6)
        XCTAssertEqual(rect.midX, keyframe.focusRect.midX, accuracy: 1e-6)
        XCTAssertEqual(rect.midY, keyframe.focusRect.midY, accuracy: 1e-6)
    }

    func testSourceRectDefaultAspectUnchanged() {
        // Backward compatibility: no aspect -> W/zoom x H/zoom as before.
        let state = CameraState(center: CGPoint(x: 960, y: 540), zoom: 2)
        let rect = state.sourceRect(videoSize: source)
        XCTAssertEqual(rect.width, 960, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 540, accuracy: 1e-6)
    }
}
