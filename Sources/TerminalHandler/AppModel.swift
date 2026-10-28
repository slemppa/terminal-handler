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
    /// Called when a new question is held, so the island can pop open.
    @ObservationIgnored var onQuestionArrived: (() -> Void)?

    @ObservationIgnored private var connections: [UUID: HookConnection] = [:]
    @ObservationIgnored private var gitCache: [String: GitInfo?] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

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
        releaseVanishedHooks()
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
        for id in gone {
            store.resolve(id)
            connections[id] = nil
        }
        if !gone.isEmpty { rebuildRows() }
    }

    private func rebuildRows() {
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
            connections[request.id] = connection
            connection.acknowledgeHold()
            onQuestionArrived?()
            let repo = row(forTTY: request.tty)?.repo ?? "Claude"
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

    private func release(_ ids: [UUID]) {
        for id in ids {
            connections.removeValue(forKey: id)?.reply()
        }
    }

    func summary(of request: PendingRequest) -> String {
        switch request.kind {
        case .permission(let tool, let detail): detail.isEmpty ? "Lupa: \(tool)" : detail
        case .question(let questions): questions.first?.question ?? "Kysymys"
        }
    }
}
