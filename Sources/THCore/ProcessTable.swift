import Foundation

/// Foreground commands per TTY, from one `ps` call per poll.
public enum ProcessTable {
    static let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "login", "th-hook"]

    /// TTY name (e.g. "ttys008") → the foreground command that is not a shell.
    @concurrent
    public static func foreground() async -> [String: String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,tty=,stat=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ output: String) -> [String: String] {
        var best: [String: (pid: Int, name: String)] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int(parts[0]), parts[1] != "??", parts[2].contains("+") else { continue }
            let name = commandName(String(parts[3]))
            guard !shells.contains(name) else { continue }
            let tty = String(parts[1])
            // `claude` wins; otherwise the oldest (lowest pid) foreground process.
            if let current = best[tty], current.name == "claude" || (name != "claude" && current.pid < pid) { continue }
            best[tty] = (pid, name)
        }
        return best.mapValues(\.name)
    }

    private static func commandName(_ comm: String) -> String {
        if comm.hasPrefix("/") { return (comm as NSString).lastPathComponent }
        return comm.split(separator: " ").first.map(String.init) ?? comm
    }
}
