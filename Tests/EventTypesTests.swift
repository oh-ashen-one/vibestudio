import XCTest
@testable import VibeStudio

final class EventTypesTests: XCTestCase {
    private func makeSampleLog() -> EventLog {
        EventLog(events: [
            .cursorType(t: 0, name: "arrow"),
            .cursorMove(t: 0.5, x: 100.5, y: 200.25),
            .click(t: 1.0, x: 100.5, y: 200.25, button: "left"),
            .click(t: 1.2, x: 50, y: 60, button: "right"),
            .scroll(t: 1.5, dx: -3, dy: 12),
            .key(t: 2.0, modifiers: ["cmd", "shift"], key: "z", keyCode: 6),
            .frontmostWindow(t: 2.5,
                             frame: CGRect(x: 10, y: 20, width: 800, height: 600),
                             appBundleID: "dev.vibestudio.app"),
            .frontmostWindow(t: 3.0, frame: nil, appBundleID: nil),
        ])
    }

    func testEventLogCodableRoundTrip() throws {
        let log = makeSampleLog()
        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(EventLog.self, from: data)
        XCTAssertEqual(decoded, log)
    }

    func testEventJSONShapeMatchesSchema() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(RecordedEvent.click(t: 1.234, x: 10, y: 20, button: "left"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "click")
        XCTAssertEqual(object["x"] as? Double, 10)
        XCTAssertEqual(object["y"] as? Double, 20)
        XCTAssertEqual(object["button"] as? String, "left")
        XCTAssertEqual(object["t"] as? Double, 1.234)
        // Unset optional fields are omitted.
        XCTAssertNil(object["dx"])
        XCTAssertNil(object["frame"])
    }

    func testKeyEventJSONShape() throws {
        let data = try JSONEncoder().encode(RecordedEvent.key(t: 0.1, modifiers: ["cmd"], key: "c", keyCode: 8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "key")
        XCTAssertEqual(object["modifiers"] as? [String], ["cmd"])
        XCTAssertEqual(object["key"] as? String, "c")
    }

    func testCursorTypeUsesNameKey() throws {
        let data = try JSONEncoder().encode(RecordedEvent.cursorType(t: 0, name: "iBeam"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "cursorType")
        XCTAssertEqual(object["name"] as? String, "iBeam")
    }

    func testRecordingMetaCodableRoundTrip() throws {
        let meta = RecordingMeta(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceMode: "area",
            displayID: 1,
            displayFrameCGPoints: CGRect(x: 0, y: 0, width: 1440, height: 900),
            scaleFactor: 2,
            outputPixelSize: CGSize(width: 400, height: 200),
            sourceRectPixels: CGRect(x: 200, y: 0, width: 400, height: 200),
            windowID: nil,
            windowFrameCGPoints: nil,
            frameRate: 60,
            systemAudioCaptured: true,
            screenFirstHostSeconds: 123456.5,
            webcamFirstHostSeconds: 123456.75,
            micFirstHostSeconds: 123456.8,
            files: ["recording.mov", "webcam.mov", "events.json", "recording-meta.json"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }
}
