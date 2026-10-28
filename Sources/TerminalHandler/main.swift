import AppKit
import THCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var island: IslandController?
    private var server: HookServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let island = IslandController(model: model)
        self.island = island
        model.onQuestionArrived = { island.questionArrived() }

        let model = model
        let server = HookServer { envelope, connection in
            model.handle(envelope, connection: connection)
        }
        server.start()
        self.server = server

        model.startPolling()
        Notifier.requestAuthorization()
        HookSetup.offerInstall()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.releaseEverything()
        server?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
