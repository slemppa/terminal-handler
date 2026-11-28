import AppKit
import UserNotifications

/// Sound + system notification when Claude starts waiting for Sami.
enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func announce(repo: String, text: String) {
        NSSound(named: "Glass")?.play()
        let content = UNMutableNotificationContent()
        content.title = "\(repo) kysyy"
        content.body = text
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Once per viewing, so Sami knows the phone is looking.
    static func screenShareStarted() {
        let content = UNMutableNotificationContent()
        content.title = "Ruutu jaettu puhelimeen"
        content.body = "Jarvis-sovellus katsoo ja ohjaa Macin näyttöä. Sulje se saarekkeen valikosta."
        let request = UNNotificationRequest(identifier: "screen-share", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
