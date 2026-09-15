import AppKit
import SwiftUI

@main
struct VibeStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var session: RecordingSession?
    private var pill: PillWindowController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let session = RecordingSession()
        self.session = session
        pill = PillWindowController(session: session)
        pill?.showPill()
        hotKey = GlobalHotKey { [weak session] in
            Task { @MainActor in
                session?.toggleRecording()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pill?.showPill()
        return false
    }
}
