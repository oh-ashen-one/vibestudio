import XCTest
@testable import VibeStudio

final class PresetStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibestudio-presets-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func sampleSettings() -> EditorSettings {
        var settings = EditorSettings()
        settings.cursorSize = 1.7
        settings.zoomStyle = .smooth
        settings.motionBlurStrength = 0.8
        settings.background = .custom(startHex: "#102030", endHex: "#000000")
        settings.hideStaticCursor = true
        return settings
    }

    func testSaveListDeleteRoundTrip() throws {
        let preset = SettingsPreset(name: "demo", settings: sampleSettings(),
                                    createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try PresetStore.save(preset, in: tempDir)
        let listed = PresetStore.list(in: tempDir)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first, preset)
        XCTAssertEqual(listed.first?.settings.cursorSize, 1.7)
        XCTAssertEqual(listed.first?.settings.hideStaticCursor, true)

        try PresetStore.delete(name: "demo", in: tempDir)
        XCTAssertTrue(PresetStore.list(in: tempDir).isEmpty)
    }

    func testClipboardJSONRoundTrip() throws {
        let settings = sampleSettings()
        let json = try PresetStore.json(for: settings)
        XCTAssertTrue(json.contains("\"cursorSize\""))
        let restored = PresetStore.settings(fromJSON: json)
        XCTAssertEqual(restored, settings)
        XCTAssertNil(PresetStore.settings(fromJSON: "not json at all"))
    }

    func testInvalidNameRejected() {
        XCTAssertThrowsError(try PresetStore.save(SettingsPreset(name: "a/b",
                                                                 settings: EditorSettings(),
                                                                 createdAt: Date()),
                                                  in: tempDir))
    }
}

final class GIFWriterTests: XCTestCase {
    private var tempFile: URL!

    override func setUp() {
        super.setUp()
        tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).gif")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempFile)
        super.tearDown()
    }

    func testMedianCutPalette() {
        // Two dominant colors must survive quantization.
        var pixels: [MedianCut.Pixel] = []
        for _ in 0..<100 { pixels.append(MedianCut.Pixel(r: 255, g: 0, b: 0)) }
        for _ in 0..<100 { pixels.append(MedianCut.Pixel(r: 0, g: 0, b: 255)) }
        let palette = MedianCut.palette(from: pixels, maxColors: 256)
        XCTAssertFalse(palette.isEmpty)
        XCTAssertLessThanOrEqual(palette.count, 256)
        let hasRed = palette.contains { $0.r > 200 && $0.g < 60 && $0.b < 60 }
        let hasBlue = palette.contains { $0.b > 200 && $0.r < 60 && $0.g < 60 }
        XCTAssertTrue(hasRed, "palette lost red: \(palette)")
        XCTAssertTrue(hasBlue, "palette lost blue: \(palette)")
    }

    func testGIFWriterProducesValidFile() {
        let palette = [MedianCut.Pixel(r: 255, g: 0, b: 0),
                       MedianCut.Pixel(r: 0, g: 255, b: 0),
                       MedianCut.Pixel(r: 0, g: 0, b: 255)]
        guard let writer = GIFWriter(url: tempFile, palette: palette, frameCount: 3) else {
            XCTFail("GIFWriter init failed")
            return
        }
        // 4x2 BGRA frames: red, green, blue.
        let width = 4, height = 2
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        func fill(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
            for i in 0..<(width * height) {
                bytes[i * 4] = b
                bytes[i * 4 + 1] = g
                bytes[i * 4 + 2] = r
                bytes[i * 4 + 3] = 255
            }
        }
        fill(255, 0, 0)
        bytes.withUnsafeBytes { p in writer.addFrame(bgra: p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                     width: width, height: height,
                                                     bytesPerRow: width * 4, delay: 0.1) }
        fill(0, 255, 0)
        bytes.withUnsafeBytes { p in writer.addFrame(bgra: p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                     width: width, height: height,
                                                     bytesPerRow: width * 4, delay: 0.1) }
        fill(0, 0, 255)
        bytes.withUnsafeBytes { p in writer.addFrame(bgra: p.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                     width: width, height: height,
                                                     bytesPerRow: width * 4, delay: 0.1) }
        XCTAssertTrue(writer.finalize())

        let data = try! Data(contentsOf: tempFile)
        // ImageIO may emit GIF87a or GIF89a depending on extensions present.
        XCTAssertTrue(data.starts(with: Data("GIF8".utf8)))
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        XCTAssertEqual(CGImageSourceGetCount(source), 3)
    }
}
