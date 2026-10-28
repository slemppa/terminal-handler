import AppKit
import THCore

/// First-launch offer and menu actions for Claude's hook settings.
enum HookSetup {
    static var helperPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/th-hook").path
    }

    static var command: String { HookInstaller.command(forHelperAt: helperPath) }

    static var isInstalled: Bool {
        HookInstaller.isInstalled(HookInstaller.readSettings(), command: command)
    }

    /// Shows exactly what will be added and installs on confirmation.
    static func offerInstall(force: Bool = false) {
        guard force || (!isInstalled && !UserDefaults.standard.bool(forKey: "declinedHookInstall")) else { return }
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { return }

        let added = HookInstaller.install(into: .object([:]), command: command)
        let alert = NSAlert()
        alert.messageText = "Asennetaanko Claude-hookit?"
        alert.informativeText = """
        Terminal Handler lisää nämä hookit tiedostoon ~/.claude/settings.json. \
        Nykyiset hookit säilyvät, ja tiedostosta otetaan ensin varmuuskopio. \
        Jos sovellus ei ole käynnissä, Claude toimii täsmälleen kuten ennenkin.
        """
        let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 460, height: 220))
        text.string = String(decoding: added.encoded(pretty: true), as: UTF8.self)
        text.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        text.isEditable = false
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Asenna")
        alert.addButton(withTitle: "Ei nyt")

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            install()
        } else {
            UserDefaults.standard.set(true, forKey: "declinedHookInstall")
        }
    }

    static func install() {
        let settings = HookInstaller.readSettings()
        do {
            try HookInstaller.write(HookInstaller.install(into: settings, command: command))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func uninstall() {
        let settings = HookInstaller.readSettings()
        try? HookInstaller.write(HookInstaller.uninstall(from: settings, command: command))
    }
}
