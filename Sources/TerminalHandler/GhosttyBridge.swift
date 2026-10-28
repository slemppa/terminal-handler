import AppKit
import OSLog
import THCore

/// Reads Ghostty's terminals and focuses them through its AppleScript dictionary.
/// Never launches Ghostty: every call first checks that it is running.
/// Scripts run on one dedicated thread so a slow Ghostty or a pending
/// permission prompt can never freeze the island, and NSAppleScript is only
/// ever touched from that single thread.
nonisolated enum GhosttyBridge {
    private static let runner = ScriptThread()

    static let bundleID = "com.mitchellh.ghostty"
    private static let log = Logger(subsystem: "fi.slemppa.TerminalHandler", category: "ghostty")

    struct Snapshot: Sendable {
        var terminals: [TerminalSnapshot]
        var focusedTerminalID: String?
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    // Only touched on `runner`'s thread.
    nonisolated(unsafe) private static let pollScript: NSAppleScript? = {
        let source = """
        set TB to character id 9
        set LF to character id 10
        set out to ""
        with timeout of 3 seconds
        tell application id "\(bundleID)"
            set focusedID to ""
            try
                set focusedID to id of focused terminal of selected tab of front window
            end try
            set out to "F" & TB & focusedID & LF
            repeat with w in windows
                set wid to id of w
                repeat with t in tabs of w
                    set tid to id of t
                    repeat with term in terminals of t
                        set out to out & "T" & TB & wid & TB & tid & TB & (id of term) & TB & (tty of term) & TB & (working directory of term) & TB & (name of term) & LF
                    end repeat
                end repeat
            end repeat
        end tell
        end timeout
        return out
        """
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        if let error { log.error("compile failed: \(error, privacy: .public)") }
        return script
    }()

    /// Nil when Ghostty is not running or scripting is not permitted.
    static func snapshot() async -> Snapshot? {
        guard isRunning else { return nil }
        return await withCheckedContinuation { continuation in
            runner.enqueue { continuation.resume(returning: runPoll()) }
        }
    }

    private static func runPoll() -> Snapshot? {
        guard let script = pollScript else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            log.error("poll failed: \(error, privacy: .public)")
            return nil
        }
        return parse(result.stringValue ?? "")
    }

    static func parse(_ text: String) -> Snapshot {
        var terminals: [TerminalSnapshot] = []
        var focused: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "F", f.count >= 2 {
                focused = f[1].isEmpty ? nil : f[1]
            } else if f.first == "T", f.count >= 7 {
                let tty = f[4].replacingOccurrences(of: "/dev/", with: "")
                terminals.append(TerminalSnapshot(
                    id: f[3], tabID: f[2], windowID: f[1], tty: tty, cwd: f[5],
                    title: f[6...].joined(separator: "\t")))
            }
        }
        return Snapshot(terminals: terminals, focusedTerminalID: focused)
    }

    static func focus(terminalID: String) {
        guard isRunning else { return }
        runner.enqueue(first: true) { runFocus(terminalID) }
    }

    private static func runFocus(_ terminalID: String) {
        let escaped = terminalID.replacingOccurrences(of: "\"", with: "")
        let source = """
        tell application id "\(bundleID)"
            focus terminal id "\(escaped)"
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log.error("focus failed: \(error, privacy: .public)") }
    }
}

/// A single long-lived thread that runs jobs in order. Focus requests jump
/// the queue so jumping to a terminal never waits behind a poll.
nonisolated final class ScriptThread: @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []

    init() {
        let thread = Thread { [unowned self] in self.loop() }
        thread.name = "fi.slemppa.TerminalHandler.applescript"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func enqueue(first: Bool = false, _ job: @escaping @Sendable () -> Void) {
        condition.lock()
        if first { jobs.insert(job, at: 0) } else { jobs.append(job) }
        condition.signal()
        condition.unlock()
    }

    private func loop() -> Never {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }
}
