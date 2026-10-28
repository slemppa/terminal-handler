# Terminal Handler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS agent app that shows every Ghostty terminal in a Dynamic Island–style overlay, tracks Claude Code sessions through hooks, and lets Sami answer permission requests and AskUserQuestion prompts from the island.

**Architecture:** SwiftPM package with three targets: `THCore` (pure, tested model and protocol code), `th-hook` (a tiny CLI that Claude Code runs as a hook and that forwards to the app over a Unix socket), and `TerminalHandler` (the AppKit + SwiftUI app: socket server, Ghostty AppleScript poller, island panel). `scripts/bundle.sh` assembles and signs `TerminalHandler.app` with `th-hook` in `Contents/MacOS`.

**Tech Stack:** Swift 6.4, SwiftUI + AppKit, Swift Testing, POSIX Unix sockets, NSAppleScript, Carbon `RegisterEventHotKey`, UserNotifications.

**Spec:** `docs/superpowers/specs/2026-10-28-terminal-handler-design.md`

## Global Constraints

- macOS 26 deployment target, Swift 6 language mode (strict concurrency).
- No third-party dependencies.
- The hook helper must never break Claude: if the socket is missing, connecting fails, or the app closes the connection, it exits 0 with no stdout.
- The island never steals keyboard focus, except while it is opened with the hotkey or a button in it is clicked.
- Main display only (`NSScreen.screens.first`, the one with the menu bar).
- Alert levels exactly as in the spec table: orange (permission/question, counted, auto-expand, sound + notification), blue (done), green (Claude working), dim green (other command), grey (idle).
- UI copy in Finnish.
- Socket: `~/Library/Application Support/TerminalHandler/th.sock`.
- Hook timeouts: `PermissionRequest` and `PreToolUse` (matcher `AskUserQuestion`) 3600 s, all others 10 s.

## Review Focus

