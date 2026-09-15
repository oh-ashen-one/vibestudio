import XCTest
@testable import VibeStudio

final class ExportMathTests: XCTestCase {
    func testWebcamSyncOffset() {
        // Webcam writer started 0.25s AFTER the screen writer.
        XCTAssertEqual(ExportRenderer.webcamMediaTime(forScreenTime: 1.0,
                                                      screenFirstHostSeconds: 100.0,
                                                      webcamFirstHostSeconds: 100.25),
                       0.75, accuracy: 1e-9)
        // Before the webcam started: clamps to 0.
        XCTAssertEqual(ExportRenderer.webcamMediaTime(forScreenTime: 0.1,
                                                      screenFirstHostSeconds: 100.0,
                                                      webcamFirstHostSeconds: 100.25),
                       0, accuracy: 1e-9)
        // Webcam started earlier: negative offset shifts the other way.
        XCTAssertEqual(ExportRenderer.webcamMediaTime(forScreenTime: 1.0,
                                                      screenFirstHostSeconds: 100.5,
                                                      webcamFirstHostSeconds: 100.0),
                       1.5, accuracy: 1e-9)
        // Missing offsets behave as zero.
        XCTAssertEqual(ExportRenderer.webcamMediaTime(forScreenTime: 2.0,
                                                      screenFirstHostSeconds: nil,
                                                      webcamFirstHostSeconds: nil),
                       2.0, accuracy: 1e-9)
    }

    func testFrameTimesTrimmedRange() {
        let times = ExportRenderer.frameTimes(trimStart: 5, trimEnd: 10, fps: 60)
        XCTAssertEqual(times.count, 300)
        XCTAssertEqual(times.first ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(times.last ?? -1, 5 + 299.0 / 60.0, accuracy: 1e-9)
    }

    func testFrameTimesMinimumOneFrame() {
        let times = ExportRenderer.frameTimes(trimStart: 1, trimEnd: 1, fps: 60)
        XCTAssertEqual(times.count, 1)
    }

    func testPresetOutputSizes() {
        let source = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(ExportPreset.p1080_60.outputSize(aspect: .a16x9, sourceSize: source, sourceFPS: 60),
                       CGSize(width: 1920, height: 1080))
        XCTAssertEqual(ExportPreset.p1080_60.outputSize(aspect: .a9x16, sourceSize: source, sourceFPS: 60),
                       CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ExportPreset.p1080_30.outputSize(aspect: .a1x1, sourceSize: source, sourceFPS: 60),
                       CGSize(width: 1080, height: 1080))
        XCTAssertEqual(ExportPreset.sourceNative.outputSize(aspect: .a16x9, sourceSize: source, sourceFPS: 60),
                       source)
        // 4K not allowed for a 1080p source.
        XCTAssertFalse(ExportPreset.p4k_60.isAllowed(sourceSize: source))
        XCTAssertTrue(ExportPreset.p4k_60.isAllowed(sourceSize: CGSize(width: 3840, height: 2160)))
        // All sizes even (H.264 requirement).
        for aspect in ExportAspect.allCases {
            let size = ExportPreset.p1080_30.outputSize(aspect: aspect, sourceSize: source, sourceFPS: 60)
            XCTAssertEqual(Int(size.width) % 2, 0)
            XCTAssertEqual(Int(size.height) % 2, 0)
        }
    }

    func testEditorSettingsTrimRoundTrip() throws {
        var settings = EditorSettings()
        settings.trimStart = 5
        settings.trimEnd = 10
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(EditorSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.trimStart, 5)
        XCTAssertEqual(decoded.trimEnd, 10)
    }

    func testEditorSettingsWithoutTrimStillDecodes() throws {
        // Pre-trim project.json (Phase 3 era) has no trim keys.
        let json = """
        {"cursorSize":1.0,"smoothnessPreset":"standard","zoomStyle":"focused",
         "motionBlurStrength":0.5,"background":{"kind":"preset","id":"midnight"},
         "padding":0.08,"cornerRadius":0.04,"shadowEnabled":true,"cameraLayout":"screenOnly"}
        """
        let decoded = try JSONDecoder().decode(EditorSettings.self, from: Data(json.utf8))
        XCTAssertNil(decoded.trimStart)
        XCTAssertNil(decoded.trimEnd)
        XCTAssertEqual(decoded.zoomStyle, .focused)
    }

    func testProjectStateRoundTripWithTrimmedSettings() throws {
        var state = ProjectState(createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                 appVersion: "1.0",
                                 recordingFile: "recording.mov",
                                 webcamFile: nil,
                                 eventsFile: "events.json",
                                 metaFile: "recording-meta.json")
        state.version = 2
        var settings = EditorSettings()
        settings.trimStart = 3.5
        state.editorSettings = settings
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ProjectState.self, from: data)
        XCTAssertEqual(decoded.editorSettings?.trimStart, 3.5)
        XCTAssertEqual(decoded, state)
    }
}
