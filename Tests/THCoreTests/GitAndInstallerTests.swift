import Foundation
import Testing
@testable import THCore

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "th-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct GitInfoTests {
    @Test func branchFromHead() throws {
        let repo = try makeTempDir().appending(path: "rascal-crm")
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appending(path: "src/deep"), withIntermediateDirectories: true)
        try "ref: refs/heads/feat/invoices\n".write(to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        #expect(GitInfo.resolve(cwd: repo.appending(path: "src/deep").path) == GitInfo(repoName: "rascal-crm", branch: "feat/invoices"))
    }

    @Test func detachedHead() throws {
        let repo = try makeTempDir()
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        try "0123456789abcdef\n".write(to: repo.appending(path: ".git/HEAD"), atomically: true, encoding: .utf8)
        #expect(GitInfo.resolve(cwd: repo.path)?.branch == "0123456")
    }

    @Test func worktreeGitFile() throws {
        let base = try makeTempDir()
        let gitDir = base.appending(path: "main/.git/worktrees/wt")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try "ref: refs/heads/wt-branch\n".write(to: gitDir.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        let wt = base.appending(path: "wt")
        try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
        try "gitdir: \(gitDir.path)\n".write(to: wt.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(GitInfo.resolve(cwd: wt.path) == GitInfo(repoName: "wt", branch: "wt-branch"))
    }

    @Test func notARepo() throws {
        #expect(GitInfo.resolve(cwd: try makeTempDir().path) == nil)
    }
}

@Suite struct HookInstallerTests {
    let ours = HookInstaller.command(forHelperAt: "/Apps/TerminalHandler.app/Contents/MacOS/th-hook")
    let foreign: JSONValue = .object([
        "model": .string("opus"),
        "hooks": .object([
            "Stop": .array([.object(["hooks": .array([.object(["type": .string("command"), "command": .string("coucou")])])])]),
        ]),
    ])

    @Test func preservesForeignHooks() {
        let installed = HookInstaller.install(into: foreign, command: ours)
        #expect(installed["model"] == .string("opus"))
        let stop = installed["hooks"]?["Stop"]?.array ?? []
        #expect(stop.count == 2)
        #expect(stop.first?["hooks"]?.array?.first?["command"] == .string("coucou"))
        #expect(HookInstaller.isInstalled(installed, command: ours))
        #expect(!HookInstaller.isInstalled(foreign, command: ours))
    }

    @Test func installTwiceIsIdempotent() {
        let once = HookInstaller.install(into: foreign, command: ours)
        #expect(HookInstaller.install(into: once, command: ours) == once)
    }

    @Test func uninstallRemovesOnlyOurs() {
        let installed = HookInstaller.install(into: foreign, command: ours)
        #expect(HookInstaller.uninstall(from: installed, command: ours) == foreign)
    }

    @Test func blockingEntriesHaveLongTimeout() {
        let installed = HookInstaller.install(into: .object([:]), command: ours)
        let permission = installed["hooks"]?["PermissionRequest"]?.array?.first?["hooks"]?.array?.first
        #expect(permission?["timeout"] == .int(3600))
        let pre = installed["hooks"]?["PreToolUse"]?.array ?? []
        #expect(pre.count == 1)
        #expect(pre.first?["hooks"]?.array?.first?["timeout"] == .int(3600))
    }

    @Test func unparsableSettingsThrow() throws {
        let url = try makeTempDir().appending(path: "settings.json")
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: HookInstaller.UnreadableSettings.self) { try HookInstaller.readSettings(at: url) }
    }

    @Test func largeIntegersSurviveRoundTrip() throws {
        let data = Data(#"{"big":9007199254740993,"f":0.5,"b":true}"#.utf8)
        let value = try #require(JSONValue.parse(data))
        #expect(value["big"] == .int(9007199254740993))
        #expect(JSONValue.parse(value.encoded()) == value)
    }

    @Test func fileWriteKeepsBackup() throws {
        let dir = try makeTempDir()
        let url = dir.appending(path: "settings.json")
        try foreign.encoded().write(to: url)
        try HookInstaller.write(HookInstaller.install(into: try HookInstaller.readSettings(at: url), command: ours), to: url)
        #expect(HookInstaller.isInstalled(try HookInstaller.readSettings(at: url), command: ours))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("settings.json.th-backup-") }
        #expect(backups.count == 1)
    }
}
