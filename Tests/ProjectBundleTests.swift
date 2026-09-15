import XCTest
@testable import VibeStudio

final class ProjectBundleTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibestudio-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    private func makeLooseFolder(name: String = "2026-09-15_12-00-00", withWebcam: Bool = false) throws -> URL {
        let folder = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fake video bytes".utf8).write(to: folder.appendingPathComponent("recording.mov"))
        if withWebcam {
            try Data("fake webcam bytes".utf8).write(to: folder.appendingPathComponent("webcam.mov"))
        }
        let log = EventLog(events: [
            .cursorMove(t: 0, x: 10, y: 20),
            .click(t: 0.5, x: 10, y: 20, button: "left"),
        ])
        try JSONEncoder().encode(log).write(to: folder.appendingPathComponent("events.json"))
        let meta = RecordingMeta(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 sourceMode: "display",
                                 displayID: 1,
                                 displayFrameCGPoints: CGRect(x: 0, y: 0, width: 960, height: 540),
                                 scaleFactor: 2,
                                 outputPixelSize: CGSize(width: 1920, height: 1080),
                                 sourceRectPixels: nil,
                                 windowID: nil,
                                 windowFrameCGPoints: nil,
                                 frameRate: 60,
                                 systemAudioCaptured: true,
                                 screenFirstHostSeconds: 100.5,
                                 webcamFirstHostSeconds: withWebcam ? 100.75 : nil,
                                 micFirstHostSeconds: nil,
                                 files: ["recording.mov", "events.json", "recording-meta.json"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: folder.appendingPathComponent("recording-meta.json"))
        return folder
    }

    func testImportCreatesBundleAndLoadRoundTrips() throws {
        let folder = try makeLooseFolder(withWebcam: true)
        let bundle = try ProjectStore.importLooseFolder(folder, to: nil)
        XCTAssertEqual(bundle.pathExtension, ProjectStore.bundleExtension)
        for name in ["recording.mov", "webcam.mov", "events.json", "recording-meta.json", "project.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent(name).path),
                          "missing \(name) in bundle")
        }

        let loaded = try ProjectStore.load(bundleURL: bundle)
        XCTAssertEqual(loaded.state.recordingFile, "recording.mov")
        XCTAssertEqual(loaded.state.webcamFile, "webcam.mov")
        XCTAssertEqual(loaded.state.eventsFile, "events.json")
        XCTAssertEqual(loaded.state.metaFile, "recording-meta.json")
        XCTAssertEqual(loaded.meta.scaleFactor, 2)
        XCTAssertEqual(loaded.meta.outputPixelSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(loaded.events.count, 2)
        XCTAssertEqual(loaded.events[1].kind, .click)
        XCTAssertEqual(loaded.events[1].button, "left")
        XCTAssertEqual(loaded.meta.webcamFirstHostSeconds ?? 0, 100.75, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: loaded.recordingURL), Data("fake video bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(loaded.webcamURL)), Data("fake webcam bytes".utf8))
    }

    func testImportWithoutWebcam() throws {
        let folder = try makeLooseFolder(withWebcam: false)
        let bundle = try ProjectStore.importLooseFolder(folder, to: nil)
        let loaded = try ProjectStore.load(bundleURL: bundle)
        XCTAssertNil(loaded.state.webcamFile)
        XCTAssertNil(loaded.webcamURL)
    }

    func testImportFailsOnMissingRecording() throws {
        let folder = tempRoot.appendingPathComponent("empty-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ProjectStore.importLooseFolder(folder, to: nil)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .missingFile("recording.mov"))
        }
    }

    func testReimportReplacesExistingBundle() throws {
        let folder = try makeLooseFolder()
        let first = try ProjectStore.importLooseFolder(folder, to: nil)
        let second = try ProjectStore.importLooseFolder(folder, to: nil)
        XCTAssertEqual(first, second)
        XCTAssertNoThrow(try ProjectStore.load(bundleURL: second))
    }

    func testProjectStateCodableRoundTrip() throws {
        let state = ProjectState(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 appVersion: "1.0",
                                 recordingFile: "recording.mov",
                                 webcamFile: nil,
                                 eventsFile: "events.json",
                                 metaFile: "recording-meta.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ProjectState.self, from: data), state)
    }
}
