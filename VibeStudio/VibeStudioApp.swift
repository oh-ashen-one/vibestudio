import AppKit
import SwiftUI

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

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Never restore windows: headless/dev runs must not block on the
        // "restore windows after crash?" modal before didFinishLaunching.
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let session = RecordingSession()
        session.onRecordingFinished = { url in
            EditorWindowManager.shared.open(url: url)
        }
        self.session = session
        pill = PillWindowController(session: session)
        pill?.showPill()
        hotKey = GlobalHotKey { [weak session] in
            Task { @MainActor in
                session?.toggleRecording()
            }
        }
        handleLaunchArguments()
    }

    /// Dev hook: `VibeStudio -open <path-to-bundle-or-loose-folder>` opens the
    /// editor directly. (With -smokeTest the process never reaches the app —
    /// see main.swift.)
    private func handleLaunchArguments() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "-open"),
              arguments.indices.contains(flagIndex + 1) else { return }
        let url = URL(fileURLWithPath: arguments[flagIndex + 1])
        EditorWindowManager.shared.open(url: url)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        EditorWindowManager.shared.open(url: URL(fileURLWithPath: filename))
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pill?.showPill()
        return false
    }
}
