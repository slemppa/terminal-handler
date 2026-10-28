import Foundation

/// What `th-hook` sends to the app: the raw hook payload plus the TTY of
/// the `claude` process that ran the hook, which joins it to a Ghostty terminal.
public struct HookEnvelope: Codable, Sendable, Equatable {
    public var tty: String?
    public var claudePID: Int32?
    public var payload: JSONValue

    public init(tty: String?, claudePID: Int32?, payload: JSONValue) {
        self.tty = tty
        self.claudePID = claudePID
        self.payload = payload
    }

    public var eventName: String { payload["hook_event_name"]?.string ?? "" }
    public var sessionID: String { payload["session_id"]?.string ?? "" }
    public var toolName: String? { payload["tool_name"]?.string }
}

/// Events where the hook waits for the app's answer.
public func isBlockingEvent(_ payload: JSONValue) -> Bool {
    switch payload["hook_event_name"]?.string {
    case "PermissionRequest": true
    case "PreToolUse": payload["tool_name"]?.string == "AskUserQuestion"
    default: false
    }
}

public enum HookPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/TerminalHandler", directoryHint: .isDirectory)
    }

    public static var socketPath: String {
        supportDirectory.appending(path: "th.sock").path
    }
}

public enum HookClient {
    /// First line the app sends when it decides to hold a blocking hook.
    public static let holdAck = Data("HOLD".utf8)

    /// Sends one envelope. Returns the reply (possibly empty) for blocking
    /// events, empty data for fire-and-forget ones, or nil on any failure.
    /// A blocking hook only waits indefinitely once the app has acknowledged
    /// it within `ackTimeout`, so a hung app can never stall Claude.
    public static func send(_ envelope: HookEnvelope, socketPath: String, waitForReply: Bool, ackTimeout: TimeInterval = 3) -> Data? {
        guard let fd = UnixSocket.connect(path: socketPath) else { return nil }
        defer { close(fd) }
        var line = (try? JSONEncoder().encode(envelope)) ?? Data()
        line.append(0x0A)
        guard UnixSocket.writeAll(fd: fd, data: line) else { return nil }
        guard waitForReply else { return Data() }
        UnixSocket.setReceiveTimeout(fd: fd, seconds: ackTimeout)
        guard UnixSocket.readLine(fd: fd) == holdAck else { return Data() }
        UnixSocket.setReceiveTimeout(fd: fd, seconds: 0)
        return UnixSocket.readToEOF(fd: fd)
    }
}
