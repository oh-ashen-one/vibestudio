import XCTest
@testable import VibeStudio

final class RecordingSettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "dev.vibestudio.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsWhenNothingStored() {
        let settings = SettingsStore.load(defaults: defaults)
        XCTAssertEqual(settings, RecordingSettings())
        XCTAssertEqual(settings.frameRate, 60)
        XCTAssertEqual(settings.resolutionCap, .native)
        XCTAssertFalse(settings.countdownEnabled)
        XCTAssertFalse(settings.hideDesktopIcons)
        XCTAssertEqual(settings.hotkeyDisplay, "⌘⇧2")
        XCTAssertTrue(settings.captureSystemAudio)
    }

    func testPersistenceRoundTrip() {
        var settings = RecordingSettings()
        settings.resolutionCap = .p1080
        settings.frameRate = 30
        settings.countdownEnabled = true
        settings.hideDesktopIcons = true
        settings.captureSystemAudio = false
        settings.selectedCameraID = "camera-uid-1"
        settings.selectedMicID = "mic-uid-1"
        settings.sourceMode = "window"

        SettingsStore.save(settings, defaults: defaults)
        let loaded = SettingsStore.load(defaults: defaults)
        XCTAssertEqual(loaded, settings)
    }

    func testCorruptedDataFallsBackToDefaults() {
        defaults.set(Data([0xFF, 0x00, 0x01]), forKey: SettingsStore.key)
        XCTAssertEqual(SettingsStore.load(defaults: defaults), RecordingSettings())
    }
}
