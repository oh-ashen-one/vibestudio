import Foundation

// Custom entry point: -smokeTest runs a synchronous load check and exits
// WITHOUT bootstrapping AppKit/SwiftUI, so it works in headless sessions
// (no WindowServer, no window-restoration modals). Everything else starts
// the normal SwiftUI app.
if CommandLine.arguments.contains("-smokeTest") {
    let arguments = CommandLine.arguments
    guard let flagIndex = arguments.firstIndex(of: "-open"),
          arguments.indices.contains(flagIndex + 1) else {
        print("[smoke] usage: VibeStudio -open <bundle-or-loose-folder> -smokeTest")
        exit(2)
    }
    exit(DevSmokeTest.run(url: URL(fileURLWithPath: arguments[flagIndex + 1])))
}

VibeStudioApp.main()
