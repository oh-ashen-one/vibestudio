import Foundation

enum OutputLocation {
    static func baseFolder(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeStudio", isDirectory: true)
    }

    /// Creates ~/Movies/VibeStudio/<yyyy-MM-dd_HH-mm-ss>/ for one recording session.
    static func newRecordingFolder(fileManager: FileManager = .default,
                                   now: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = baseFolder(fileManager: fileManager)
            .appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
