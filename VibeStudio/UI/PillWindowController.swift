import AppKit
import Combine
import SwiftUI

/// The floating pill: borderless, non-activating, status-bar level, visible on
/// all spaces, bottom-center of the main screen. Re-centers when the pill's
/// content size changes between phases.
@MainActor
final class PillWindowController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private var cancellables: Set<AnyCancellable> = []
    private var userMovedPill = false

    init(session: RecordingSession) {
        hostingView = NSHostingView(rootView: AnyView(PillView().environmentObject(session)))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hostingView

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                               object: panel,
                                               queue: .main) { [weak self] _ in
            Task { @MainActor in self?.userMovedPill = true }
        }
        session.$phase
            .removeDuplicates { String(describing: $0) == String(describing: $1) }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reposition(force: true) }
            .store(in: &cancellables)
    }

    func showPill() {
        reposition(force: true)
        panel.orderFrontRegardless()
    }

    private func reposition(force: Bool) {
        guard force || !userMovedPill else { return }
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard size.width > 0, size.height > 0, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 20)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}
