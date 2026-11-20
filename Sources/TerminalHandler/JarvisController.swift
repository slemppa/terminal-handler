import AppKit
import Observation
import OSLog
import Synchronization
import THCore

/// Runs dictated commands through a headless Claude Code session in
/// ~/Jarvis and reads the answer aloud with Satu.
///
/// One turn at a time. A command that arrives while a turn runs is queued,
/// not interrupting: killing a turn halfway could leave an action (opening,
/// moving, sending) half done, and a queued follow-up still sees the earlier
/// turn's context because it resumes the same session.
@Observable
final class JarvisController {
    enum Phase: Equatable {
        case idle
        /// The command arrived; claude is starting.
        case received
        /// Claude works; the text is the latest tool step, if any.
        case thinking(String?)
        case speaking
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript = ""
    private(set) var reply = ""
    private(set) var queued: [String] = []
    /// When the island last had something to show for Jarvis.
    private(set) var updatedAt: Date?

    /// Called on every phase change, so the island can open, hold and close.
    @ObservationIgnored var onPhaseChange: ((Phase) -> Void)?

    @ObservationIgnored private static let log = Logger(subsystem: "fi.slemppa.TerminalHandler", category: "jarvis")
    @ObservationIgnored private var turn: ClaudeTurn?
    @ObservationIgnored private var speech: Process?
    @ObservationIgnored private var policy: JarvisSessionPolicy
    @ObservationIgnored private var resumedThisTurn = false
    @ObservationIgnored private var sawAssistantText = false
    @ObservationIgnored private var cancelled = false

    private static let sessionKey = "jarvisSessionID"
    private static let lastTurnKey = "jarvisLastTurnAt"

    init() {
        let defaults = UserDefaults.standard
        policy = JarvisSessionPolicy(
            sessionID: defaults.string(forKey: Self.sessionKey),
            lastTurnAt: defaults.object(forKey: Self.lastTurnKey) as? Date)
    }

    var isBusy: Bool { turn != nil }
    var isSpeaking: Bool { phase == .speaking }
    /// Worth showing in the island: active, or finished within the last few minutes.
    var isRecent: Bool {
        if phase != .idle { return true }
        guard let updatedAt else { return false }
        return Date.now.timeIntervalSince(updatedAt) < 5 * 60
    }

    // MARK: Commands

    func submit(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stopSpeaking()
        if turn != nil {
            queued.append(text)
            touch()
            return
        }
        start(text)
    }

    /// Stops the running turn and drops the queue.
    func cancel() {
        queued = []
        if turn != nil { cancelled = true }
        turn?.cancel()
        stopSpeaking()
    }

    func stopSpeaking() {
        guard let speech else { return }
        self.speech = nil
        if speech.isRunning { speech.terminate() }
        if phase == .speaking { set(.idle) }
    }

    // MARK: Turn

    private func start(_ text: String, forceFresh: Bool = false) {
        transcript = text
        reply = ""
        sawAssistantText = false
        cancelled = false
        let resume = forceFresh ? nil : policy.resumeID()
        resumedThisTurn = resume != nil
        set(.received)
        guard let claude = Self.claudeExecutable() else {
            fail("Claude Codea ei löytynyt (~/.local/bin/claude).")
            return
        }
        let directory = Self.jarvisDirectory()
        guard FileManager.default.fileExists(atPath: directory.path) else {
            fail("Kansiota \(directory.path) ei ole.")
            return
        }
        Self.log.info("turn: resume=\(resume ?? "-", privacy: .public)")
        let turn = ClaudeTurn(executable: claude, directory: directory, prompt: text, resume: resume) { [weak self] event in
            self?.handle(event)
        } onExit: { [weak self] status, stderr in
            self?.finished(status: status, stderr: stderr)
        }
        self.turn = turn
        if !turn.launch() {
            self.turn = nil
            fail("Clauden käynnistys epäonnistui.")
        }
    }

    private func handle(_ event: ClaudeStreamEvent) {
        switch event {
        case .started:
            if phase == .received { set(.thinking(nil)) }
        case .text(let text):
            sawAssistantText = true
            reply = reply.isEmpty ? text : reply + "\n\n" + text
            touch()
        case .tool(let summary):
            set(.thinking(summary))
        case .result(let text, let sessionID, let isError):
            if !isError || sawAssistantText { policy.turnEnded(sessionID: sessionID) }
            saveSession()
            if !text.isEmpty { reply = text }
            if isError && !sawAssistantText && text.isEmpty { return }
            speak(reply)
        }
    }

    private func finished(status: Int32, stderr: String) {
        turn = nil
        if phase == .received || isThinking {
            // No result line: the turn crashed, was cancelled, or the session could not be resumed.
            if resumedThisTurn && !cancelled && !sawAssistantText && status != 0 {
                Self.log.info("resume failed, starting fresh: \(stderr, privacy: .public)")
                policy.reset()
                saveSession()
                start(transcript, forceFresh: true)
                return
            }
            if cancelled {
                reply = "Keskeytetty."
                set(.idle)
            } else {
                Self.log.error("claude exited \(status): \(stderr, privacy: .public)")
                fail("Jarvis ei vastannut.")
            }
        }
        if let next = queued.first {
            queued.removeFirst()
            stopSpeaking()
            start(next)
        }
    }

