import XCTest
@testable import VibeStudio

/// Parses the generated dev fixture (scripts/make_fixture.sh) and asserts its
/// schema compatibility and known scripted coordinates. Skips when the fixture
/// has not been generated (e.g. fresh clone).
final class FixtureTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample-recording", isDirectory: true)
    }

    private func loadFixture() throws -> (EventLog, RecordingMeta) {
        let eventsData = try Data(contentsOf: fixtureURL.appendingPathComponent("events.json"))
        let log = try JSONDecoder().decode(EventLog.self, from: eventsData)
        let metaData = try Data(contentsOf: fixtureURL.appendingPathComponent("recording-meta.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(RecordingMeta.self, from: metaData)
        return (log, meta)
    }

    func testFixtureParsesAgainstSchema() throws {
        guard FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("events.json").path) else {
            throw XCTSkip("fixture not generated — run ./scripts/make_fixture.sh")
        }
        let (log, meta) = try loadFixture()
        XCTAssertEqual(log.version, 1)
        XCTAssertEqual(meta.version, 1)
        XCTAssertEqual(meta.sourceMode, "display")
        XCTAssertEqual(meta.displayFrameCGPoints, CGRect(x: 0, y: 0, width: 960, height: 540))
        XCTAssertEqual(meta.scaleFactor, 2)
        XCTAssertEqual(meta.outputPixelSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(meta.sourceRectPixels, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(meta.frameRate, 60)
        XCTAssertGreaterThan(log.events.count, 3000)
    }

    func testFixtureScriptedClicksProjectToExpectedPixels() throws {
        guard FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("events.json").path) else {
            throw XCTSkip("fixture not generated — run ./scripts/make_fixture.sh")
        }
        let (log, meta) = try loadFixture()
        let projector = EventProjector(meta: meta)
        let clicks = log.events.filter { $0.kind == .click }
        XCTAssertEqual(clicks.count, 6)
        // The t=10 click is scripted at exact display center (480,270).
        let centerClick = try XCTUnwrap(clicks.first { abs($0.t - 10.0) < 1e-6 })
        XCTAssertEqual(centerClick.x, 480)
        XCTAssertEqual(centerClick.y, 270)
        let pixel = try XCTUnwrap(projector.videoPoint(for: centerClick))
        XCTAssertEqual(pixel, CGPoint(x: 960, y: 540))
        // All clicks project inside the 1920x1080 video bounds.
        for click in clicks {
            let point = try XCTUnwrap(projector.videoPoint(for: click))
            XCTAssertTrue((0...1920).contains(point.x), "click at t=\(click.t) x out of bounds")
            XCTAssertTrue((0...1080).contains(point.y), "click at t=\(click.t) y out of bounds")
        }
    }

    func testFixtureEventKindsAndTiming() throws {
        guard FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("events.json").path) else {
            throw XCTSkip("fixture not generated — run ./scripts/make_fixture.sh")
        }
        let (log, _) = try loadFixture()
        let kinds = Set(log.events.map(\.kind))
        XCTAssertTrue(kinds.contains(.cursorMove))
        XCTAssertTrue(kinds.contains(.click))
        XCTAssertTrue(kinds.contains(.scroll))
        XCTAssertTrue(kinds.contains(.key))
        XCTAssertTrue(kinds.contains(.cursorType))
        XCTAssertTrue(kinds.contains(.frontmostWindow))
        for event in log.events {
            XCTAssertTrue((0...30).contains(event.t), "event t=\(event.t) outside recording")
        }
        // Cursor path is extractable and long enough for smoothing.
        let path = CursorSmoother.cursorPath(from: log.events)
        XCTAssertGreaterThan(path.count, 3000)
        let smoothed = CursorSmoother.smoothedPath(from: log.events, frameRate: 60)
        XCTAssertFalse(smoothed.isEmpty)
        XCTAssertEqual(smoothed.first, path.first.map { CursorPoint(t: $0.t, x: $0.x, y: $0.y) })
    }
}
