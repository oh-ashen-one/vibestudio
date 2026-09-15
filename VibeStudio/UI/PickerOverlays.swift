import AppKit
import ScreenCaptureKit

/// Borderless panel that may become key so the pickers can handle Escape.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private func makeOverlayPanel(on screen: NSScreen) -> NSPanel {
    let panel = OverlayPanel(contentRect: screen.frame,
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false)
    panel.level = .screenSaver
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.acceptsMouseMovedEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    return panel
}

// MARK: - Window picker

/// Full-screen transparent overlays (one per display) that highlight the
/// window under the cursor; click selects it, Escape cancels.
@MainActor
final class WindowPickerController {
    private static let excludedBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
    ]

    private var panels: [NSPanel] = []
    private var didFinish = false

    func pickWindow(completion: @escaping (SCWindow?) -> Void) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let ownBundleID = Bundle.main.bundleIdentifier
                let candidates = content.windows.filter { window in
                    guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
                    return bundleID != ownBundleID
                        && !Self.excludedBundleIDs.contains(bundleID)
                        && window.isOnScreen
                        && window.frame.width >= 50
                        && window.frame.height >= 50
                }
                showOverlays(candidates: candidates, completion: completion)
            } catch {
                completion(nil)
            }
        }
    }

    private func showOverlays(candidates: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        guard !candidates.isEmpty else { completion(nil); return }
        NSApp.activate()
        for screen in NSScreen.screens {
            let panel = makeOverlayPanel(on: screen)
            let view = WindowHighlightView(screen: screen, windows: candidates) { [weak self] picked in
                self?.finish(picked, completion: completion)
            }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
    }

    private func finish(_ window: SCWindow?, completion: (SCWindow?) -> Void) {
        guard !didFinish else { return }
        didFinish = true
        for panel in panels { panel.close() }
        panels.removeAll()
        completion(window)
    }
}

private final class WindowHighlightView: NSView {
    private let screen: NSScreen
    private let windows: [SCWindow]
    private let onDone: (SCWindow?) -> Void
    private let primaryHeight: CGFloat
    private var highlighted: SCWindow?

    init(screen: NSScreen, windows: [SCWindow], onDone: @escaping (SCWindow?) -> Void) {
        self.screen = screen
        self.windows = windows
        self.onDone = onDone
        self.primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        let tracking = NSTrackingArea(rect: bounds,
                                      options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                      owner: self,
                                      userInfo: nil)
        addTrackingArea(tracking)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let globalAppKit = CGPoint(x: screen.frame.minX + local.x, y: screen.frame.minY + local.y)
        let cg = CoordinateMapper.appKitPointToCG(globalAppKit, primaryHeight: primaryHeight)
        let hit = windows.first { $0.frame.contains(cg) }
        if hit?.windowID != highlighted?.windowID {
            highlighted = hit
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        onDone(highlighted)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onDone(nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window = highlighted else { return }
        let appKit = CoordinateMapper.cgRectToAppKit(window.frame, primaryHeight: primaryHeight)
        let local = NSRect(x: appKit.minX - screen.frame.minX,
                           y: appKit.minY - screen.frame.minY,
                           width: appKit.width,
                           height: appKit.height)
        let path = NSBezierPath(roundedRect: local.insetBy(dx: -2, dy: -2), xRadius: 8, yRadius: 8)
        NSColor.systemBlue.withAlphaComponent(0.25).setFill()
        path.fill()
        NSColor.systemBlue.setStroke()
        path.lineWidth = 3
        path.stroke()
    }
}

// MARK: - Area picker

/// Full-screen overlays (one per display) where the user drags a selection
/// rect. Calls back with the screen and rect in global AppKit coordinates.
@MainActor
final class AreaSelectionController {
    private var panels: [NSPanel] = []
    private var didFinish = false

    func pickArea(completion: @escaping (NSScreen?, CGRect?) -> Void) {
        NSApp.activate()
        for screen in NSScreen.screens {
            let panel = makeOverlayPanel(on: screen)
            let view = AreaDragView(screen: screen) { [weak self] rect in
                self?.finish(screen: rect == nil ? nil : screen, rect: rect, completion: completion)
            }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
        }
    }

    private func finish(screen: NSScreen?, rect: CGRect?, completion: (NSScreen?, CGRect?) -> Void) {
        guard !didFinish else { return }
        didFinish = true
        for panel in panels { panel.close() }
        panels.removeAll()
        completion(screen, rect)
    }
}

private final class AreaDragView: NSView {
    private let screen: NSScreen
    private let onDone: (CGRect?) -> Void
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    init(screen: NSScreen, onDone: @escaping (CGRect?) -> Void) {
        self.screen = screen
        self.onDone = onDone
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    private var selectionRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(x: min(start.x, current.x),
                      y: min(start.y, current.y),
                      width: abs(current.x - start.x),
                      height: abs(current.y - start.y))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect, rect.width >= 20, rect.height >= 20 else {
            reset()
            onDone(nil)
            return
        }
        let global = CGRect(x: rect.minX + screen.frame.minX,
                            y: rect.minY + screen.frame.minY,
                            width: rect.width,
                            height: rect.height)
        reset()
        onDone(global)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            reset()
            onDone(nil)
        }
    }

    private func reset() {
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let rect = selectionRect else { return }
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.setBlendMode(.clear)
            NSBezierPath(rect: rect).fill()
            context.restoreGState()
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()
    }
}
