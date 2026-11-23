import Foundation

/// Jarvis's conversation history: every command and answer, appended to one
/// Markdown file per day (`~/Jarvis/loki/2026-11-23.md`).
///
/// The app writes it, not the model, so nothing depends on Claude
/// remembering to log. Jarvis reads it only when asked about the past.
public struct ConversationLog: Sendable {
    public enum Source: String, Sendable {
        case mac = "Mac"
        case phone = "puhelin"
    }

    public var directory: URL
    public var calendar: Calendar

    public init(directory: URL, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
    }

    /// `2026-11-23.md`, in the local day.
    public func fileName(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `# Keskustelut 23.11.2026`, written once at the top of a new day.
    public func header(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "# Keskustelut \(c.day ?? 0).\(c.month ?? 0).\(c.year ?? 0)\n"
    }

    public func entry(command: String, reply: String, source: Source, at date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d.%02d", c.hour ?? 0, c.minute ?? 0)
        return """

        ## \(time) · \(source.rawValue)
        **Sami:** \(Self.oneParagraph(command))
        **Jarvis:** \(Self.oneParagraph(reply))

        """
    }

    /// Appends one exchange; creates the folder and the day's file as needed.
    public func append(command: String, reply: String, source: Source, at date: Date = .now) throws {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: fileName(for: date))
        var text = entry(command: command, reply: reply.isEmpty ? "(ei vastausta)" : reply, source: source, at: date)
        if !FileManager.default.fileExists(atPath: file.path) {
            text = header(for: date) + text
            try Data(text.utf8).write(to: file, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Keeps an entry to one Markdown paragraph: a blank line or a heading
    /// inside an answer would break the day file's structure.
    static func oneParagraph(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
    }
}
