import AppKit

/// Menu-bar (top-right) presence so the app is always reachable and quittable,
/// even though the main UI is a floating pill.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private weak var session: RecordingSession?
    private weak var pill: PillWindowController?

    init(session: RecordingSession, pill: PillWindowController) {
        self.session = session
        self.pill = pill
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "VibeStudio")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show Pill", action: #selector(showPill), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let recordItem = NSMenuItem(title: "Start / Stop Recording", action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open Recordings Folder", action: #selector(openRecordings), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit VibeStudio", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func showPill() {
        pill?.showPill()
        NSApp.activate()
    }

    @objc private func toggleRecording() {
        Task { @MainActor in
            self.session?.toggleRecording()
        }
    }

    @objc private func openRecordings() {
        let dir = OutputLocation.baseFolder()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
