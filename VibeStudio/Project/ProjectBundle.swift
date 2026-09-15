import Foundation

/// project.json inside a .vibestudio bundle. v2 adds the zoom keyframe
/// timeline and inspector settings; both are optional so v1 files decode.
struct ProjectState: Codable, Equatable {
    var version: Int = 1
    var createdAt: Date
    var appVersion: String
    var recordingFile: String
    var webcamFile: String?
    var eventsFile: String
    var metaFile: String
    var keyframes: [CameraKeyframe]?
    var editorSettings: EditorSettings?
}

struct LoadedProject: Equatable {
    var bundleURL: URL
    var state: ProjectState
    var meta: RecordingMeta
    var events: [RecordedEvent]

    var recordingURL: URL { bundleURL.appendingPathComponent(state.recordingFile) }
    var webcamURL: URL? { state.webcamFile.map { bundleURL.appendingPathComponent($0) } }
}

enum ProjectStoreError: Error, Equatable {
    case missingFile(String)
}

/// .vibestudio bundle (package directory) import/load.
enum ProjectStore {
    static let bundleExtension = "vibestudio"
    static let recordingFile = "recording.mov"
    static let webcamFile = "webcam.mov"
    static let eventsFile = "events.json"
    static let metaFile = "recording-meta.json"
    static let projectFile = "project.json"

    /// Converts a loose Phase-1 output folder into a .vibestudio bundle.
    /// Default destination: `<folder>.vibestudio` next to the source folder.
    @discardableResult
    static func importLooseFolder(_ folder: URL,
                                  to destination: URL? = nil,
                                  fileManager: FileManager = .default) throws -> URL {
        for name in [recordingFile, eventsFile, metaFile] {
            guard fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) else {
                throw ProjectStoreError.missingFile(name)
            }
        }
        let bundle = destination ?? folder.deletingLastPathComponent()
            .appendingPathComponent("\(folder.lastPathComponent).\(bundleExtension)", isDirectory: true)
        if fileManager.fileExists(atPath: bundle.path) {
            try fileManager.removeItem(at: bundle)
        }
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)

        var files = [recordingFile, eventsFile, metaFile]
        let hasWebcam = fileManager.fileExists(atPath: folder.appendingPathComponent(webcamFile).path)
        if hasWebcam { files.append(webcamFile) }
        for name in files {
            try fileManager.copyItem(at: folder.appendingPathComponent(name),
                                     to: bundle.appendingPathComponent(name))
        }

        let state = ProjectState(createdAt: Date(),
                                 appVersion: Bundle.main.appVersion,
                                 recordingFile: recordingFile,
                                 webcamFile: hasWebcam ? webcamFile : nil,
                                 eventsFile: eventsFile,
                                 metaFile: metaFile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: bundle.appendingPathComponent(projectFile), options: .atomic)
        return bundle
    }

    static func load(bundleURL: URL) throws -> LoadedProject {
        let stateDecoder = JSONDecoder()
        stateDecoder.dateDecodingStrategy = .iso8601
        let state = try stateDecoder.decode(ProjectState.self,
                                            from: Data(contentsOf: bundleURL.appendingPathComponent(projectFile)))

        let metaDecoder = JSONDecoder()
        metaDecoder.dateDecodingStrategy = .iso8601
        let meta = try metaDecoder.decode(RecordingMeta.self,
                                          from: Data(contentsOf: bundleURL.appendingPathComponent(state.metaFile)))

        let log = try JSONDecoder().decode(EventLog.self,
                                           from: Data(contentsOf: bundleURL.appendingPathComponent(state.eventsFile)))
        return LoadedProject(bundleURL: bundleURL, state: state, meta: meta, events: log.events)
    }

    /// Persists keyframes + inspector settings into an existing bundle's
    /// project.json, preserving the v1 fields.
    static func save(bundleURL: URL,
                     keyframes: [CameraKeyframe],
                     editorSettings: EditorSettings) throws {
        let stateDecoder = JSONDecoder()
        stateDecoder.dateDecodingStrategy = .iso8601
        var state = try stateDecoder.decode(ProjectState.self,
                                            from: Data(contentsOf: bundleURL.appendingPathComponent(projectFile)))
        state.version = 2
        state.keyframes = keyframes
        state.editorSettings = editorSettings
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: bundleURL.appendingPathComponent(projectFile), options: .atomic)
    }
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
