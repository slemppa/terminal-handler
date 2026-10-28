import Foundation

/// All state the island shows, derived from Ghostty polls and Claude hook
/// events. A plain value so it can be tested without the app.
public struct SessionStore: Sendable {
    public private(set) var terminals: [TerminalSnapshot] = []
    /// Keyed by TTY: one Claude process per terminal at a time.
    public private(set) var sessions: [String: ClaudeSession] = [:]
    /// Oldest first.
    public private(set) var pending: [PendingRequest] = []
    /// TTY of the focused terminal while Ghostty is frontmost, else nil.
    public var focusedTTY: String?

    public init() {}

    // MARK: Inputs

    /// Replaces the terminal list and drops sessions whose terminal or
    /// Claude process is gone. Returns pending requests that were orphaned.
    public mutating func updateTerminals(_ snapshots: [TerminalSnapshot], isAlive: (Int32) -> Bool) -> [UUID] {
        terminals = snapshots
        let ttys = Set(snapshots.map(\.tty))
        for (tty, session) in sessions {
            let processGone = session.claudePID.map { !isAlive($0) } ?? false
            if !ttys.contains(tty) || processGone {
                sessions[tty] = nil
            }
        }
        let live = sessions
        return removePending { live[$0.tty] == nil }
    }

    /// Applies a hook event. `cleared` lists held requests that this event
    /// shows were settled elsewhere; the app releases their connections.
    public mutating func apply(_ env: HookEnvelope, requestID: UUID = UUID(), now: Date = .now)
        -> (disposition: HookDisposition, cleared: [UUID])
    {
        let blocking = isBlockingEvent(env.payload)
        guard let tty = env.tty else {
            return (blocking ? .releaseNow : .none, [])
        }
        let payload = env.payload
        let input = payload["tool_input"] ?? .null
        let toolName = env.toolName ?? ""
        var cleared: [UUID] = []

        switch env.eventName {
        case "SessionEnd":
            sessions[tty] = nil
            cleared = removePending { $0.tty == tty }
            return (.none, cleared)
        case "SessionStart":
            cleared = removePending { $0.tty == tty }
            sessions[tty] = ClaudeSession(sessionID: env.sessionID, tty: tty, claudePID: env.claudePID, status: .idle, updatedAt: now)
            return (.none, cleared)
        default:
            break
        }

        var session = sessions[tty] ?? ClaudeSession(sessionID: env.sessionID, tty: tty, claudePID: env.claudePID, status: .idle, updatedAt: now)
        session.sessionID = env.sessionID
        if let pid = env.claudePID { session.claudePID = pid }
        session.updatedAt = now
        var disposition: HookDisposition = .none

        switch env.eventName {
        case "UserPromptSubmit":
            cleared = removePending { $0.tty == tty }
            session.status = .working("Miettii…")
        case "Stop":
            cleared = removePending { $0.tty == tty }
            session.status = .done
        case "Notification":
            if payload["notification_type"]?.string == "idle_prompt", !hasPending(tty) {
                session.status = .done
            }
        case "PostToolUse":
            let useID = payload["tool_use_id"]
            cleared = removePending { req in
                guard req.tty == tty else { return false }
                if let useID, useID != .null, req.payload["tool_use_id"] == useID { return true }
                return req.payload["tool_name"]?.string == toolName && req.payload["tool_input"] == input
            }
            if !hasPending(tty) { session.status = .working(activitySummary(tool: toolName, input: input)) }
        case "PreToolUse" where toolName == "AskUserQuestion":
            session.status = .waitingQuestion
            disposition = hold(tty: tty, env: env, kind: .question(parseQuestions(input)), id: requestID, now: now)
        case "PreToolUse":
            if !hasPending(tty) { session.status = .working(activitySummary(tool: toolName, input: input)) }
        case "PermissionRequest":
            let detail = permissionDetail(tool: toolName, input: input)
            session.status = .waitingPermission(detail)
            disposition = hold(tty: tty, env: env, kind: .permission(tool: toolName, detail: detail), id: requestID, now: now)
        default:
            break
        }
        sessions[tty] = session
        if case .none = disposition, blocking { disposition = .releaseNow }
        return (disposition, cleared)
    }