1. The app is not running, or is quit while a request is pending → Claude shows its normal prompt immediately (helper sees ECONNREFUSED/EOF and exits empty). Test: `HookClientTests.missingSocketReturnsNil`, `serverClosesReturnsNil`.
2. A hook arrives from a TTY that is not a Ghostty terminal (VS Code, `claude -p`) → released immediately, never shown. Test: `SessionStoreTests.unknownTTYIsReleased`.
3. Sami answers in the terminal after the release → the stale question disappears from the island (`PostToolUse`/`Stop`/`UserPromptSubmit` clears the pending request). Test: `SessionStoreTests.laterEventClearsPending`.
4. A Claude process exits without `SessionEnd` (crash, closed tab) → its session disappears instead of staying orange. Test: `SessionStoreTests.sessionDroppedWhenClaudeGone`.
5. Existing hooks in `settings.json` (for example Coucou's) are kept untouched and install is idempotent. Test: `HookInstallerTests.preservesForeignHooks`, `installTwiceIsIdempotent`.

---

### Task 1: Package skeleton + hook wire protocol and helper

**Files:**
- Create: `Package.swift`, `Sources/THCore/HookWire.swift`, `Sources/THCore/UnixSocket.swift`, `Sources/THCore/ProcessTTY.swift`, `Sources/th-hook/main.swift`, `Tests/THCoreTests/HookClientTests.swift`

**Interfaces:**
- Produces:
  - `struct HookEnvelope: Codable, Sendable { var tty: String?; var claudePID: Int32?; var payload: JSONValue }`
  - `enum JSONValue: Codable, Sendable, Equatable` (null/bool/number/string/array/object) with subscript `[String] -> JSONValue?` and `.string`.
  - `func isBlockingEvent(_ payload: JSONValue) -> Bool`: true for `PermissionRequest`, and for `PreToolUse` with `tool_name == "AskUserQuestion"`.
  - `enum HookClient { static func send(_ env: HookEnvelope, socketPath: String, waitForReply: Bool) -> Data? }`: returns the reply bytes (may be empty), or nil on any failure.
  - `func controllingTTY(startingAt pid: pid_t, maxDepth: Int = 6) -> (tty: String, pid: pid_t)?`: walks parents with `sysctl(KERN_PROC_PID)` and returns the first ancestor with a tty (`devname(e_tdev, S_IFCHR)`, e.g. `ttys008`).
  - `UnixSocket.listen(path:) -> Int32`, `UnixSocket.connect(path:timeout:) -> Int32?`, `readLine(fd:) -> Data?`, `writeAll(fd:data:)`.
- Wire format: the helper writes one JSON line (`HookEnvelope`). For blocking events it then reads until EOF; the reply is the raw stdout JSON (possibly empty). For non-blocking events it closes right after writing.

- [ ] Tests: `missingSocketReturnsNil` (nonexistent path → nil within 0.5 s), `roundTripReply` (test server echoes `{"ok":1}` → client gets those bytes), `serverClosesReturnsNil` (server accepts then closes → empty/nil), `blockingClassification` (PermissionRequest true; PreToolUse+Bash false; PreToolUse+AskUserQuestion true; Stop false).
- [ ] Implement; `swift test` passes.
- [ ] `th-hook`: read stdin, build the envelope from `controllingTTY(getppid())`, send; print the reply if it is non-empty; always `exit(0)`.
- [ ] Commit.

### Task 2: Session store (status derivation)

**Files:**
- Create: `Sources/THCore/Model.swift`, `Sources/THCore/SessionStore.swift`, `Tests/THCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct TerminalSnapshot: Sendable, Equatable { id, tabID, windowID: String; tty: String; cwd: String; title: String; foreground: String? /* non-shell fg command */; claudeRunning: Bool }`
  - `enum ClaudeStatus: Equatable, Sendable { case idle, working(String), done, waitingPermission, waitingQuestion }`
  - `struct PendingRequest: Identifiable, Sendable { id: UUID; tty: String; sessionID: String; kind: .permission(tool: String, detail: String) | .question([AskQuestion]); payload: JSONValue }`
  - `struct AskQuestion: Sendable, Equatable { question, header: String; options: [(label, description)]; multiSelect: Bool }`
  - `enum Dot { case orange, blue, green, dimGreen, grey }`
  - `struct SessionStore` (value type, `mutating`):
    - `updateTerminals(_ [TerminalSnapshot])`: drops sessions whose tty is gone or whose tty no longer has `claudeRunning`; returns IDs of pending requests that became orphaned.
    - `apply(_ env: HookEnvelope, requestID: UUID?) -> HookDisposition` where `enum HookDisposition { case none, releaseNow, hold(PendingRequest) }`. Unknown tty or blocking event while that terminal is focused → `.releaseNow`.
    - `resolve(_ id: UUID)`, `pending: [PendingRequest]` (oldest first), `dot(for terminalID) -> Dot`, `activity(for terminalID) -> String`, `waitingCount: Int`.
    - `focusedTTY: String?` (set by the poller; nil when Ghostty is not frontmost).
- Status rules from the spec: SessionStart → idle; UserPromptSubmit/PreToolUse/PostToolUse → working(summary); PermissionRequest → waitingPermission; PreToolUse AskUserQuestion → waitingQuestion; Stop or Notification `idle_prompt` → done; SessionEnd → remove. Any non-blocking event for a session clears that session's pending requests (returned so the app can release them).
- Activity summary: `"<Tool> · <short arg>"` (Bash → first 40 chars of the command, Edit/Write/Read → file name, otherwise the tool name).

- [ ] Tests: `unknownTTYIsReleased`, `focusedTerminalIsReleased`, `permissionHolds`, `laterEventClearsPending`, `sessionDroppedWhenClaudeGone`, `dotPriority` (waiting > working > done > fg command > idle), `waitingCountCountsOnlyOrange`, `bashActivitySummary`.
- [ ] Implement; tests pass. Commit.

### Task 3: Git info + hook installer

**Files:**
- Create: `Sources/THCore/GitInfo.swift`, `Sources/THCore/HookInstaller.swift`, `Tests/THCoreTests/GitInfoTests.swift`, `Tests/THCoreTests/HookInstallerTests.swift`

**Interfaces:**
- `struct GitInfo: Equatable, Sendable { repoName: String; branch: String }`, `static func resolve(cwd: String) -> GitInfo?`: walks up to the `.git` dir or file (worktree `gitdir:`), reads `HEAD` (`ref: refs/heads/x` → `x`, detached → 7-char sha).
- `enum HookInstaller { static func install(into: JSONValue, command: String) -> JSONValue; static func uninstall(from: JSONValue, command: String) -> JSONValue; static func isInstalled(_: JSONValue, command: String) -> Bool }`. Events: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse (two entries: all tools at 10 s, plus matcher `AskUserQuestion` at 3600 s), PostToolUse, PermissionRequest (3600 s), Notification, Stop. Our entries are recognized by the exact command string.
- Plus file I/O: `installFile(at: URL, command:)` writes a backup `settings.json.th-backup-<yyyyMMdd-HHmmss>` first.

- [ ] Tests: `branchFromHead`, `detachedHead`, `worktreeGitFile`, `notARepo` (temp dirs); `preservesForeignHooks`, `installTwiceIsIdempotent`, `uninstallRemovesOnlyOurs`.
- [ ] Implement; tests pass. Commit.

### Task 4: App: socket server, Ghostty bridge, app state

**Files:**
- Create: `Sources/TerminalHandler/TerminalHandlerApp.swift`, `AppModel.swift`, `HookServer.swift`, `GhosttyBridge.swift`, `ProcessTable.swift`, `Notifier.swift`

**Interfaces:**
- `@MainActor @Observable final class AppModel`: owns `SessionStore`, `terminals: [TerminalRow]`, `pending`, and `answer(_ id: UUID, with: Answer)` where `enum Answer { case allow, deny, choices([String: String]) }`; `release(_ id:)`; `jump(to terminalID:)`.
- `HookServer`: accept loop on a background thread; each line → `AppModel.handle(envelope, connection)`; `Connection.reply(Data)` writes and closes, at most once.
- `GhosttyBridge.snapshot() -> (terminals, focusedTerminalID?)`: only when Ghostty is running (`NSRunningApplication` bundle id `com.mitchellh.ghostty`); never launches Ghostty. One compiled NSAppleScript returning tab/linefeed-separated rows; runs on the main actor every 1.5 s. `focus(terminalID:)` runs `focus terminal id "<id>"` and `activate`.
- `ProcessTable.foreground() -> [tty: (command, isClaude)]` from a single `ps -A -o tty=,stat=,comm=` (rows with `+` in stat; shells zsh/bash/fish/login/-zsh are ignored).
- Reply JSON exactly:
  - allow permission: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  - deny: `…"decision":{"behavior":"deny","message":"Kielletty Terminal Handlerista"}}}`
  - question: `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":<tool_input + "answers">}}`
  - release: empty reply.
- `Notifier`: `NSSound(named: "Glass")` + `UNUserNotificationCenter` notification "<repo> kysyy" when a hold starts.

- [ ] `swift build` passes. Commit.

### Task 5: The island

**Files:**
- Create: `Sources/TerminalHandler/IslandPanel.swift`, `IslandView.swift`, `Hotkey.swift`

**Interfaces:**
- `IslandPanel: NSPanel`: borderless, `.nonactivatingPanel`, clear background, level `.statusBar`, `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, fixed 460×420 frame centred at the top of the main screen; `canBecomeKey` true. A 30 Hz mouse timer toggles `ignoresMouseEvents` so that only the island's current shape is clickable, and drives hover (open after 150 ms inside the pill, close 300 ms after leaving).
- `IslandView`: three states (`.pill`, `.list`, `.question`), one black `UnevenRoundedRectangle` (bottom radius 14 → 22) morphing with `.spring(duration: 0.35, bounce: 0.2)`, Reduce Motion → crossfade. Pill: one dot per terminal + "N odottaa". List rows: dot, repo, branch (SF Mono), activity, `⌘n`. Question: repo/branch, the permission tool + command, or AskUserQuestion options, buttons "Salli" / "Kiellä" / "Avaa ikkuna ↗".
- `Hotkey`: Carbon ⌃⌥Space by default; the key code and modifiers are read from UserDefaults `hotkeyKeyCode` / `hotkeyModifiers`. While open via the hotkey the panel is key: ⌘1…⌘9 jump, Esc closes.
- Right-click on the island → menu: "Asenna Claude-hookit" / "Poista Claude-hookit", "Lopeta".
- First launch with no hooks installed → NSAlert showing the exact hook JSON, "Asenna" / "Ei nyt".

- [ ] `scripts/bundle.sh` builds release, assembles `build/TerminalHandler.app` (Info.plist: `LSUIElement`, `NSAppleEventsUsageDescription`, bundle id `fi.slemppa.TerminalHandler`), signs with the Apple Development identity, and copies it to `~/Applications`.
- [ ] Launch it; screenshot to verify the pill, the list and a question (`th-hook` fed a synthetic PermissionRequest for a real Ghostty tty). Commit.

### Task 6: End-to-end verification

- [ ] Install the hooks, start a real `claude` in a new Ghostty tab, trigger a permission prompt: it appears in the island; "Salli" runs the command; focusing the tab releases it to the terminal prompt (verifies the spec's open question; if it fails, switch to the `send key` fallback described in the spec).
- [ ] Quit the app with a pending question → the terminal prompt appears.
- [ ] Commit; write a README with install/uninstall steps.
