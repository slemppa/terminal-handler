import AppIntents
import SwiftUI

@main
struct JarvisApp: App {
    @State private var session = Session()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { startIfAsked() }
                }
                .onReceive(NotificationCenter.default.publisher(for: .jarvisListen)) { _ in startIfAsked() }
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

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ListenIntent(),
                    phrases: ["\(.applicationName)", "Puhu \(.applicationName)lle", "Kysy \(.applicationName)lta"],
                    shortTitle: "Puhu Jarvisille",
                    systemImageName: "waveform")
    }
}
