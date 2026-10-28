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
}
