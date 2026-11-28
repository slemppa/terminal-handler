import AppIntents
import SwiftUI

@main
struct JarvisApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { startIfAsked() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .jarvisListen)) { _ in startIfAsked() }
                .onReceive(NotificationCenter.default.publisher(for: .jarvisScreen)) { _ in session.showScreen = true }
        }
    }

    /// Siri ("Hei Siri, Jarvis") opens the app and asks it to listen.
    private func startIfAsked() {
        guard ListenRequest.take() else { return }
        session.start()
    }
}

extension Notification.Name {
    static let jarvisListen = Notification.Name("jarvisListen")
    static let jarvisScreen = Notification.Name("jarvisScreen")
}

enum ListenRequest {
    private static var pending = false
    @MainActor static func post() {
        pending = true
        NotificationCenter.default.post(name: .jarvisListen, object: nil)
    }
    @MainActor static func take() -> Bool {
        defer { pending = false }
        return pending
    }
}

struct ListenIntent: AppIntent {
    static let title: LocalizedStringResource = "Puhu Jarvisille"
    static let description = IntentDescription("Avaa Jarvisin kuuntelemaan komentoa.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ListenRequest.post()
        return .result()
    }
}

struct ScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Näytä Macin ruutu"
    static let description = IntentDescription("Avaa Macin näytön Jarvisiin, ja voit ohjata sitä puhelimella.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .jarvisScreen, object: nil)
        return .result()
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ListenIntent(),
                    phrases: ["\(.applicationName)", "Puhu \(.applicationName)lle", "Kysy \(.applicationName)lta"],
                    shortTitle: "Puhu Jarvisille",
                    systemImageName: "waveform")
        AppShortcut(intent: ScreenIntent(),
                    phrases: ["\(.applicationName), näytä ruutu", "\(.applicationName), näytä Macin ruutu"],
                    shortTitle: "Macin ruutu",
                    systemImageName: "display")
    }
}
