import XCTest
@testable import VibeStudio

final class AutoZoomEngineTests: XCTestCase {
    private let videoSize = CGSize(width: 1920, height: 1080)

    private func meta() -> RecordingMeta {
        RecordingMeta(createdAt: Date(timeIntervalSince1970: 0),
                      sourceMode: "display",
                      displayID: 1,
                      displayFrameCGPoints: CGRect(x: 0, y: 0, width: 960, height: 540),
                      scaleFactor: 2,
                      outputPixelSize: videoSize,
                      sourceRectPixels: nil,
                      windowID: nil,
                      windowFrameCGPoints: nil,
                      frameRate: 60,
                      systemAudioCaptured: false,
                      screenFirstHostSeconds: nil,
                      webcamFirstHostSeconds: nil,
                      micFirstHostSeconds: nil,
                      files: [])
    }

    private var projector: EventProjector { EventProjector(meta: meta()) }

    private func cursorMoves(from start: CGPoint, to end: CGPoint, t0: Double, t1: Double, rate: Double = 30) -> [RecordedEvent] {
        stride(from: t0, through: t1, by: 1.0 / rate).map { t in
            let f = (t - t0) / (t1 - t0)
            return .cursorMove(t: t,
                               x: Double(start.x) + Double(end.x - start.x) * f,
                               y: Double(start.y) + Double(end.y - start.y) * f)
        }
    }

    // MARK: - Clustering

