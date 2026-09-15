import AppKit
import SwiftUI

/// Opens .vibestudio bundles (or loose Phase-1 folders) in editor windows.
@MainActor
final class EditorWindowManager {
    static let shared = EditorWindowManager()

    private var windows: [URL: NSWindow] = [:]

    func open(url: URL) {
        let key = url.standardizedFileURL
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        print("[VibeStudio] opening editor for \(key.path)")
        let viewModel = EditorViewModel(url: key)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = key.lastPathComponent
        window.contentView = NSHostingView(rootView: EditorView(viewModel: viewModel))
        window.center()
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window,
                                               queue: .main) { [weak self] note in
            guard let closing = note.object as? NSWindow else { return }
            Task { @MainActor in
                self?.windows = self?.windows.filter { $0.value != closing } ?? [:]
            }
        }
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
