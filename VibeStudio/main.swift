import Foundation

// Custom entry point: dev/CI hooks run synchronously and exit WITHOUT
// bootstrapping AppKit/SwiftUI, so they work in headless sessions (no
// WindowServer, no window-restoration modals). Everything else starts the
// normal SwiftUI app.
//
//   VibeStudio -open <bundle-or-folder> -smokeTest
//   VibeStudio -open <bundle> -export <out.mp4> [-aspect 16:9|9:16|1:1]
//              [-preset native|1080p60|1080p30|4k60] [-range start,end]

let arguments = CommandLine.arguments

func argumentValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

if arguments.contains("-smokeTest") {
    guard let path = argumentValue("-open") else {
        FileHandle.standardError.write(Data("[smoke] usage: VibeStudio -open <bundle-or-loose-folder> -smokeTest\n".utf8))
        exit(2)
    }
    exit(DevSmokeTest.run(url: URL(fileURLWithPath: path)))
}

if let exportPath = argumentValue("-export") {
    guard let openPath = argumentValue("-open") else {
        FileHandle.standardError.write(Data("[export] usage: VibeStudio -open <bundle> -export <out.mp4> [-aspect 9:16] [-preset 1080p60] [-range a,b]\n".utf8))
        exit(2)
    }
    let aspect: ExportAspect
    switch argumentValue("-aspect") ?? "16:9" {
    case "16:9": aspect = .a16x9
    case "9:16": aspect = .a9x16
    case "1:1": aspect = .a1x1
    default:
        FileHandle.standardError.write(Data("[export] unknown aspect\n".utf8))
        exit(2)
    }
    let preset: ExportPreset
    switch argumentValue("-preset") ?? "native" {
    case "native": preset = .sourceNative
    case "1080p60": preset = .p1080_60
    case "1080p30": preset = .p1080_30
    case "4k60": preset = .p4k_60
    default:
        FileHandle.standardError.write(Data("[export] unknown preset\n".utf8))
        exit(2)
    }
    var trimRange: ClosedRange<Double>?
    if let rangeArg = argumentValue("-range") {
        let parts = rangeArg.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > parts[0] else {
            FileHandle.standardError.write(Data("[export] -range expects start,end in seconds\n".utf8))
            exit(2)
        }
        trimRange = parts[0]...parts[1]
    }

    let config = ExportConfiguration(bundleURL: URL(fileURLWithPath: openPath),
                                     outputURL: URL(fileURLWithPath: exportPath),
                                     preset: preset,
                                     aspect: aspect,
                                     trimRange: trimRange)
    let semaphore = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    let progressBox = CLIProgressBox()
    Task {
        do {
            let result = try await ExportRenderer.run(configuration: config, progress: { fraction in
                progressBox.report(fraction)
            })
            FileHandle.standardError.write(Data("[export] done: \(result.outputURL.lastPathComponent) duration=\(String(format: "%.2f", result.duration))s frames=\(result.frameCount) size=\(result.fileSize) bytes\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("[export] failed: \(error.localizedDescription)\n".utf8))
            exitCode = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(exitCode)
}

private final class CLIProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lastReported = -1

    func report(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        let percent = Int((fraction * 100).rounded(.down))
        if percent != lastReported, percent % 10 == 0 {
            lastReported = percent
            FileHandle.standardError.write(Data("[export] \(percent)%\n".utf8))
        }
    }
}

VibeStudioApp.main()
