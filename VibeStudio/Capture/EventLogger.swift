import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

/// Global event capture via a CGEvent tap (.cghidEventTap, listen-only) on a
/// dedicated run-loop thread, plus NSWorkspace frontmost-window notifications.
/// Requires Input Monitoring (tap) and Accessibility (frontmost window frames).
final class EventLogger: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RecordedEvent] = []
    private let clock: SharedPauseClock
    private var startHostSeconds: Double = 0

    private var tap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
    private var workspaceObserver: NSObjectProtocol?

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 1)
        mach_timebase_info(&info)
        return info
    }()

    static func hostSeconds(forMachTimestamp ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    init(clock: SharedPauseClock) {
        self.clock = clock
    }

    var tapIsActive: Bool { tap != nil }

    func start() {
        lock.lock()
        events.removeAll()
        lock.unlock()
        startHostSeconds = CACurrentMediaTime()
        append(.cursorType(t: 0, name: "arrow"))
        startTap()
        startWorkspaceObserver()
    }

    private func mediaTime(forHostSeconds hostSeconds: Double) -> Double {
        clock.mediaTime(hostSeconds)
    }

    private func append(_ event: RecordedEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func stopAndFlush(to url: URL) throws {
        stopCapture()
        lock.lock()
        let log = EventLog(events: events)
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(log).write(to: url, options: .atomic)
    }

    func stopCapture() {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoop = tapRunLoop,
               let source = CFMachPortCreateRunLoopSource(nil, tap, 0) {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
        }
        if let runLoop = tapRunLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        tap = nil
        tapRunLoop = nil
        tapThread = nil
    }

    // MARK: - Event tap

    private func startTap() {
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .scrollWheel, .keyDown,
        ]
        var mask: CGEventMask = 0
        for type in types {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        let semaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { semaphore.signal(); return }
            let callback: CGEventTapCallBack = { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let logger = Unmanaged<EventLogger>.fromOpaque(userInfo).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = logger.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                logger.handle(event: event, type: type)
                return Unmanaged.passUnretained(event)
            }
            if let tap = CGEvent.tapCreate(tap: .cghidEventTap,
                                           place: .headInsertEventTap,
                                           options: .listenOnly,
                                           eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                self.tap = tap
                let runLoop = CFRunLoopGetCurrent()
                self.tapRunLoop = runLoop
                let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(runLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                semaphore.signal()
                CFRunLoopRun()
            } else {
                semaphore.signal()
            }
        }
        thread.name = "dev.vibestudio.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
        semaphore.wait()
    }

    private func handle(event: CGEvent, type: CGEventType) {
        if clock.isPaused { return }
        let hostSeconds = Self.hostSeconds(forMachTimestamp: event.timestamp)
        let t = mediaTime(forHostSeconds: hostSeconds)
        guard t >= 0 else { return }
        let location = event.location

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            append(.cursorMove(t: t, x: location.x, y: location.y))
        case .leftMouseDown:
            append(.click(t: t, x: location.x, y: location.y, button: "left"))
        case .rightMouseDown:
            append(.click(t: t, x: location.x, y: location.y, button: "right"))
        case .otherMouseDown:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            append(.click(t: t, x: location.x, y: location.y, button: "other(\(number))"))
        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            append(.scroll(t: t, dx: dx, dy: dy))
        case .keyDown:
            append(.key(t: t, modifiers: Self.modifierNames(event.flags),
                        key: Self.keyString(event), keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode))))
        default:
            break
        }
    }

    static func modifierNames(_ flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("cmd") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskControl) { names.append("control") }
        return names
    }

    static func keyString(_ event: CGEvent) -> String {
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return "" }
        var chars = [UniChar](repeating: 0, count: length)
        event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &chars)
        return String(utf16CodeUnits: chars, count: length)
    }

    // MARK: - Frontmost window

    private func startWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if self.clock.isPaused { return }
            let t = self.mediaTime(forHostSeconds: CACurrentMediaTime())
            let frame = Self.frontmostWindowFrame(pid: app.processIdentifier)
            self.append(.frontmostWindow(t: t, frame: frame, appBundleID: app.bundleIdentifier))
        }
    }

    /// AX position/size are already in global CG points (top-left origin).
    static func frontmostWindowFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue else { return nil }
        let window = windowValue as! AXUIElement
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
