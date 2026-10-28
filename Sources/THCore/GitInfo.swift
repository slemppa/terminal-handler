import Foundation

public struct GitInfo: Sendable, Equatable {
    public var repoName: String
    public var branch: String

    /// Finds the enclosing repo by reading `.git` directly (no `git` process),
    /// so it is cheap enough to run on every poll.
    public static func resolve(cwd: String) -> GitInfo? {
        let fm = FileManager.default
        var dir = URL(filePath: cwd, directoryHint: .isDirectory).standardizedFileURL
        while true {
            let dotGit = dir.appending(path: ".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                let gitDir = isDir.boolValue ? dotGit : worktreeGitDir(dotGit, relativeTo: dir)
                guard let gitDir, let branch = readBranch(gitDir) else { return nil }
                return GitInfo(repoName: dir.lastPathComponent, branch: branch)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// A worktree or submodule has a `.git` file: `gitdir: <path>`.
    private static func worktreeGitDir(_ file: URL, relativeTo base: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/") ? URL(filePath: path) : base.appending(path: path)
    }

    private static func readBranch(_ gitDir: URL) -> String? {
        guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("ref: refs/heads/") { return String(trimmed.dropFirst("ref: refs/heads/".count)) }
        if trimmed.hasPrefix("ref: ") { return String(trimmed.dropFirst(5)) }
        return String(trimmed.prefix(7))
    }
}
