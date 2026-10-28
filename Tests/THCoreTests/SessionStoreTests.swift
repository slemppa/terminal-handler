import Foundation
import Testing
@testable import THCore

private func env(_ event: String, tty: String? = "ttys001", pid: Int32 = 100, _ extra: [String: JSONValue] = [:]) -> HookEnvelope {
    var obj: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string("s1")]
    obj.merge(extra) { $1 }
    return HookEnvelope(tty: tty, claudePID: pid, payload: .object(obj))
}

private let bash: [String: JSONValue] = [
    "tool_name": .string("Bash"),
    "tool_input": .object(["command": .string("supabase db push --linked")]),
]

private func storeWithTerminal(_ ttys: String...) -> SessionStore {
    var store = SessionStore()
    _ = store.updateTerminals(ttys.enumerated().map { TerminalSnapshot(id: "t\($0.offset)", tty: $0.element) }, isAlive: { _ in true })
    return store
}

@Suite struct SessionStoreTests {
    @Test func unknownTTYIsReleased() {
        var store = storeWithTerminal("ttys001")
        let result = store.apply(env("PermissionRequest", tty: "ttys099", bash))
        #expect(result.disposition == .releaseNow)
        #expect(store.pending.isEmpty)
    }

    @Test func missingTTYIsReleased() {
        var store = storeWithTerminal("ttys001")
        #expect(store.apply(env("PermissionRequest", tty: nil, bash)).disposition == .releaseNow)
    }

    @Test func focusedTerminalIsReleased() {
        var store = storeWithTerminal("ttys001")
        store.focusedTTY = "ttys001"
        #expect(store.apply(env("PermissionRequest", bash)).disposition == .releaseNow)
        #expect(store.dot(for: store.terminals[0]) == .orange)
    }

    @Test func permissionHolds() throws {
        var store = storeWithTerminal("ttys001")
        let result = store.apply(env("PermissionRequest", bash))
        guard case .hold(let req) = result.disposition else { Issue.record("expected hold"); return }
        #expect(req.kind == .permission(tool: "Bash", detail: "supabase db push --linked"))
        #expect(store.pending.count == 1)
        #expect(store.waitingCount == 1)
    }

    @Test func questionHoldsWithParsedOptions() {
        var store = storeWithTerminal("ttys001")
        let input: JSONValue = .object(["questions": .array([.object([
            "question": .string("Which DB?"), "header": .string("DB"), "multiSelect": .bool(false),
            "options": .array([.object(["label": .string("Postgres"), "description": .string("SQL")])]),
        ])])])
        let result = store.apply(env("PreToolUse", ["tool_name": .string("AskUserQuestion"), "tool_input": input]))
        guard case .hold(let req) = result.disposition, case .question(let qs) = req.kind else { Issue.record("expected question"); return }
        #expect(qs.first?.question == "Which DB?")
        #expect(qs.first?.options == [AskOption(label: "Postgres", description: "SQL")])
    }

    @Test func laterEventClearsPending() {
        var store = storeWithTerminal("ttys001")
        guard case .hold(let req) = store.apply(env("PermissionRequest", bash)).disposition else { return }
        // A different tool finishing does not clear it…
        let other = store.apply(env("PostToolUse", ["tool_name": .string("Read"), "tool_input": .object([:])]))
        #expect(other.cleared.isEmpty)
        // …the same tool call finishing does.
        let same = store.apply(env("PostToolUse", bash))
        #expect(same.cleared == [req.id])
        #expect(store.pending.isEmpty)
        #expect(store.dot(for: store.terminals[0]) == .green)
    }

    @Test func notificationDoesNotClearPending() {
        var store = storeWithTerminal("ttys001")
        _ = store.apply(env("PermissionRequest", bash))
        let result = store.apply(env("Notification", ["notification_type": .string("permission_prompt")]))
        #expect(result.cleared.isEmpty)
        #expect(store.pending.count == 1)
    }

    @Test func sessionDroppedWhenClaudeGone() {
        var store = storeWithTerminal("ttys001")
        _ = store.apply(env("PermissionRequest", pid: 4242, bash))
        let orphaned = store.updateTerminals(store.terminals, isAlive: { $0 != 4242 })
        #expect(orphaned.count == 1)
        #expect(store.sessions.isEmpty)
        #expect(store.dot(for: store.terminals[0]) == .grey)
    }

    @Test func sessionDroppedWhenTerminalClosed() {
        var store = storeWithTerminal("ttys001")
        _ = store.apply(env("Stop"))
        _ = store.updateTerminals([], isAlive: { _ in true })
        #expect(store.sessions.isEmpty)
    }

    @Test func dotPriority() {
        var store = SessionStore()
        _ = store.updateTerminals([
            TerminalSnapshot(id: "a", tty: "a"), TerminalSnapshot(id: "b", tty: "b"),
            TerminalSnapshot(id: "c", tty: "c"), TerminalSnapshot(id: "d", tty: "d", foreground: "npm"),
            TerminalSnapshot(id: "e", tty: "e"),
        ], isAlive: { _ in true })
        _ = store.apply(env("PermissionRequest", tty: "a", bash))
        _ = store.apply(env("PreToolUse", tty: "b", bash))
        _ = store.apply(env("Stop", tty: "c"))
        #expect(store.terminals.map { store.dot(for: $0) } == [.orange, .green, .blue, .dimGreen, .grey])
        #expect(store.waitingCount == 1)
    }

    @Test func resolveReturnsToWorking() {
        var store = storeWithTerminal("ttys001")
        guard case .hold(let req) = store.apply(env("PermissionRequest", bash)).disposition else { return }
        store.resolve(req.id)
        #expect(store.pending.isEmpty)
        #expect(store.dot(for: store.terminals[0]) == .green)
    }

    @Test func bashActivitySummary() {
        #expect(activitySummary(tool: "Bash", input: .object(["command": .string("npm test\nnpm run lint")])) == "Bash · npm test")
        #expect(activitySummary(tool: "Edit", input: .object(["file_path": .string("/a/b/Invoices.swift")])) == "Edit · Invoices.swift")
        #expect(activitySummary(tool: "Mystery", input: .null) == "Mystery")
    }

    @Test func replyShapes() throws {
        let req = PendingRequest(id: UUID(), tty: "t", sessionID: "s", kind: .question([]),
                                 payload: .object(["tool_input": .object(["questions": .array([])])]), createdAt: .now)
        let allow = try #require(JSONValue.parse(HookReply.data(for: .allow, request: req)))
        #expect(allow["hookSpecificOutput"]?["decision"]?["behavior"] == .string("allow"))
        let choices = try #require(JSONValue.parse(HookReply.data(for: .choices(["Q?": "A"]), request: req)))
        #expect(choices["hookSpecificOutput"]?["permissionDecision"] == .string("allow"))
        #expect(choices["hookSpecificOutput"]?["updatedInput"]?["answers"]?["Q?"] == .string("A"))
        #expect(choices["hookSpecificOutput"]?["updatedInput"]?["questions"] == .array([]))
    }
}
