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

    private func probeBody(_ text: String, tools: Int = 0) -> Data {
        var json: [String: JSONValue] = [
            "model": .string("jarvis"),
            "messages": .array([.object(["role": .string("user"), "content": .string(text)])]),
        ]
        if tools > 0 {
            json["tools"] = .array(Array(repeating: .object(["type": .string("function")]), count: tools))
        }
        return JSONValue.object(json).encoded()
    }

    /// FluidVoice's provider check: one bare "test" message without tools.
    @Test func connectionProbe() throws {
        #expect(try #require(ChatRequest.parse(probeBody("test"))).isConnectionProbe)
        #expect(try #require(ChatRequest.parse(probeBody("Test."))).isConnectionProbe)
        #expect(try #require(ChatRequest.parse(probeBody("test", tools: 1))).isConnectionProbe == false)
        #expect(try #require(ChatRequest.parse(probeBody("Avaa Safari"))).isConnectionProbe == false)
        let command = try #require(ChatRequest.parse(chatBody(stream: false, last: .object(["role": .string("user"), "content": .string("test")]))))
        #expect(command.isConnectionProbe == false)
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

@Suite struct RemoteRouteTests {
    private func post(_ path: String, _ headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: headers, body: Data("{}".utf8))
    }

    private let tailnet = ["host": "mac.tail1234.ts.net", "content-type": "application/json", "authorization": "Bearer k1"]

    @Test func routes() {
        #expect(JarvisAPI.route(HTTPRequest(method: "POST", path: "/jarvis/command")) == .remoteCommand)
        #expect(JarvisAPI.route(HTTPRequest(method: "POST", path: "/v1/jarvis/status/")) == .remoteStatus)
        #expect(JarvisAPI.route(HTTPRequest(method: "POST", path: "/jarvis/answer")) == .remoteAnswer)
        #expect(JarvisAPI.Route.remoteCommand.isRemote)
        #expect(!JarvisAPI.Route.chatCompletions.isRemote)
    }

    @Test func tailscaleHostOnlyForPhoneRoutes() {
        #expect(JarvisAPI.check(post("/jarvis/command", tailnet), route: .remoteCommand, apiKey: "k1") == nil)
        #expect(JarvisAPI.check(post("/v1/chat/completions", tailnet), route: .chatCompletions, apiKey: "k1") == .badHost)
        let local = tailnet.merging(["host": "127.0.0.1:8765"]) { $1 }
        #expect(JarvisAPI.check(post("/jarvis/status", local), route: .remoteStatus, apiKey: "k1") == nil)
    }

    @Test func otherHostsAreRejectedUnlessListed() {
        let evil = tailnet.merging(["host": "evil.example"]) { $1 }
        #expect(JarvisAPI.check(post("/jarvis/command", evil), route: .remoteCommand, apiKey: "k1") == .badHost)
        #expect(JarvisAPI.check(post("/jarvis/command", evil), route: .remoteCommand, apiKey: "k1", remoteHosts: ["Evil.example"]) == nil)
        let bare = tailnet.merging(["host": ".ts.net"]) { $1 }
        #expect(JarvisAPI.check(post("/jarvis/command", bare), route: .remoteCommand, apiKey: "k1") == .badHost)
    }

    @Test func phoneAlwaysNeedsTheKey() {
        #expect(JarvisAPI.check(post("/jarvis/command", tailnet), route: .remoteCommand, apiKey: nil) == .unauthorized)
        #expect(JarvisAPI.check(post("/jarvis/command", tailnet), route: .remoteCommand, apiKey: "") == .unauthorized)
        let wrong = tailnet.merging(["authorization": "Bearer nope"]) { $1 }
        #expect(JarvisAPI.check(post("/jarvis/command", wrong), route: .remoteCommand, apiKey: "k1") == .unauthorized)
        let browser = tailnet.merging(["origin": "https://evil.example"]) { $1 }
        #expect(JarvisAPI.check(post("/jarvis/command", browser), route: .remoteCommand, apiKey: "k1") == .browserOrigin)
        #expect(JarvisAPI.check(HTTPRequest(method: "GET", path: "/jarvis/command", headers: tailnet), route: .remoteCommand, apiKey: "k1") == .method)
    }
}

