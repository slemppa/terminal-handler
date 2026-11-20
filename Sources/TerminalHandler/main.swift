import AppKit
import THCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var island: IslandController?
    private var server: HookServer?
    private var jarvisServer: JarvisServer?

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

        let jarvis = model.jarvis
        let jarvisServer = JarvisServer(port: JarvisSettings.port, apiKey: { JarvisSettings.requiredKey }) { transcript in
            jarvis.submit(transcript)
        }
        JarvisSettings.listening = jarvisServer.start()
        self.jarvisServer = jarvisServer

        model.startPolling()
        Notifier.requestAuthorization()
        HookSetup.offerInstall()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.releaseEverything()
        model.jarvis.cancel()
        server?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
