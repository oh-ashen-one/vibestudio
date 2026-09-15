import AppKit
import ScreenCaptureKit

/// Borderless panel that may become key so the pickers can handle Escape.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private func makeOverlayPanel(on screen: NSScreen) -> NSPanel {
    // NB: on macOS 26 a transparent [.borderless] panel never composites its
    // content (verified live: opaque renders, clear+non-opaque renders
    // nothing). Adding .nonactivatingPanel + floating makes alpha work.
    let panel = OverlayPanel(contentRect: screen.frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
    panel.isFloatingPanel = true
    panel.level = .screenSaver
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.ignoresMouseEvents = false
    panel.acceptsMouseMovedEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
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

    static func log(_ message: String) {
        FileHandle.standardError.write(Data(("[VibeStudio/picker] \(message)\n".utf8)))
    }

    func pickWindow(completion: @escaping (SCWindow?) -> Void) {
        Self.log("pickWindow entered; preflight screen capture: \(CGPreflightScreenCaptureAccess())")
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                Self.log("SCShareableContent: \(content.windows.count) windows, \(content.displays.count) displays")
                let ownBundleID = Bundle.main.bundleIdentifier
                let candidates = content.windows.filter { window in
                    guard let bundleID = window.owningApplication?.bundleIdentifier else { return false }
                    return bundleID != ownBundleID
                        && !Self.excludedBundleIDs.contains(bundleID)
                        && window.isOnScreen
                        && window.frame.width >= 50
                        && window.frame.height >= 50
                }
                Self.log("candidates after filter: \(candidates.count)")
                showOverlays(candidates: candidates, completion: completion)
            } catch {
                Self.log("SCShareableContent FAILED: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    private func showOverlays(candidates: [SCWindow], completion: @escaping (SCWindow?) -> Void) {
        guard !candidates.isEmpty else { Self.log("no candidates — aborting"); completion(nil); return }
        NSApp.activate()
        for screen in NSScreen.screens {
            let panel = makeOverlayPanel(on: screen)
            let view = WindowHighlightView(screen: screen, windows: candidates) { [weak self] picked in
                self?.finish(picked, completion: completion)
            }
            panel.contentView = view
            panel.makeKeyAndOrderFront(nil)
            panels.append(panel)
            Self.log("overlay panel shown on \(screen.frame) visible=\(panel.isVisible) level=\(panel.level.rawValue) hidesOnDeactivate=\(panel.hidesOnDeactivate)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            for panel in self.panels {
                Self.log("t+3s panel visible=\(panel.isVisible) onScreen=\(panel.isOnActiveSpace) appActive=\(NSApp.isActive)")
            }
        }
    }

    private func finish(_ window: SCWindow?, completion: (SCWindow?) -> Void) {
        guard !didFinish else { Self.log("finish called AGAIN — ignored"); return }
        didFinish = true
        Self.log("finish picked=\(window?.windowID ?? 0)")
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
        // NB: borderless non-opaque panels on macOS 26 do not composite
        // non-layer-backed content views at all (verified live) — must be
        // layer-backed for draw(_:) to reach the screen.
        wantsLayer = true
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
        WindowPickerController.log("highlight view mouseDown highlighted=\(highlighted?.windowID ?? 0)")
        onDone(highlighted)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            WindowPickerController.log("escape pressed")
            onDone(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dim the screen so picker mode is unmistakable, plus the instruction.
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        drawLabel("Click a window to record it · Esc to cancel",
                  at: CGPoint(x: (bounds.midX - 190).rounded(.down), y: bounds.maxY - 64))

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

        let appName = window.owningApplication?.applicationName
        let title = window.title?.isEmpty == false ? window.title! : (appName ?? "this window")
        let labelPoint = CGPoint(x: max(local.minX, 8), y: min(local.maxY + 10, bounds.maxY - 40))
        drawLabel("Record “\(title)”", at: labelPoint)
    }

    private func drawLabel(_ text: String, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 15),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: point.x, y: point.y,
                          width: textSize.width + 28, height: textSize.height + 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        path.fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + 8),
                                withAttributes: attributes)
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
        WindowPickerController.log("pickArea entered, screens=\(NSScreen.screens.count)")
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
        WindowPickerController.log("area finish rect=\(String(describing: rect))")
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
        wantsLayer = true
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
        drawInstruction("Drag to select an area to record · Esc to cancel")
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
        drawInstruction("\(Int(rect.width)) × \(Int(rect.height))", at: CGPoint(x: rect.minX, y: max(rect.minY - 34, 6)))
    }

    private func drawInstruction(_ text: String, at point: CGPoint? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 15),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let x = point?.x ?? (bounds.midX - textSize.width / 2 - 14).rounded(.down)
        let y = point?.y ?? bounds.maxY - 64
        let rect = CGRect(x: x, y: y, width: textSize.width + 28, height: textSize.height + 16)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 14, y: rect.minY + 8),
                                withAttributes: attributes)
    }
}

/// Brief on-screen confirmation that a source was selected: an accent border
/// around the display (or rect) with a label, auto-dismissing. Mouse-transparent.
@MainActor
final class SelectionFlashController {
    private var panels: [NSPanel] = []

    func flash(on screen: NSScreen, text: String, duration: Double = 1.4) {
        let panel = makeOverlayPanel(on: screen)
        panel.ignoresMouseEvents = true
        panel.contentView = SelectionFlashView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                               text: text)
        panel.orderFrontRegardless()
        panels.append(panel)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak panel] in
            panel?.close()
            self?.panels.removeAll { $0 === panel }
        }
    }
}

private final class SelectionFlashView: NSView {
    private let text: String

    init(frame frameRect: NSRect, text: String) {
        self.text = text
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12)
        NSColor.systemBlue.setStroke()
        border.lineWidth = 6
        border.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: bounds.midX - textSize.width / 2 - 16,
                          y: bounds.maxY - 72,
                          width: textSize.width + 32, height: textSize.height + 18)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 16, y: rect.minY + 9),
                                withAttributes: attributes)
    }
}
