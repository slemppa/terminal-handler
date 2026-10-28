import Foundation

/// One Ghostty terminal (a tab or split), as last polled.
public struct TerminalSnapshot: Sendable, Equatable, Identifiable {
    public var id: String
    public var tabID: String
    public var windowID: String
    public var tty: String
    public var cwd: String
    public var title: String
    /// The foreground command when it is not a plain shell, e.g. "npm" or "claude".
    public var foreground: String?

    public init(id: String, tabID: String = "", windowID: String = "", tty: String, cwd: String = "", title: String = "", foreground: String? = nil) {
        self.id = id
        self.tabID = tabID
        self.windowID = windowID
        self.tty = tty
        self.cwd = cwd
        self.title = title
        self.foreground = foreground
    }
}

public enum ClaudeStatus: Sendable, Equatable {
    case idle
    case working(String)
    case done
    case waitingPermission(String)
    case waitingQuestion

    public var isWaiting: Bool {
        switch self {
        case .waitingPermission, .waitingQuestion: true
        default: false
        }
    }
}

public struct ClaudeSession: Sendable, Equatable {
    public var sessionID: String
    public var tty: String
    public var claudePID: Int32?
    public var status: ClaudeStatus
    public var updatedAt: Date
}

public struct AskOption: Sendable, Equatable, Hashable {
    public var label: String
    public var description: String
}

public struct AskQuestion: Sendable, Equatable {
    public var question: String
    public var header: String
    public var options: [AskOption]
    public var multiSelect: Bool
}

public enum RequestKind: Sendable, Equatable {
    case permission(tool: String, detail: String)
    case question([AskQuestion])
}

/// A blocking hook the app is holding until Sami answers or it is released.
public struct PendingRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var tty: String
    public var sessionID: String
    public var kind: RequestKind
    public var payload: JSONValue
    public var createdAt: Date
}

/// Status dot colours, in the spec's alert-level order.
public enum Dot: Sendable, Equatable {
    case orange, blue, green, dimGreen, grey
}

public enum HookDisposition: Sendable, Equatable {
    /// Fire-and-forget event; nothing to answer.
    case none
    /// Blocking event the app will not handle: answer immediately with no output.
    case releaseNow
    /// Blocking event shown in the island until answered or released.
    case hold(PendingRequest)
}

/// How Sami answered a pending request.
public enum Answer: Sendable, Equatable {
    case allow
    case deny
    /// Question text → chosen label(s), comma-joined for multi-select.
    case choices([String: String])
}
