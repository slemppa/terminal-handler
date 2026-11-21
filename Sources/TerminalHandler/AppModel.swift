import AppKit
import Observation
import THCore

/// One row in the island list.
struct TerminalRow: Identifiable, Equatable {
    var id: String
    var repo: String
    var branch: String?
    var activity: String
    var dot: Dot
}

/// Owns all state: Ghostty polls and hook events go in, rows and the
/// current question come out.
@Observable
final class AppModel {
    private(set) var store = SessionStore()
    private(set) var rows: [TerminalRow] = []
    /// The voice assistant run from FluidVoice's Command Mode.
    let jarvis = JarvisController()
    /// Called when a new question is held, so the island can pop open.
    @ObservationIgnored var onQuestionArrived: (() -> Void)?

    @ObservationIgnored private var connections: [UUID: HookConnection] = [:]
    @ObservationIgnored private var gitCache: [String: GitInfo?] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// The phone's answers so far to a Jarvis question with several parts.
    @ObservationIgnored private var remoteChoices: [UUID: [String: String]] = [:]

    var pending: [PendingRequest] { store.pending }
    var waitingCount: Int { store.waitingCount }

    func row(forTTY tty: String) -> TerminalRow? {
        guard let terminal = store.terminals.first(where: { $0.tty == tty }) else { return nil }
        return rows.first { $0.id == terminal.id }
    }

    // MARK: Polling

    func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    private func poll() async {
        releaseVanishedHooks()
        release(store.expired(olderThan: 30 * 60), answered: false)
        let foreground = await ProcessTable.foreground()
        guard let snapshot = await GhosttyBridge.snapshot() else {
            // A failed poll while Ghostty runs is transient: keep what we know.
            if !GhosttyBridge.isRunning { apply(terminals: [], focusedID: nil) }
            return
        }
        let terminals = snapshot.terminals.map { t in
            var t = t
            t.foreground = foreground[t.tty]
            return t
        }
        apply(terminals: terminals, focusedID: GhosttyBridge.isFrontmost ? snapshot.focusedTerminalID : nil)
    }

    private func apply(terminals: [TerminalSnapshot], focusedID: String?) {
        gitCache = [:]
        let orphaned = store.updateTerminals(terminals) { kill($0, 0) == 0 || errno == EPERM }
        release(orphaned)
        store.focusedTTY = terminals.first { $0.id == focusedID }?.tty
        // Sami went to the terminal himself: hand the question back to Claude's own prompt.
        if let tty = store.focusedTTY {
            release(store.releaseAll(forTTY: tty))
        }
        rebuildRows()
    }

    /// Claude cancels a hook (e.g. Esc) by killing it; drop those questions.
    private func releaseVanishedHooks() {
        let gone = connections.filter { $0.value.peerClosed }.map(\.key)
        release(gone, answered: false)
    }

    private func rebuildRows() {
        syncRemotePrompt()
        rows = store.terminals.map { t in
            let git = gitInfo(for: t.cwd)
            return TerminalRow(
                id: t.id,
                repo: git?.repoName ?? displayName(for: t.cwd),
                branch: git?.branch,
                activity: activityText(for: t),
                dot: store.dot(for: t))
        }
    }

    private func activityText(for terminal: TerminalSnapshot) -> String {
        let text = store.activity(for: terminal)
        // Without hook data, Claude's own terminal title is the best summary.
        if store.session(for: terminal) == nil, terminal.foreground == "claude" {
            let title = terminal.title.drop { !$0.isLetter && !$0.isNumber }
            return title.isEmpty ? "Claude" : "Claude · \(title)"
        }
        return text
    }

    private func gitInfo(for cwd: String) -> GitInfo? {
        if let cached = gitCache[cwd] { return cached }
        let info = GitInfo.resolve(cwd: cwd)
        gitCache[cwd] = info
        return info
    }

    private func displayName(for cwd: String) -> String {
        if cwd.isEmpty { return "Terminaali" }
        if cwd == NSHomeDirectory() { return "~" }
        return (cwd as NSString).lastPathComponent
    }

    // MARK: Hooks

    func handle(_ envelope: HookEnvelope, connection: HookConnection) {
        let (disposition, cleared) = store.apply(envelope)
        release(cleared)
        switch disposition {
        case .none, .releaseNow:
            connection.reply()
        case .hold(let request):
            connection.acknowledgeHold()
            // th-hook gives up after 3 s without an ack; then Claude already shows its own prompt.
            if connection.peerClosed {
                connection.reply()
                store.resolve(request.id, answered: false)
                break
            }
            connections[request.id] = connection
            onQuestionArrived?()
            let repo = request.tty == SessionStore.jarvisTTY ? "Jarvis" : row(forTTY: request.tty)?.repo ?? "Claude"
            Notifier.announce(repo: repo, text: summary(of: request))
        }
        rebuildRows()
    }

