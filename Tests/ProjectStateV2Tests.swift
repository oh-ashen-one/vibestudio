import XCTest
@testable import VibeStudio

final class ProjectStateV2Tests: XCTestCase {
    private func isoEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func isoDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testCameraKeyframeCodableRoundTrip() throws {
        let keyframe = CameraKeyframe(tStart: 1.7, tEnd: 4.2,
                                      focusRect: CGRect(x: 100, y: 200, width: 960, height: 540),
                                      zoom: 2, isManual: true)
        let decoded = try JSONDecoder().decode(CameraKeyframe.self, from: JSONEncoder().encode(keyframe))
        XCTAssertEqual(decoded, keyframe)
        XCTAssertEqual(decoded.id, keyframe.id)
    }

    func testEditorSettingsCodableRoundTrip() throws {
        var settings = EditorSettings()
        settings.cursorSize = 1.8
        settings.smoothnessPreset = .slow
        settings.zoomStyle = .smooth
        settings.motionBlurStrength = 0.7
        settings.background = .custom(startHex: "#112233", endHex: "#000000")
        settings.padding = 0.12
        settings.cornerRadius = 0.06
        settings.shadowEnabled = false
        settings.cameraLayout = .webcamFull
        let decoded = try JSONDecoder().decode(EditorSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    func testBackgroundSpecJSONShape() throws {
        let preset = try JSONEncoder().encode(BackgroundSpec.preset("midnight"))
        let presetObject = try XCTUnwrap(JSONSerialization.jsonObject(with: preset) as? [String: Any])
        XCTAssertEqual(presetObject["kind"] as? String, "preset")
        XCTAssertEqual(presetObject["id"] as? String, "midnight")

        let custom = try JSONEncoder().encode(BackgroundSpec.custom(startHex: "#AABBCC", endHex: "#000000"))
        let customObject = try XCTUnwrap(JSONSerialization.jsonObject(with: custom) as? [String: Any])
        XCTAssertEqual(customObject["kind"] as? String, "custom")
        XCTAssertEqual(customObject["startHex"] as? String, "#AABBCC")
        XCTAssertEqual(try JSONDecoder().decode(BackgroundSpec.self, from: custom),
                       .custom(startHex: "#AABBCC", endHex: "#000000"))
    }

    func testProjectStateV2RoundTripWithKeyframesAndSettings() throws {
        var state = ProjectState(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 appVersion: "1.0",
                                 recordingFile: "recording.mov",
                                 webcamFile: "webcam.mov",
                                 eventsFile: "events.json",
                                 metaFile: "recording-meta.json")
        state.version = 2
        state.keyframes = [CameraKeyframe(tStart: 1, tEnd: 3,
                                          focusRect: CGRect(x: 0, y: 0, width: 960, height: 540),
                                          zoom: 2)]
        state.editorSettings = EditorSettings()
        let data = try isoEncoder().encode(state)
        let decoded = try isoDecoder().decode(ProjectState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.keyframes?.count, 1)
    }

    func testV1ProjectJSONStillDecodes() throws {
        // v1 project.json has no keyframes/editorSettings keys.
        let json = """
        {
            "version": 1,
            "createdAt": "2026-09-15T00:00:00Z",
            "appVersion": "1.0",
            "recordingFile": "recording.mov",
            "eventsFile": "events.json",
            "metaFile": "recording-meta.json"
        }
        """
        let decoded = try isoDecoder().decode(ProjectState.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertNil(decoded.keyframes)
        XCTAssertNil(decoded.editorSettings)
        XCTAssertNil(decoded.webcamFile)
    }

    func testSavePreservesV1FieldsAndWritesV2() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibestudio-v2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("test.vibestudio", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let state = ProjectState(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 appVersion: "1.0",
                                 recordingFile: "recording.mov",
                                 webcamFile: nil,
                                 eventsFile: "events.json",
                                 metaFile: "recording-meta.json")
        try isoEncoder().encode(state).write(to: bundle.appendingPathComponent("project.json"))

        let keyframe = CameraKeyframe(tStart: 0.5, tEnd: 2,
                                      focusRect: CGRect(x: 10, y: 10, width: 100, height: 100),
                                      zoom: 1.8)
        var settings = EditorSettings()
        settings.zoomStyle = .smooth
        try ProjectStore.save(bundleURL: bundle, keyframes: [keyframe], editorSettings: settings)

        let saved = try isoDecoder().decode(ProjectState.self,
                                            from: Data(contentsOf: bundle.appendingPathComponent("project.json")))
        XCTAssertEqual(saved.version, 2)
        XCTAssertEqual(saved.createdAt, state.createdAt)
        XCTAssertEqual(saved.appVersion, "1.0")
        XCTAssertEqual(saved.recordingFile, "recording.mov")
        XCTAssertEqual(saved.keyframes?.first, keyframe)
        XCTAssertEqual(saved.editorSettings?.zoomStyle, .smooth)
    }
}
