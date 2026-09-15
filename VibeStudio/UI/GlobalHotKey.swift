import Carbon
import Foundation

/// Registers the global record hotkey (⌘⇧2) via Carbon RegisterEventHotKey,
/// which works regardless of which app is frontmost and without Input
/// Monitoring permission.
final class GlobalHotKey {
    private static let signature: OSType = 0x5642_4953 // 'VBIS'

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let handler: () -> Void

    init(keyCode: UInt32 = UInt32(kVK_ANSI_2),
         modifiers: UInt32 = UInt32(cmdKey | shiftKey),
         handler: @escaping () -> Void) {
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),
                            hotKeyEventCallback,
                            1,
                            &eventType,
                            userData,
                            &eventHandler)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    fileprivate func fire() {
        let action = handler
        DispatchQueue.main.async { action() }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

private func hotKeyEventCallback(nextHandler: EventHandlerCallRef?,
                                 event: EventRef?,
                                 userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    hotKey.fire()
    return noErr
}