    /// Removes a request after it was answered or released.
    public mutating func resolve(_ id: UUID) {
        guard let req = pending.first(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        if var session = sessions[req.tty], session.status.isWaiting, !hasPending(req.tty) {
            session.status = .working("Jatkaa…")
            sessions[req.tty] = session
        }
    }

    /// Releases any request held for `tty` (Sami went to the terminal himself).
    /// The session stays "waiting": the prompt now shows in the terminal.
    public mutating func releaseAll(forTTY tty: String) -> [UUID] {
        removePending { $0.tty == tty }
    }

    // MARK: Derived

    public func session(for terminal: TerminalSnapshot) -> ClaudeSession? {
        sessions[terminal.tty]
    }

    public func dot(for terminal: TerminalSnapshot) -> Dot {
        if let session = sessions[terminal.tty] {
            switch session.status {
            case .waitingPermission, .waitingQuestion: return .orange
            case .working: return .green
            case .done: return .blue
            case .idle: return .grey
            }
        }
        return terminal.foreground == nil ? .grey : .dimGreen
    }

    public func activity(for terminal: TerminalSnapshot) -> String {
        if let session = sessions[terminal.tty] {
            switch session.status {
            case .working(let text): return text
            case .waitingPermission(let detail): return "Kysyy lupaa: \(detail)"
            case .waitingQuestion: return "Odottaa vastaustasi"
            case .done: return "Valmis · odottaa promptia"
            case .idle: return "Claude · valmiina"
            }
        }
        return terminal.foreground ?? "vapaa"
    }

    public var waitingCount: Int {
        terminals.count { dot(for: $0) == .orange }
    }

    // MARK: Private

    private func hasPending(_ tty: String) -> Bool {
        pending.contains { $0.tty == tty }
    }

    private mutating func hold(tty: String, env: HookEnvelope, kind: RequestKind, id: UUID, now: Date) -> HookDisposition {
        guard terminals.contains(where: { $0.tty == tty }), focusedTTY != tty else { return .releaseNow }
        let req = PendingRequest(id: id, tty: tty, sessionID: env.sessionID, kind: kind, payload: env.payload, createdAt: now)
        pending.append(req)
        return .hold(req)
    }

    private mutating func removePending(where predicate: (PendingRequest) -> Bool) -> [UUID] {
        let ids = pending.filter(predicate).map(\.id)
        pending.removeAll(where: predicate)
        return ids
    }
}

// MARK: - Text helpers

func shortened(_ text: String, _ limit: Int) -> String {
    let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
}

public func activitySummary(tool: String, input: JSONValue) -> String {
    let arg: String? = switch tool {
    case "Bash": input["command"]?.string.map { shortened($0, 40) }
    case "Edit", "Write", "Read", "MultiEdit", "NotebookEdit":
        (input["file_path"]?.string ?? input["notebook_path"]?.string).map { ($0 as NSString).lastPathComponent }
    case "Grep", "Glob": input["pattern"]?.string.map { shortened($0, 30) }
    case "WebFetch": input["url"]?.string.flatMap { URL(string: $0)?.host() }
    case "WebSearch": input["query"]?.string.map { shortened($0, 30) }
    case "Task", "Agent": input["description"]?.string.map { shortened($0, 30) }
    default: nil
    }
    guard let arg, !arg.isEmpty else { return tool }
    return "\(tool) · \(arg)"
}

func permissionDetail(tool: String, input: JSONValue) -> String {
    if let command = input["command"]?.string { return command }
    if let path = input["file_path"]?.string { return "\(tool) \(path)" }
    if let url = input["url"]?.string { return "\(tool) \(url)" }
    let json = String(decoding: input.encoded(), as: UTF8.self)
    return json == "null" ? tool : "\(tool) \(json.count > 200 ? String(json.prefix(199)) + "…" : json)"
}

func parseQuestions(_ input: JSONValue) -> [AskQuestion] {
    (input["questions"]?.array ?? []).map { q in
        AskQuestion(
            question: q["question"]?.string ?? "",
            header: q["header"]?.string ?? "",
            options: (q["options"]?.array ?? []).map {
                AskOption(label: $0["label"]?.string ?? "", description: $0["description"]?.string ?? "")
            },
            multiSelect: q["multiSelect"]?.bool ?? false
        )
    }
}

// MARK: - Replies

public enum HookReply {
    /// The JSON written to the hook's stdout for an answer.
    public static func data(for answer: Answer, request: PendingRequest) -> Data {
        let output: JSONValue
        switch (answer, request.kind) {
        case (.allow, _):
            output = .object(["hookEventName": .string("PermissionRequest"),
                              "decision": .object(["behavior": .string("allow")])])
        case (.deny, _):
            output = .object(["hookEventName": .string("PermissionRequest"),
                              "decision": .object(["behavior": .string("deny"),
                                                   "message": .string("Kielletty Terminal Handlerista")])])
        case (.choices(let answers), _):
            var input = request.payload["tool_input"]?.object ?? [:]
            input["answers"] = .object(answers.mapValues { .string($0) })
            output = .object(["hookEventName": .string("PreToolUse"),
                              "permissionDecision": .string("allow"),
                              "updatedInput": .object(input)])
        }
        return JSONValue.object(["hookSpecificOutput": output]).encoded()
    }
}
