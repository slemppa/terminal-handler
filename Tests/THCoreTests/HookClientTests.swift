import Foundation
import Testing
@testable import THCore

private func tempSocketPath() -> String {
    "/tmp/th-test-\(UUID().uuidString.prefix(8)).sock"
}

/// Accepts one connection on a background thread and runs `handler` with it.
private func serveOnce(at path: String, _ handler: @escaping @Sendable (Int32) -> Void) throws -> Thread {
    let listener = try #require(UnixSocket.listen(path: path))
    let thread = Thread {
        if let client = UnixSocket.accept(fd: listener) {
            handler(client)
            close(client)
        }
        close(listener)
        unlink(path)
    }
    thread.start()
    return thread
}

private let samplePayload: JSONValue = .object([
    "hook_event_name": .string("PermissionRequest"),
    "session_id": .string("s1"),
])

@Suite struct HookClientTests {
    @Test func missingSocketReturnsNil() {
        let start = Date()
        let reply = HookClient.send(
            HookEnvelope(tty: "ttys001", claudePID: 1, payload: samplePayload),
            socketPath: tempSocketPath(), waitForReply: true)
        #expect(reply == nil)
        #expect(Date().timeIntervalSince(start) < 0.5)
    }

    @Test func roundTripReply() throws {
        let path = tempSocketPath()
        _ = try serveOnce(at: path) { fd in
            let line = UnixSocket.readLine(fd: fd)
            let env = line.flatMap { try? JSONDecoder().decode(HookEnvelope.self, from: $0) }
            if env?.tty == "ttys009" {
                UnixSocket.writeAll(fd: fd, data: Data("HOLD\n".utf8))
                UnixSocket.writeAll(fd: fd, data: Data(#"{"ok":1}"#.utf8))
            }
        }
        let reply = HookClient.send(
            HookEnvelope(tty: "ttys009", claudePID: 1, payload: samplePayload),
            socketPath: path, waitForReply: true)
        #expect(reply == Data(#"{"ok":1}"#.utf8))
    }

    @Test func serverClosesReturnsEmpty() throws {
        let path = tempSocketPath()
        _ = try serveOnce(at: path) { fd in _ = UnixSocket.readLine(fd: fd) }
        let reply = HookClient.send(
            HookEnvelope(tty: nil, claudePID: nil, payload: samplePayload),
            socketPath: path, waitForReply: true)
        #expect(reply?.isEmpty ?? true)
    }

    @Test func hungAppTimesOutEmpty() throws {
        let path = tempSocketPath()
        _ = try serveOnce(at: path) { fd in
            _ = UnixSocket.readLine(fd: fd)
            Thread.sleep(forTimeInterval: 1.5) // never acknowledges
        }
        let start = Date()
        let reply = HookClient.send(
            HookEnvelope(tty: "ttys009", claudePID: 1, payload: samplePayload),
            socketPath: path, waitForReply: true, ackTimeout: 0.3)
        #expect(reply?.isEmpty ?? true)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test(arguments: [
        ("PermissionRequest", nil as String?, true),
        ("PreToolUse", "Bash", false),
        ("PreToolUse", "AskUserQuestion", true),
        ("Stop", nil, false),
    ])
    func blockingClassification(event: String, tool: String?, expected: Bool) {
        var obj: [String: JSONValue] = ["hook_event_name": .string(event)]
        if let tool { obj["tool_name"] = .string(tool) }
        #expect(isBlockingEvent(.object(obj)) == expected)
    }

    @Test func ttyOfThisProcessTreeIsFoundOrNil() {
        // Under `swift test` in a terminal there is a TTY; under CI there may be none.
        if let found = controllingTTY(startingAt: getpid()) {
            #expect(found.tty.hasPrefix("tty"))
        }
    }
}
