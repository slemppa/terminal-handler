import Foundation
import Testing
@testable import THCore

private func raw(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

private func chatBody(stream: Bool, last: JSONValue) -> Data {
    JSONValue.object([
        "model": .string("jarvis"),
        "stream": .bool(stream),
        "messages": .array([
            .object(["role": .string("system"), "content": .string(String(repeating: "Olet avustaja. ", count: 2000))]),
            .object(["role": .string("user"), "content": .string("Vanha komento")]),
            .object(["role": .string("assistant"), "content": .string("Selvä.")]),
            last,
        ]),
        "tools": .array([.object(["type": .string("function"), "function": .object(["name": .string("execute_terminal_command")])])]),
    ]).encoded()
}

@Suite struct HTTPParserTests {
    @Test func incompleteUntilBodyArrives() {
        let head = raw("POST /v1/chat/completions HTTP/1.1\nHost: 127.0.0.1:8765\nContent-Length: 10\n\n")
        #expect(HTTPRequestParser.parse(head) == .incomplete)
        #expect(HTTPRequestParser.parse(head + Data("12345".utf8)) == .incomplete)
        guard case .complete(let request) = HTTPRequestParser.parse(head + Data("1234567890".utf8)) else {
            Issue.record("expected a complete request"); return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.header("HOST") == "127.0.0.1:8765")
        #expect(request.body == Data("1234567890".utf8))
    }

    @Test func stripsQueryAndAbsoluteForm() {
        guard case .complete(let r) = HTTPRequestParser.parse(raw("GET http://localhost:8765/v1/models?x=1 HTTP/1.1\n\n")) else {
            Issue.record("expected a complete request"); return
        }
        #expect(r.path == "/v1/models")
    }

    @Test func chunkedBody() {
        let data = raw("POST /v1/chat/completions HTTP/1.1\nTransfer-Encoding: chunked\n\n") + Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        guard case .complete(let r) = HTTPRequestParser.parse(data) else { Issue.record("expected complete"); return }
        #expect(String(decoding: r.body, as: UTF8.self) == "Wikipedia")
    }

    @Test func rejectsHugeBody() {
        #expect(HTTPRequestParser.parse(raw("POST / HTTP/1.1\nContent-Length: 999999999\n\n")) == .tooLarge)
    }

    @Test func rejectsGarbage() {
        if case .invalid = HTTPRequestParser.parse(raw("NONSENSE\n\n")) {} else { Issue.record("expected invalid") }
    }
}

@Suite struct ChatRequestTests {
    @Test func lastUserStringIsTheTranscript() throws {
        let last: JSONValue = .object(["role": .string("user"), "content": .string("  Paljonko levytilaa on jäljellä?\n")])
        let r = try #require(ChatRequest.parse(chatBody(stream: true, last: last)))
        #expect(r.transcript == "Paljonko levytilaa on jäljellä?")
        #expect(r.stream)
        #expect(r.lastRole == "user")
        #expect(r.messageCount == 4)
        #expect(r.toolCount == 1)
    }

    @Test func contentPartsAreJoined() throws {
        let last: JSONValue = .object(["role": .string("user"), "content": .array([
            .object(["type": .string("text"), "text": .string("Avaa")]),
            .object(["type": .string("image_url"), "image_url": .object([:])]),
            .object(["type": .string("text"), "text": .string("Safari")]),
        ])])
        let r = try #require(ChatRequest.parse(chatBody(stream: false, last: last)))
        #expect(r.transcript == "Avaa\nSafari")
        #expect(!r.stream)
    }

    @Test func toolResultIsNotACommand() throws {
        let last: JSONValue = .object(["role": .string("tool"), "tool_call_id": .string("c1"), "content": .string("ok")])
        let r = try #require(ChatRequest.parse(chatBody(stream: false, last: last)))
        #expect(r.transcript == nil)
        #expect(r.lastRole == "tool")
    }

    @Test func notChatJSON() {
        #expect(ChatRequest.parse(Data("{}".utf8)) == nil)
        #expect(ChatRequest.parse(Data("nope".utf8)) == nil)
    }
}

@Suite struct JarvisAPITests {
    private func post(_ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v1/chat/completions", headers: headers)
    }

    @Test func routes() {
        #expect(JarvisAPI.route(HTTPRequest(method: "GET", path: "/v1/models")) == .models)
        #expect(JarvisAPI.route(HTTPRequest(method: "GET", path: "/models/")) == .models)
        #expect(JarvisAPI.route(HTTPRequest(method: "POST", path: "/v1/chat/completions")) == .chatCompletions)
        #expect(JarvisAPI.route(HTTPRequest(method: "POST", path: "/v1/v1/chat/completions")) == .chatCompletions)
        #expect(JarvisAPI.route(HTTPRequest(method: "GET", path: "/")) == .notFound)
    }

    @Test func acceptsLocalClientWithKey() {
        let ok = post(["host": "127.0.0.1:8765", "content-type": "application/json; charset=utf-8", "authorization": "Bearer k1"])
        #expect(JarvisAPI.check(ok, route: .chatCompletions, apiKey: "k1") == nil)
        #expect(JarvisAPI.check(post(["content-type": "application/json", "x-api-key": "k1"]), route: .chatCompletions, apiKey: "k1") == nil)
    }

    @Test func rejectsBrowsersAndStrangers() {
        let base = ["host": "localhost:8765", "content-type": "application/json", "authorization": "Bearer k1"]
        #expect(JarvisAPI.check(post(base.merging(["origin": "https://evil.example"]) { $1 }), route: .chatCompletions, apiKey: "k1") == .browserOrigin)
        #expect(JarvisAPI.check(post(base.merging(["host": "evil.example:8765"]) { $1 }), route: .chatCompletions, apiKey: "k1") == .badHost)
        #expect(JarvisAPI.check(post(base.merging(["content-type": "text/plain"]) { $1 }), route: .chatCompletions, apiKey: "k1") == .notJSON)
        #expect(JarvisAPI.check(post(base.merging(["authorization": "Bearer nope"]) { $1 }), route: .chatCompletions, apiKey: "k1") == .unauthorized)
        #expect(JarvisAPI.check(HTTPRequest(method: "OPTIONS", path: "/v1/chat/completions"), route: .chatCompletions, apiKey: "k1") == .method)
    }

    @Test func keyCanBeTurnedOff() {
        #expect(JarvisAPI.check(post(["content-type": "application/json"]), route: .chatCompletions, apiKey: nil) == nil)
    }

    @Test func modelsListsJarvis() throws {
        let json = try #require(JSONValue.parse(JarvisAPI.modelsBody()))
        #expect(json["data"]?.array?.first?["id"]?.string == "jarvis")
    }

    @Test func completionIsOpenAIShaped() throws {
        let json = try #require(JSONValue.parse(JarvisAPI.completionBody(id: "c1", model: "jarvis", created: 1, text: "Selvä.")))
        #expect(json["object"]?.string == "chat.completion")
        let choice = try #require(json["choices"]?.array?.first)
        #expect(choice["message"]?["content"]?.string == "Selvä.")
        #expect(choice["message"]?["tool_calls"] == nil)
        #expect(choice["finish_reason"]?.string == "stop")
    }

    @Test func streamEndsWithDone() throws {
        let text = String(decoding: JarvisAPI.streamEvents(id: "c1", model: "jarvis", created: 1, text: "Selvä."), as: UTF8.self)
        let events = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        #expect(events.count == 4)
        #expect(events.last == "data: [DONE]")
        let content = events.dropLast().compactMap { event -> String? in
            JSONValue.parse(Data(event.dropFirst(6).utf8))?["choices"]?.array?.first?["delta"]?["content"]?.string
        }.joined()
        #expect(content == "Selvä.")
        let finish = JSONValue.parse(Data(events[2].dropFirst(6).utf8))?["choices"]?.array?.first?["finish_reason"]?.string
        #expect(finish == "stop")
    }
}

@Suite struct SpeechTextTests {
    @Test func stripsMarkdownCodeAndLinks() {
        let input = """
        ## Levytila
        Sinulla on **120 Gt** vapaana. Katso [ohje](https://example.com/a) tai https://apple.com/x.

        ```
        df -h
        ```
        - Kohta yksi
        > lainaus
        | a | b |
        Komento `df -h` kertoi sen.
        """
        // Same output as puhu.sh's perl (the URL rule eats the trailing dot there too).
        #expect(SpeechText.clean(input) == "Levytila Sinulla on 120 Gt vapaana. Katso ohje tai linkki Kohta yksi lainaus. Komento df -h kertoi sen.")
    }

    @Test func capsLength() {
        #expect(SpeechText.clean(String(repeating: "a", count: 3000)).count == SpeechText.limit)
    }

    @Test func emptyStaysEmpty() {
        #expect(SpeechText.clean("```\ncode\n```") == "")
    }
}

@Suite struct JarvisSessionPolicyTests {
    let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func freshWithoutHistory() {
        #expect(JarvisSessionPolicy().resumeID(now: start) == nil)
    }

    @Test func resumesWithinFifteenMinutes() {
        var policy = JarvisSessionPolicy()
        policy.turnEnded(sessionID: "s1", at: start)
        #expect(policy.resumeID(now: start.addingTimeInterval(60)) == "s1")
        #expect(policy.resumeID(now: start.addingTimeInterval(14 * 60 + 59)) == "s1")
        #expect(policy.resumeID(now: start.addingTimeInterval(15 * 60)) == nil)
    }

    @Test func eachTurnExtendsTheWindow() {
        var policy = JarvisSessionPolicy()
        policy.turnEnded(sessionID: "s1", at: start)
        policy.turnEnded(sessionID: nil, at: start.addingTimeInterval(10 * 60))
        #expect(policy.resumeID(now: start.addingTimeInterval(20 * 60)) == "s1")
    }

    @Test func clockGoingBackwardsStartsFresh() {
        let policy = JarvisSessionPolicy(sessionID: "s1", lastTurnAt: start)
        #expect(policy.resumeID(now: start.addingTimeInterval(-5)) == nil)
    }

    @Test func reset() {
        var policy = JarvisSessionPolicy(sessionID: "s1", lastTurnAt: start)
        policy.reset()
        #expect(policy.resumeID(now: start) == nil)
    }
}

@Suite struct ClaudeStreamTests {
    private func line(_ s: String) -> Data { Data(s.utf8) }

    @Test func initGivesSessionID() {
        #expect(ClaudeStream.events(fromLine: line(#"{"type":"system","subtype":"init","cwd":"/x","session_id":"abc"}"#)) == [.started(sessionID: "abc")])
        #expect(ClaudeStream.events(fromLine: line(#"{"type":"system","subtype":"hook_started","session_id":"abc"}"#)) == [])
    }

    @Test func assistantTextAndTools() {
        let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":" Hei. "},{"type":"tool_use","name":"Bash","input":{"command":"df -h /"}}]},"parent_tool_use_id":null}"#
        #expect(ClaudeStream.events(fromLine: line(text)) == [.text("Hei."), .tool("Bash · df -h /")])
    }

    @Test func subagentMessagesAreSkipped() {
        let text = #"{"type":"assistant","message":{"content":[{"type":"text","text":"sisäinen"}]},"parent_tool_use_id":"toolu_1"}"#
        #expect(ClaudeStream.events(fromLine: line(text)) == [])
    }

    @Test func result() {
        let ok = #"{"type":"result","subtype":"success","is_error":false,"result":"Levyllä on tilaa.","session_id":"abc"}"#
        #expect(ClaudeStream.events(fromLine: line(ok)) == [.result(text: "Levyllä on tilaa.", sessionID: "abc", isError: false)])
        let bad = #"{"type":"result","subtype":"error_during_execution","session_id":"abc"}"#
        #expect(ClaudeStream.events(fromLine: line(bad)) == [.result(text: "", sessionID: "abc", isError: true)])
    }

    @Test func garbageIsIgnored() {
        #expect(ClaudeStream.events(fromLine: line("not json")) == [])
        #expect(ClaudeStream.events(fromLine: line(#"{"type":"rate_limit_event"}"#)) == [])
    }

    @Test func lineBufferSplitsAcrossReads() {
        var buffer = LineBuffer()
        #expect(buffer.append(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(buffer.append(Data(":2}\n\n".utf8)) == [Data("{\"b\":2}".utf8)])
        #expect(buffer.append(Data("tail".utf8)) == [])
        #expect(buffer.flush() == Data("tail".utf8))
        #expect(buffer.flush() == nil)
    }
}

@Suite struct JarvisHookTests {
    private let permission: JSONValue = .object([
        "hook_event_name": .string("PermissionRequest"),
        "session_id": .string("j1"),
        "tool_name": .string("Bash"),
        "tool_input": .object(["command": .string("touch /tmp/x")]),
    ])

    @Test func environmentMarksJarvis() {
        let env = HookEnvelope.make(payload: permission, environment: ["TH_JARVIS": "1"], owner: nil)
        #expect(env.isJarvis)
        #expect(env.tty == SessionStore.jarvisTTY)
        let normal = HookEnvelope.make(payload: permission, environment: [:], owner: (tty: "ttys001", pid: 42))
        #expect(!normal.isJarvis)
        #expect(normal.tty == "ttys001")
        #expect(normal.claudePID == 42)
    }

    @Test func oldAppsStillDecodeNewEnvelopes() throws {
        let data = try JSONEncoder().encode(HookEnvelope(tty: "ttys001", claudePID: 1, payload: permission))
        let decoded = try JSONDecoder().decode(HookEnvelope.self, from: data)
        #expect(decoded.origin == nil)
    }

    @Test func jarvisPermissionIsHeldWithoutGhostty() {
        var store = SessionStore()
        _ = store.updateTerminals([], isAlive: { _ in true })
        let env = HookEnvelope.make(payload: permission, environment: ["TH_JARVIS": "1"], owner: nil)
        let (disposition, _) = store.apply(env)
        guard case .hold(let request) = disposition else { Issue.record("expected hold"); return }
        #expect(request.tty == SessionStore.jarvisTTY)
        #expect(store.waitingCount == 1)
        // A Ghostty poll must not drop it.
        let orphaned = store.updateTerminals([TerminalSnapshot(id: "t1", tty: "ttys001")], isAlive: { _ in true })
        #expect(orphaned.isEmpty)
        #expect(store.pending.count == 1)
    }

    @Test func unknownTTYIsStillReleased() {
        var store = SessionStore()
        let env = HookEnvelope(tty: "ttys009", claudePID: 1, payload: permission)
        #expect(store.apply(env).disposition == .releaseNow)
    }
}
