import Foundation
import Observation

/// One exchange at a time: listen or type → send → follow the job → answer.
/// A spoken command is answered aloud; a typed one is answered on screen only.
@MainActor
@Observable
final class Session {
    enum Phase: Equatable {
        case idle
        case listening
        case sending
        case working(String?)
        case prompt(question: String, options: [String])
        case speaking
        case failed(String)
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var command: String
        var reply: String
        var failed: Bool
        var date = Date()
    }

    private(set) var phase: Phase = .idle
    private(set) var heard = ""
    private(set) var reply = ""
    private(set) var history: [Entry] = []
    /// Set when "näytä ruutu" was said or typed; the view opens the screen.
    var showScreen = false

    private let listener = Listener()
    private let speaker = Speaker()
    private var job: JobReply?
    private var run: Task<Void, Never>?
    /// False while a typed message is in flight: the phone stays quiet.
    private var aloud = true

    init() {
        listener.onPartial = { [weak self] text in self?.heard = text }
    }

    var isBusy: Bool {
        switch phase {
        case .idle, .failed: false
        default: true
        }
    }

    /// The big button: start, stop listening early, or stop speaking.
    func mainButton() {
        switch phase {
        case .idle, .failed: start()
        case .listening: listener.finish()
        case .speaking: speaker.stop()
        default: break
        }
    }

    func start() {
        guard !isBusy else { return }
        run?.cancel()
        run = Task { await exchange() }
    }

    /// Sends a typed message. Returns false when nothing was sent.
    @discardableResult
    func send(_ typed: String) -> Bool {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return false }
        guard let client = Settings.client else {
            phase = .failed(RemoteError.notConfigured.localizedDescription)
            return false
        }
        if ScreenRequest.matches(text) {
            showScreen = true
            return true
        }
        run?.cancel()
        aloud = false
        heard = text
        reply = ""
        phase = .sending
        run = Task { await follow({ try await client.command(text) }, client: client) }
        return true
    }

    func cancel() {
        run?.cancel()
        listener.cancel()
        speaker.stop()
        phase = .idle
    }

    func choose(_ option: String) {
        guard case .prompt = phase, let job, let promptID = job.promptID, let client = Settings.client else { return }
        speaker.stop()
        phase = .working("Vastaus lähetetty")
        run = Task { await follow({ try await client.answer(job: job.id, prompt: promptID, choice: option) }, client: client) }
    }

    // MARK: Flow

    private func exchange() async {
        guard let client = Settings.client else {
            phase = .failed(RemoteError.notConfigured.localizedDescription)
            return
        }
        aloud = true
        heard = ""
        reply = ""
        phase = .listening
        let text: String
        do {
            text = try await listener.listen()
        } catch is CancellationError {
            phase = .idle
            return
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        heard = text
        if ScreenRequest.matches(text) {
            phase = .idle
            showScreen = true
            return
        }
        phase = .sending
        await follow({ try await client.command(text) }, client: client)
    }

    /// Asks again while Jarvis works; stops at a question or the answer.
    private func follow(_ first: () async throws -> JobReply, client: RemoteClient) async {
        do {
            var current = try await first()
            for _ in 0..<120 {
                job = current
                if Task.isCancelled { return }
                if current.isWorking {
                    phase = .working(current.step.flatMap { $0.isEmpty ? nil : $0 })
                    current = try await client.status(current.id)
                    continue
                }
                if current.isPrompt {
                    phase = .prompt(question: current.question ?? "", options: current.options ?? ["Salli", "Kiellä"])
                    if aloud { await speaker.speak(current.say ?? "") }
                    return
                }
                await finish(current)
                return
            }
            phase = .failed("Jarvis ei vastannut ajoissa.")
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            let message = (error as? URLError).map(Self.describe) ?? error.localizedDescription
            phase = .failed(message)
            record(failed: true, reply: message)
        }
    }

    private func finish(_ reply: JobReply) async {
        let failed = reply.status == "failed"
        self.reply = reply.reply ?? reply.say ?? ""
        record(failed: failed, reply: self.reply)
        guard aloud else {
            phase = failed ? .failed(self.reply) : .idle
            return
        }
        phase = .speaking
        await speaker.speak(reply.say ?? self.reply)
        if phase == .speaking { phase = failed ? .failed(self.reply) : .idle }
    }

    private func record(failed: Bool, reply: String) {
        history.insert(Entry(command: heard, reply: reply, failed: failed), at: 0)
        if history.count > 30 { history.removeLast() }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet, .timedOut:
            "Mac ei vastaa. Onko Tailscale päällä puhelimessa ja Macilla?"
        default:
            error.localizedDescription
        }
    }
}
