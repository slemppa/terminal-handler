import Foundation

/// Adds and removes Terminal Handler's entries in `~/.claude/settings.json`,
/// leaving every other hook untouched. Our entries are recognised by their
/// exact command string.
public enum HookInstaller {
    struct Entry { var event: String; var matcher: String?; var timeout: Int }

    static let entries: [Entry] = [
        Entry(event: "SessionStart", matcher: nil, timeout: 10),
        Entry(event: "SessionEnd", matcher: nil, timeout: 10),
        Entry(event: "UserPromptSubmit", matcher: nil, timeout: 10),
        Entry(event: "PreToolUse", matcher: nil, timeout: 10),
        Entry(event: "PreToolUse", matcher: "AskUserQuestion", timeout: 3600),
        Entry(event: "PostToolUse", matcher: nil, timeout: 10),
        Entry(event: "PermissionRequest", matcher: nil, timeout: 3600),
        Entry(event: "Notification", matcher: nil, timeout: 10),
        Entry(event: "Stop", matcher: nil, timeout: 10),
    ]

    /// The quoted command line Claude runs.
    public static func command(forHelperAt path: String) -> String {
        "\"\(path)\""
    }

    public static func install(into settings: JSONValue, command: String) -> JSONValue {
        var root = uninstall(from: settings, command: command).object ?? [:]
        var hooks = root["hooks"]?.object ?? [:]
        for entry in entries {
            var group: [String: JSONValue] = [
                "hooks": .array([.object([
                    "type": .string("command"),
                    "command": .string(command),
                    "timeout": .number(Double(entry.timeout)),
                ])]),
            ]
            if let matcher = entry.matcher { group["matcher"] = .string(matcher) }
            hooks[entry.event] = .array((hooks[entry.event]?.array ?? []) + [.object(group)])
        }
        root["hooks"] = .object(hooks)
        return .object(root)
    }

    public static func uninstall(from settings: JSONValue, command: String) -> JSONValue {
        guard var root = settings.object else { return .object([:]) }
        guard var hooks = root["hooks"]?.object else { return settings }
        for (event, groups) in hooks {
            let kept: [JSONValue] = (groups.array ?? []).compactMap { group in
                guard var obj = group.object else { return group }
                let inner = (obj["hooks"]?.array ?? []).filter { $0["command"]?.string != command }
                if inner.isEmpty { return nil }
                obj["hooks"] = .array(inner)
                return .object(obj)
            }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        root["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        return .object(root)
    }

    public static func isInstalled(_ settings: JSONValue, command: String) -> Bool {
        let hooks = settings["hooks"]
        return entries.allSatisfy { entry in
            (hooks?[entry.event]?.array ?? []).contains { group in
                group["matcher"]?.string == entry.matcher
                    && (group["hooks"]?.array ?? []).contains { $0["command"]?.string == command }
            }
        }
    }

    // MARK: File I/O

    public static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    public static func readSettings(at url: URL = settingsURL) -> JSONValue {
        guard let data = try? Data(contentsOf: url) else { return .object([:]) }
        return JSONValue.parse(data) ?? .object([:])
    }

    /// Writes the new settings after saving a timestamped backup next to the file.
    public static func write(_ settings: JSONValue, to url: URL = settingsURL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: .current))
            let backup = url.deletingLastPathComponent().appending(path: "settings.json.th-backup-\(stamp)")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        try settings.encoded(pretty: true).write(to: url, options: .atomic)
    }
}
