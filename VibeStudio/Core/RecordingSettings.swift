import Foundation

struct RecordingSettings: Codable, Equatable {
    enum ResolutionCap: String, Codable, CaseIterable {
        case native
        case p1080
        case p4k
    }

    var resolutionCap: ResolutionCap = .native
    var frameRate: Int = 60
    var countdownEnabled: Bool = false
    var hideDesktopIcons: Bool = false
    var hotkeyDisplay: String = "⌘⇧2"
    var captureSystemAudio: Bool = true
    var selectedCameraID: String?
    var selectedMicID: String?
    var sourceMode: String = "display"
}

enum SettingsStore {
    static let key = "recordingSettings.v1"

    static func load(defaults: UserDefaults = .standard) -> RecordingSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data) else {
            return RecordingSettings()
        }
        return settings
    }

    static func save(_ settings: RecordingSettings, defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(settings), forKey: key)
    }
}