@Suite struct RemoteJobsTests {
    @Test func lifecycle() throws {
        let jobs = RemoteJobs()
        let id = jobs.create()
        #expect(jobs.snapshot(id) == .init(state: .queued, version: 0))
        jobs.update(id, .working(nil))
        jobs.update(id, .working(nil))
        #expect(jobs.snapshot(id)?.version == 1)
        jobs.update(id, .done("Valmista."))
        jobs.update(id, .failed("myöhässä"))
        #expect(jobs.snapshot(id)?.state == .done("Valmista."))
        #expect(jobs.snapshot("job-nope") == nil)
    }

    @Test func waitReturnsWhenThePhoneHasWork() {
        let jobs = RemoteJobs()
        let id = jobs.create()
        jobs.update(id, .working("Bash · ls"))
        // Nothing to do yet: times out with the current state.
        #expect(jobs.wait(id, timeout: 0.05, poll: 0.01)?.state == .working("Bash · ls"))
        jobs.update(id, .done("Ok"))
        #expect(jobs.wait(id, timeout: 5, poll: 0.01)?.state == .done("Ok"))
        #expect(jobs.wait("job-nope", timeout: 0.01) == nil)
    }

    @Test func waitAfterAnswerSkipsTheOldPrompt() {
        let jobs = RemoteJobs()
        let id = jobs.create()
        let prompt = RemotePrompt(id: "p#0", question: "Saako?", options: ["Salli", "Kiellä"])
        jobs.update(id, .prompt(prompt))
        let before = jobs.snapshot(id)?.version
        #expect(jobs.wait(id, after: before, timeout: 0.05, poll: 0.01)?.state == .prompt(prompt))
        jobs.update(id, .working(nil))
        jobs.update(id, .done("Tehty."))
        #expect(jobs.wait(id, after: before, timeout: 5, poll: 0.01)?.state == .done("Tehty."))
    }

    @Test func oldJobsAreForgotten() {
        let jobs = RemoteJobs()
        let old = jobs.create(now: Date(timeIntervalSince1970: 0))
        _ = jobs.create(now: Date(timeIntervalSince1970: RemoteJobs.keepFor + 1))
        #expect(jobs.snapshot(old) == nil)
    }
}

