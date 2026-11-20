import AppKit
import ApplicationServices
import OSLog

/// Closes FluidVoice's expanded Command Mode window after Jarvis took a command.
///
/// FluidVoice opens that window for every Command Mode reply, and it only shows
/// Jarvis's acknowledgement; the real answer is in the island and Satu's voice.
/// There is no setting to turn it off on Macs without a notch, so the island
/// presses its close button ("Close (Escape)") through the Accessibility API.
/// Needs Accessibility permission; asks for it once and otherwise does nothing.
@MainActor
enum FluidVoiceNotch {
    static let bundleID = "com.FluidApp.app"
    /// Tooltip of the window's X button in FluidVoice's NotchCommandOutputExpandedView.
    static let closeHelp = "Close (Escape)"

    private static let log = Logger(subsystem: "fi.slemppa.TerminalHandler", category: "fluidvoice")
    private static var watch: Task<Void, Never>?
    private static var askedTrust = false

    /// Watches for the window for a few seconds and closes it whenever it appears.
    /// FluidVoice opens it after reading the reply, a moment after the request ends.
    static func closeAfterReply() {
        guard UserDefaults.standard.object(forKey: "jarvisCloseFluidVoiceWindow") as? Bool ?? true else { return }
        guard trusted() else { return }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let pid = app.processIdentifier
        watch?.cancel()
        watch = Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                if pressClose(pid: pid) { log.info("closed FluidVoice command window") }
            }
        }
    }

    private static func trusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        if !askedTrust {
            askedTrust = true
            // Value of kAXTrustedCheckOptionPrompt (a C global Swift 6 will not read).
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        return false
    }

    private static func pressClose(pid: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.5)
        var pressed = false
        for window in children(root, kAXWindowsAttribute) {
            if let button = find(in: window, depth: 0) {
                pressed = AXUIElementPerformAction(button, kAXPressAction as CFString) == .success || pressed
            }
        }
        return pressed
    }

    private static func find(in element: AXUIElement, depth: Int) -> AXUIElement? {
        if string(element, kAXRoleAttribute) == kAXButtonRole as String,
           string(element, kAXHelpAttribute) == closeHelp {
            return element
        }
        guard depth < 16 else { return nil }
        for child in children(element, kAXChildrenAttribute) {
            if let found = find(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