    func testNearbyClicksMergeIntoOneCluster() {
        // Two clicks 1s apart, 100px apart (video px = CG pt * 2).
        var events = cursorMoves(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 200, y: 150), t0: 0, t1: 5)
        events.append(.click(t: 2.0, x: 150, y: 150, button: "left"))
        events.append(.click(t: 3.0, x: 200, y: 150, button: "left"))
        let activities = AutoZoomEngine.activities(from: events, projector: projector)
        let clusters = AutoZoomEngine.cluster(activities, videoSize: videoSize)
        XCTAssertEqual(clusters.count, 1)
    }

    func testDistantClicksSplitClusters() {
        var events = cursorMoves(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), t0: 0, t1: 0.5)
        events += cursorMoves(from: CGPoint(x: 900, y: 500), to: CGPoint(x: 900, y: 500), t0: 3.0, t1: 3.5)
        events.append(.click(t: 1.0, x: 100, y: 100, button: "left"))
        events.append(.click(t: 4.0, x: 900, y: 500, button: "left"))
        let clusters = AutoZoomEngine.cluster(AutoZoomEngine.activities(from: events, projector: projector),
                                              videoSize: videoSize)
        XCTAssertEqual(clusters.count, 2)
    }

    func testTimeGapBeyondMergeWindowSplitsClusters() {
        // Same spot, but 3s apart (> mergeWindow 1.5).
        var events = cursorMoves(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), t0: 0, t1: 6)
        events.append(.click(t: 1.0, x: 100, y: 100, button: "left"))
        events.append(.click(t: 4.0, x: 100, y: 100, button: "left"))
        let clusters = AutoZoomEngine.cluster(AutoZoomEngine.activities(from: events, projector: projector),
                                              videoSize: videoSize)
        XCTAssertEqual(clusters.count, 2)
    }

    func testWeakActivityWithoutClicksNeedsTwoEvents() {
        var events = cursorMoves(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), t0: 0, t1: 2)
        events.append(.key(t: 1.0, modifiers: ["cmd"], key: "c", keyCode: 8))
        // Single key event, no click -> no cluster.
        let clusters = AutoZoomEngine.cluster(AutoZoomEngine.activities(from: events, projector: projector),
                                              videoSize: videoSize)
        XCTAssertEqual(clusters.count, 0)
    }

    // MARK: - Keyframe emission

    func testFirstKeyframeAnticipatesFirstClick() {
        var events = cursorMoves(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 220, y: 200), t0: 0, t1: 5)
        events.append(.click(t: 2.0, x: 200, y: 200, button: "left"))
        events.append(.click(t: 2.4, x: 210, y: 200, button: "left"))
        let keyframes = AutoZoomEngine.keyframes(from: events, projector: projector,
                                                 videoSize: videoSize, duration: 10)
        let first = keyframes.first!
        XCTAssertEqual(first.tStart, 2.0 - AutoZoomEngine.anticipation, accuracy: 1e-9)
        XCTAssertGreaterThan(first.zoom, 1)
    }

    func testZoomOutAfterInactivity() {
        var events = cursorMoves(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 200, y: 200), t0: 0, t1: 2)
        events.append(.click(t: 1.0, x: 200, y: 200, button: "left"))
        let keyframes = AutoZoomEngine.keyframes(from: events, projector: projector,
                                                 videoSize: videoSize, duration: 10)
        XCTAssertEqual(keyframes.count, 2)
        let zoomOut = keyframes[1]
        XCTAssertEqual(zoomOut.zoom, 1)
        XCTAssertEqual(zoomOut.focusRect, CGRect(origin: .zero, size: videoSize))
        XCTAssertEqual(zoomOut.tStart, keyframes[0].tEnd + AutoZoomEngine.zoomOutDelay, accuracy: 1e-9)
    }

    func testNearbyClustersPanWithoutZoomOut() {
        // Two clusters 300 CG pt apart (600 video px < panRadius 0.4*1920=768),
        // 3s apart (gap > mergeWindow so they split).
        var events = cursorMoves(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), t0: 0, t1: 1)
        events += cursorMoves(from: CGPoint(x: 400, y: 100), to: CGPoint(x: 400, y: 100), t0: 3.0, t1: 4)
        events.append(.click(t: 0.5, x: 100, y: 100, button: "left"))
        events.append(.click(t: 3.5, x: 400, y: 100, button: "left"))
        let keyframes = AutoZoomEngine.keyframes(from: events, projector: projector,
                                                 videoSize: videoSize, duration: 10)
        // No zoom-out segment BETWEEN the two zoomed segments (a trailing
        // zoom-out at the end of the recording is fine).
        let secondZoomIn = keyframes.firstIndex(where: { $0.zoom > 1 && $0.tStart > 1 })!
        let between = keyframes[1..<secondZoomIn]
        XCTAssertTrue(between.allSatisfy { $0.zoom > 1 },
                      "camera should pan, not zoom out, between nearby clusters")
        XCTAssertGreaterThanOrEqual(keyframes.count, 2)
        XCTAssertTrue(keyframes.prefix(2).allSatisfy { $0.zoom > 1 })
    }

    func testDistantClustersZoomOutBetween() {
        var events = cursorMoves(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 100), t0: 0, t1: 1)
        events += cursorMoves(from: CGPoint(x: 900, y: 500), to: CGPoint(x: 900, y: 500), t0: 4.0, t1: 5)
        events.append(.click(t: 0.5, x: 100, y: 100, button: "left"))
        events.append(.click(t: 4.5, x: 900, y: 500, button: "left"))
        let keyframes = AutoZoomEngine.keyframes(from: events, projector: projector,
                                                 videoSize: videoSize, duration: 10)
        XCTAssertTrue(keyframes.contains { $0.zoom == 1 })
        // Zoom-out begins ~1s after the first cluster's hold ends.
        let firstZoom = keyframes[0]
        let gap = keyframes[1]
        XCTAssertEqual(gap.tStart, firstZoom.tEnd + AutoZoomEngine.zoomOutDelay, accuracy: 1e-9)
    }

    func testFullScreenActivityStaysAt1x() {
        // Click trail chains across the whole screen within the merge window:
        // the merged cluster's bounding box exceeds the full-screen factor.
        var events = cursorMoves(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 850, y: 475), t0: 0, t1: 2)
        // Click trail chaining across the screen (each step within the spatial
        // radius): the merged cluster's bbox exceeds the full-screen factor.
        events.append(.click(t: 0.4, x: 50, y: 50, button: "left"))
        events.append(.click(t: 0.8, x: 250, y: 150, button: "left"))
        events.append(.click(t: 1.2, x: 450, y: 250, button: "left"))
        events.append(.click(t: 1.6, x: 650, y: 350, button: "left"))
        events.append(.click(t: 2.0, x: 850, y: 475, button: "left"))
        let keyframes = AutoZoomEngine.keyframes(from: events, projector: projector,
                                                 videoSize: videoSize, duration: 10)
        XCTAssertEqual(keyframes.first?.zoom, 1)
    }

    func testZoomClampedByMinVisibleWidth() {
        // maxZoom = 1/0.35 ≈ 2.86; default 2.0 is inside, verify clamp bounds.
        let cluster = AutoZoomEngine.Cluster(activities: [
            .init(t: 1, point: CGPoint(x: 960, y: 540), isClick: true),
        ])
        let (_, zoom) = AutoZoomEngine.focusRect(for: cluster, videoSize: videoSize)
        XCTAssertGreaterThanOrEqual(zoom, AutoZoomEngine.minZoom)
        XCTAssertLessThanOrEqual(zoom, 1.0 / AutoZoomEngine.minVisibleWidthFactor)
    }

    func testFocusRectClampedInsideVideo() {
        // Cluster in the corner: focus rect must not leave the video bounds.
        let cluster = AutoZoomEngine.Cluster(activities: [
            .init(t: 1, point: CGPoint(x: 5, y: 5), isClick: true),
            .init(t: 1.2, point: CGPoint(x: 30, y: 20), isClick: true),
        ])
        let (rect, zoom) = AutoZoomEngine.focusRect(for: cluster, videoSize: videoSize)
        XCTAssertGreaterThan(zoom, 1)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, videoSize.width)
        XCTAssertLessThanOrEqual(rect.maxY, videoSize.height)
    }

    func testCursorPositionInterpolation() {
        let path = [CursorPoint(t: 0, x: 0, y: 0), CursorPoint(t: 1, x: 100, y: 50)]
        XCTAssertEqual(AutoZoomEngine.cursorPosition(at: 0.5, in: path), CGPoint(x: 50, y: 25))
        XCTAssertEqual(AutoZoomEngine.cursorPosition(at: -1, in: path), CGPoint(x: 0, y: 0))
        XCTAssertEqual(AutoZoomEngine.cursorPosition(at: 5, in: path), CGPoint(x: 100, y: 50))
        XCTAssertNil(AutoZoomEngine.cursorPosition(at: 0, in: []))
    }

    func testEmptyEventsProduceNoKeyframes() {
        XCTAssertTrue(AutoZoomEngine.keyframes(from: [], projector: projector,
                                               videoSize: videoSize, duration: 10).isEmpty)
    }
}