@Suite struct RemoteAPITests {
    @Test func parsesBodies() {
        #expect(RemoteAPI.commandText(Data(#"{"text":"  Avaa Safari \n"}"#.utf8)) == "Avaa Safari")
        #expect(RemoteAPI.commandText(Data(#"{"text":"  "}"#.utf8)) == nil)
        #expect(RemoteAPI.jobID(Data(#"{"id":"job-1"}"#.utf8)) == "job-1")
        #expect(RemoteAPI.answer(Data(#"{"id":"job-1","prompt_id":"p#0","choice":"Salli"}"#.utf8))
                == .init(jobID: "job-1", promptID: "p#0", choice: "Salli"))
        #expect(RemoteAPI.answer(Data(#"{"id":"job-1"}"#.utf8)) == nil)
    }

    @Test func promptIDsRoundTrip() throws {
        let uuid = UUID()
        let parsed = try #require(RemotePrompt.parse(RemotePrompt.id(request: uuid, index: 2)))
        #expect(parsed.request == uuid)
        #expect(parsed.index == 2)
        #expect(RemotePrompt.parse("nonsense") == nil)
    }

    @Test func onlyAClearYesAllows() {
        #expect(RemotePrompt.isAllow("Salli"))
        #expect(RemotePrompt.isAllow(" kyllä."))
        #expect(!RemotePrompt.isAllow("Kiellä"))
        #expect(!RemotePrompt.isAllow(""))
        #expect(!RemotePrompt.isAllow("salli ei"))
    }

    @Test func bodies() throws {
        let done = try #require(JSONValue.parse(RemoteAPI.body(jobID: "j", state: .done("**Valmis**, katso https://x.fi"))))
        #expect(done["status"]?.string == "done")
        #expect(done["say"]?.string == "Valmis, katso linkki")
        let empty = try #require(JSONValue.parse(RemoteAPI.body(jobID: "j", state: .done(""))))
        #expect(empty["say"]?.string == "Valmis.")
        let prompt = try #require(JSONValue.parse(RemoteAPI.body(jobID: "j", state: .prompt(.init(id: "p#0", question: "Saako?", options: ["Salli", "Kiellä"])))))
        #expect(prompt["status"]?.string == "prompt")
        #expect(prompt["prompt_id"]?.string == "p#0")
        #expect(prompt["options"]?.array?.compactMap(\.string) == ["Salli", "Kiellä"])
        let spoken = try #require(JSONValue.parse(RemoteAPI.body(jobID: "j", state: .prompt(.init(id: "p#0", question: "Bash: mkdir x", options: ["Salli"], spoken: "Jarvis pyytää lupaa: Luo kansio.")))))
        #expect(spoken["say"]?.string == "Jarvis pyytää lupaa: Luo kansio.")
        #expect(spoken["question"]?.string == "Bash: mkdir x")
        let queued = try #require(JSONValue.parse(RemoteAPI.body(jobID: "j", state: .queued)))
        #expect(queued["status"]?.string == "working")
        #expect(queued["say"] == nil)
        let working = try #require(JSONValue.parse(RemoteAPI.body(jobID: "j", state: .working("Bash · ls"))))
        #expect(working["say"] == nil)
        let unknown = try #require(JSONValue.parse(RemoteAPI.unknownJob("j")))
        #expect(unknown["status"]?.string == "failed")
    }
}

@Suite struct ConversationLogTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return c
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func namesFilesByLocalDay() {
        let log = ConversationLog(directory: URL(filePath: "/tmp"), calendar: calendar)
        // 23.30 UTC is already the next day in Helsinki.
        #expect(log.fileName(for: date("2026-11-23T23:30:00Z")) == "2026-11-24.md")
        #expect(log.header(for: date("2026-11-23T10:00:00Z")) == "# Keskustelut 23.11.2026\n")
    }

    @Test func entryKeepsOneParagraph() {
        let log = ConversationLog(directory: URL(filePath: "/tmp"), calendar: calendar)
        let entry = log.entry(command: "Paljonko tilaa?", reply: "Tilaa on 39 gigaa.\n\n# Otsikko\nLoput.",
                              source: .phone, at: date("2026-11-23T13:34:00Z"))
        #expect(entry == "\n## 15.34 · puhelin\n**Sami:** Paljonko tilaa?\n**Jarvis:** Tilaa on 39 gigaa. / # Otsikko / Loput.\n")
    }

    @Test func appendsToDayFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jarvis-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = ConversationLog(directory: dir, calendar: calendar)
        let now = date("2026-11-23T08:00:00Z")
        try log.append(command: "Avaa Safari", reply: "Avasin Safarin.", source: .mac, at: now)
        try log.append(command: "Kiitos", reply: "", source: .phone, at: now.addingTimeInterval(60))
        try log.append(command: "   ", reply: "ohitetaan", source: .mac, at: now)
        let text = try String(contentsOf: dir.appending(path: "2026-11-23.md"), encoding: .utf8)
        #expect(text == """
        # Keskustelut 23.11.2026

        ## 10.00 · Mac
        **Sami:** Avaa Safari
        **Jarvis:** Avasin Safarin.

        ## 10.01 · puhelin
        **Sami:** Kiitos
        **Jarvis:** (ei vastausta)

        """)
    }
}