    func answer(_ id: UUID, with answer: Answer) {
        guard let request = store.pending.first(where: { $0.id == id }) else { return }
        connections.removeValue(forKey: id)?.reply(HookReply.data(for: answer, request: request))
        store.resolve(id)
        rebuildRows()
    }

    /// Jumps to the terminal; the question goes back to Claude's own prompt.
    func openTerminal(for request: PendingRequest) {
        release(store.releaseAll(forTTY: request.tty))
        if let terminal = store.terminals.first(where: { $0.tty == request.tty }) {
            GhosttyBridge.focus(terminalID: terminal.id)
        }
        rebuildRows()
    }

    func jump(to terminalID: String) {
        if let terminal = store.terminals.first(where: { $0.id == terminalID }) {
            release(store.releaseAll(forTTY: terminal.tty))
        }
        GhosttyBridge.focus(terminalID: terminalID)
    }

    /// Answers every held hook with no output, e.g. on quit.
    func releaseEverything() {
        for connection in connections.values { connection.reply() }
        connections = [:]
    }

    /// Gives held hooks back to Claude with no answer. With `answered: false`
    /// they are also dropped from the store (cancelled or expired).
    private func release(_ ids: [UUID], answered: Bool? = nil) {
        for id in ids {
            connections.removeValue(forKey: id)?.reply()
            if answered == false { store.resolve(id, answered: false) }
        }
        if answered == false, !ids.isEmpty { rebuildRows() }
    }

    // MARK: Phone

    /// While a phone command runs, what Jarvis waits on is mirrored to the
    /// phone. The island shows it too; whichever answers first wins.
    private func syncRemotePrompt() {
        let held = Set(store.pending.map(\.id))
        remoteChoices = remoteChoices.filter { held.contains($0.key) }
        guard let job = jarvis.currentRemoteJob else { return }
        let jobs = jarvis.remoteJobs
        if let request = store.pending.first(where: { $0.tty == SessionStore.jarvisTTY }),
           let prompt = remotePrompt(for: request) {
            jobs.update(job, .prompt(prompt))
        } else if case .prompt? = jobs.snapshot(job)?.state {
            jobs.update(job, .working(nil))
        }
    }

    private func remotePrompt(for request: PendingRequest) -> RemotePrompt? {
        switch request.kind {
        case .permission(let tool, let detail):
            let what = detail.isEmpty ? tool : "\(tool): \(detail)"
            return RemotePrompt(id: RemotePrompt.id(request: request.id, index: 0),
                                question: "Saako Jarvis jatkaa? \(what)",
                                options: [RemotePrompt.allow, RemotePrompt.deny])
        case .question(let questions):
            let index = remoteChoices[request.id]?.count ?? 0
            guard index < questions.count else { return nil }
            let question = questions[index]
            return RemotePrompt(id: RemotePrompt.id(request: request.id, index: index),
                                question: question.question,
                                options: question.options.map(\.label))
        }
    }

    /// The phone answered `promptID`. Only Jarvis's own requests can be
    /// answered this way, never a Ghostty session's.
    func remoteAnswer(promptID: String, choice: String) {
        guard let parsed = RemotePrompt.parse(promptID),
              let request = store.pending.first(where: { $0.id == parsed.request }),
              request.tty == SessionStore.jarvisTTY else { return }
        let (id, index) = (parsed.request, parsed.index)
        switch request.kind {
        case .permission:
            guard index == 0 else { return }
            answer(id, with: RemotePrompt.isAllow(choice) ? .allow : .deny)
        case .question(let questions):
            var choices = remoteChoices[id] ?? [:]
            guard index == choices.count, index < questions.count else { return }
            choices[questions[index].question] = choice
            if choices.count == questions.count {
                remoteChoices[id] = nil
                answer(id, with: .choices(choices))
            } else {
                remoteChoices[id] = choices
                syncRemotePrompt()
            }
        }
    }

    func summary(of request: PendingRequest) -> String {
        switch request.kind {
        case .permission(let tool, let detail): detail.isEmpty ? "Lupa: \(tool)" : detail
        case .question(let questions): questions.first?.question ?? "Kysymys"
        }
    }
}
