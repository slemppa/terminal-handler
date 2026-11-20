import Foundation

// MARK: - Speech text

/// Turns an assistant answer into something worth reading aloud. Mirrors the
/// rules of `~/Jarvis/.claude/hooks/puhu.sh` so the app and a terminal
/// session sound the same.
public enum SpeechText {
    public static let limit = 1500

    public static func clean(_ text: String) -> String {
        var s = text
        s = replace(s, #"```.*?```"#, " ", options: [.dotMatchesLineSeparators])       // code blocks
        s = replace(s, #"`([^`]*)`"#, "$1")                                              // inline code
        s = replace(s, #"\[([^\]]+)\]\([^)]+\)"#, "$1")                                  // markdown links
        s = replace(s, #"https?://\S+"#, "linkki")                                       // bare URLs
        s = replace(s, #"^\s*\|.*\|\s*$"#, "", options: [.anchorsMatchLines])            // tables
        s = replace(s, #"^\s*#+\s*"#, "", options: [.anchorsMatchLines])                 // headings
        s = replace(s, #"\*\*|__|\*"#, "")                                                // emphasis
        s = replace(s, #"^\s*[-*>]\s+"#, "", options: [.anchorsMatchLines])              // bullets, quotes
        s = replace(s, #"\n{2,}"#, ". ")
        s = replace(s, #"\s+"#, " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) : s
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String,
                                options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

// MARK: - Session continuity

/// A spoken conversation continues while the last turn ended recently;
/// after a pause Jarvis starts fresh, so old context does not leak in.
public struct JarvisSessionPolicy: Sendable, Equatable {
    public static let idleLimit: TimeInterval = 15 * 60

    public var sessionID: String?
    public var lastTurnAt: Date?

    public init(sessionID: String? = nil, lastTurnAt: Date? = nil) {
        self.sessionID = sessionID
        self.lastTurnAt = lastTurnAt
    }

    /// The session to `--resume`, or nil for a fresh one.
    public func resumeID(now: Date = .now, idleLimit: TimeInterval = idleLimit) -> String? {
        guard let sessionID, !sessionID.isEmpty, let lastTurnAt else { return nil }
        let idle = now.timeIntervalSince(lastTurnAt)
        return idle >= 0 && idle < idleLimit ? sessionID : nil
    }

    public mutating func turnEnded(sessionID: String?, at date: Date = .now) {
        if let sessionID, !sessionID.isEmpty { self.sessionID = sessionID }
        lastTurnAt = date
    }

    public mutating func reset() {
        sessionID = nil
        lastTurnAt = nil
    }
}

// MARK: - claude -p --output-format stream-json

public enum ClaudeStreamEvent: Sendable, Equatable {
    case started(sessionID: String)
    /// A text block of an assistant message.
    case text(String)
    /// A tool call, summarised for the island ("Bash · df -h").
    case tool(String)
    case result(text: String, sessionID: String?, isError: Bool)
}

public enum ClaudeStream {
    /// Parses one line of stream-json output. Unknown or irrelevant lines
    /// (hooks, rate limits, tool results) give an empty list.
    public static func events(fromLine line: Data) -> [ClaudeStreamEvent] {
        guard let json = JSONValue.parse(line) else { return [] }
        switch json["type"]?.string {
        case "system":
            guard json["subtype"]?.string == "init", let id = json["session_id"]?.string else { return [] }
            return [.started(sessionID: id)]
        case "assistant":
            guard json["parent_tool_use_id"] == nil || json["parent_tool_use_id"] == .null else { return [] }
            return (json["message"]?["content"]?.array ?? []).compactMap { block in
                switch block["type"]?.string {
                case "text":
                    let text = block["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return text.isEmpty ? nil : .text(text)
                case "tool_use":
                    return .tool(activitySummary(tool: block["name"]?.string ?? "", input: block["input"] ?? .null))
                default:
                    return nil
                }
            }
        case "result":
            let isError = json["is_error"]?.bool ?? (json["subtype"]?.string != "success")
            return [.result(text: json["result"]?.string ?? "", sessionID: json["session_id"]?.string, isError: isError)]
        default:
            return []
        }
    }
}

/// Splits a byte stream into newline-terminated lines.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        return lines
    }

    /// Whatever is left after the stream closed.
    public mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}