    private var isThinking: Bool {
        if case .thinking = phase { return true }
        return false
    }

    private func fail(_ message: String) {
        reply = message
        set(.failed(message))
        speak("Jokin meni pieleen.", thenIdle: false)
    }

    // MARK: Speech

    private func speak(_ text: String, thenIdle: Bool = true) {
        let spoken = SpeechText.clean(text)
        guard !spoken.isEmpty else {
            if thenIdle { set(.idle) }
            return
        }
        stopSpeaking()
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Satu", "-r", "195", "--", spoken]
        say.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.speech === process else { return }
                self.speech = nil
                if self.phase == .speaking { self.set(.idle) }
            }
        }
        do {
            try say.run()
            speech = say
            if thenIdle { set(.speaking) }
        } catch {
            Self.log.error("say failed: \(error.localizedDescription, privacy: .public)")
            if thenIdle { set(.idle) }
        }
    }

    // MARK: Helpers

    private func set(_ phase: Phase) {
        self.phase = phase
        touch()
        onPhaseChange?(phase)
    }

    private func touch() { updatedAt = .now }

    private func saveSession() {
        let defaults = UserDefaults.standard
        defaults.set(policy.sessionID, forKey: Self.sessionKey)
        defaults.set(policy.lastTurnAt, forKey: Self.lastTurnKey)
    }

    /// `defaults write fi.slemppa.TerminalHandler jarvisClaudePath <path>` overrides.
    static func claudeExecutable() -> URL? {
        let home = NSHomeDirectory()
        let candidates = [UserDefaults.standard.string(forKey: "jarvisClaudePath"),
                          "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    /// `defaults write fi.slemppa.TerminalHandler jarvisDirectory <path>` overrides.
    static func jarvisDirectory() -> URL {
        if let path = UserDefaults.standard.string(forKey: "jarvisDirectory") { return URL(filePath: path) }
        return URL(filePath: NSHomeDirectory()).appending(path: "Jarvis", directoryHint: .isDirectory)
    }
}

/// One `claude -p` run with its output parsed line by line.
nonisolated final class TurnBuffers: Sendable {
    let lock = Mutex<(lines: LineBuffer, stderr: Data)>((LineBuffer(), Data()))
}

/// Process and Pipe are not Sendable; they are only configured in init and
/// then touched through their own thread-safe API.
nonisolated final class ClaudeTurn: @unchecked Sendable {
    private let process = Process()
    private let buffers = TurnBuffers()

    init(executable: URL, directory: URL, prompt: String, resume: String?,
         onEvent: @escaping @Sendable @MainActor (ClaudeStreamEvent) -> Void,
         onExit: @escaping @Sendable @MainActor (Int32, String) -> Void) {
        process.executableURL = executable
        process.currentDirectoryURL = directory
        var arguments = ["-p", "--permission-mode", "auto", "--output-format", "stream-json", "--verbose"]
        if let resume { arguments += ["--resume", resume] }
        process.arguments = arguments
        process.environment = Self.environment()

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let promptData = Data(prompt.utf8)
        let state = buffers

        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let lines = state.lock.withLock { $0.lines.append(data) }
            let events = lines.flatMap(ClaudeStream.events(fromLine:))
            guard !events.isEmpty else { return }
            Task { @MainActor in events.forEach(onEvent) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            state.lock.withLock { s in
                s.stderr.append(data)
                if s.stderr.count > 16 << 10 { s.stderr = s.stderr.suffix(8 << 10) }
            }
        }
        process.terminationHandler = { process in
            // Let the pipes drain before reporting the exit.
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            let (events, stderr) = state.lock.withLock { s -> ([ClaudeStreamEvent], String) in
                var lines = s.lines.append(rest)
                if let tail = s.lines.flush() { lines.append(tail) }
                return (lines.flatMap(ClaudeStream.events(fromLine:)), String(decoding: s.stderr, as: UTF8.self))
            }
            let status = process.terminationStatus
            Task { @MainActor in
                events.forEach(onEvent)
                onExit(status, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        self.input = input
        self.promptData = promptData
    }

    private let input: Pipe
    private let promptData: Data

    func launch() -> Bool {
        do {
            try process.run()
        } catch {
            return false
        }
        // The prompt goes in on stdin so a command starting with "-" is never read as a flag.
        let handle = input.fileHandleForWriting
        handle.write(promptData)
        try? handle.close()
        return true
    }

    func cancel() {
        guard process.isRunning else { return }
        process.interrupt()
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT"] { env[key] = nil }
        let home = NSHomeDirectory()
        let path = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (path + existing.filter { !path.contains($0) }).joined(separator: ":")
        env["HOME"] = env["HOME"] ?? home
        // puhu.sh stays quiet (the app speaks); th-hook routes permission prompts to the island.
        env["JARVIS_FROM_APP"] = "1"
        env["TH_JARVIS"] = "1"
        return env
    }
}
