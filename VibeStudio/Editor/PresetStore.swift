import Foundation

/// Named inspector presets stored as JSON in Application Support (no network).
/// Sharing = copy/paste the same JSON via the clipboard.
struct SettingsPreset: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var settings: EditorSettings
    var createdAt: Date
}

enum PresetStoreError: Error {
    case invalidJSON
    case invalidName
}

enum PresetStore {
    static func defaultDirectory(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: true)
        return support.appendingPathComponent("VibeStudio/Presets", isDirectory: true)
    }

    static func save(_ preset: SettingsPreset,
                     in directory: URL,
                     fileManager: FileManager = .default) throws {
        guard !preset.name.isEmpty, !preset.name.contains("/") else { throw PresetStoreError.invalidName }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(preset).write(to: fileURL(for: preset.name, in: directory), options: .atomic)
    }

    static func list(in directory: URL, fileManager: FileManager = .default) -> [SettingsPreset] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SettingsPreset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    static func delete(name: String, in directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.removeItem(at: fileURL(for: name, in: directory))
    }

    static func json(for settings: EditorSettings) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        guard let string = String(data: data, encoding: .utf8) else { throw PresetStoreError.invalidJSON }
        return string
    }

    static func settings(fromJSON string: String) -> EditorSettings? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditorSettings.self, from: data)
    }

    private static func fileURL(for name: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(name).json")
    }
}
