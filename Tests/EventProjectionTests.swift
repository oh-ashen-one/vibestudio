import XCTest
@testable import VibeStudio

final class EventProjectionTests: XCTestCase {
    private func meta(sourceMode: String = "display",
                      displayFrame: CGRect,
                      scale: Double,
                      output: CGSize,
                      sourceRect: CGRect? = nil,
                      windowFrame: CGRect? = nil) -> RecordingMeta {
        RecordingMeta(createdAt: Date(timeIntervalSince1970: 0),
                      sourceMode: sourceMode,
                      displayID: 1,
                      displayFrameCGPoints: displayFrame,
                      scaleFactor: scale,
                      outputPixelSize: output,
                      sourceRectPixels: sourceRect,
                      windowID: nil,
                      windowFrameCGPoints: windowFrame,
                      frameRate: 60,
                      systemAudioCaptured: false,
                      screenFirstHostSeconds: nil,
                      webcamFirstHostSeconds: nil,
                      micFirstHostSeconds: nil,
                      files: [])
    }

    func testDisplayProjectionScale2() {
        // Fixture mapping: 960x540pt display @2x -> 1920x1080 video.
        let projector = EventProjector(meta: meta(displayFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
                                                  scale: 2,
                                                  output: CGSize(width: 1920, height: 1080),
                                                  sourceRect: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        // Known fixture click at display center (480,270) -> pixel (960,540).
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 480, y: 270)), CGPoint(x: 960, y: 540))
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 300, y: 200)), CGPoint(x: 600, y: 400))
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 700, y: 400)), CGPoint(x: 1400, y: 800))
    }

    func testDisplayProjectionScale1() {
        let projector = EventProjector(meta: meta(displayFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                  scale: 1,
                                                  output: CGSize(width: 1920, height: 1080)))
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 500, y: 400)), CGPoint(x: 500, y: 400))
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 0))
    }

    func testResolutionCapRatio() {
        // Native 1920x1080 captured, but output capped to 960x540.
        let projector = EventProjector(meta: meta(displayFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
                                                  scale: 2,
                                                  output: CGSize(width: 960, height: 540)))
        XCTAssertEqual(projector.outputScale, 0.5, accuracy: 1e-9)
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 480, y: 270)), CGPoint(x: 480, y: 270))
    }

    func testAreaProjectionScale2() {
        let projector = EventProjector(meta: meta(sourceMode: "area",
                                                  displayFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
                                                  scale: 2,
                                                  output: CGSize(width: 400, height: 200),
                                                  sourceRect: CGRect(x: 200, y: 100, width: 400, height: 200)))
        // CG point (150, 100) -> native (300, 200) -> minus source origin -> (100, 100).
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 150, y: 100)), CGPoint(x: 100, y: 100))
    }

    func testWindowProjectionScale2() {
        let projector = EventProjector(meta: meta(sourceMode: "window",
                                                  displayFrame: CGRect(x: 0, y: 0, width: 960, height: 540),
                                                  scale: 2,
                                                  output: CGSize(width: 800, height: 600),
                                                  windowFrame: CGRect(x: 100, y: 100, width: 400, height: 300)))
        // Point at window origin -> (0,0); center -> (400,300).
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 100, y: 100)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(projector.videoPoint(forGlobalCGPoint: CGPoint(x: 300, y: 250)), CGPoint(x: 400, y: 300))
    }
}
