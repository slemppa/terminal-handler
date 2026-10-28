import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon's `RegisterEventHotKey`, which needs no
/// Accessibility permission.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        unregister(id: id)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5448_4B59), id: id) // "THKY"
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return }
        refs[id] = ref
        actions[id] = action
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotkeyCenter.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotkeyDefaults {
    /// ⌃⌥Space unless overridden with
    /// `defaults write fi.slemppa.TerminalHandler hotkeyKeyCode -int <code>` (and `hotkeyModifiers`).
    static var toggle: (keyCode: UInt32, modifiers: UInt32) {
        let defaults = UserDefaults.standard
        let code = defaults.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_Space
        let mods = defaults.object(forKey: "hotkeyModifiers") as? Int ?? (controlKey | optionKey)
        return (UInt32(code), UInt32(mods))
    }

    static let digitKeyCodes: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                       kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}
