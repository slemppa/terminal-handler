# Terminal Handler: design

Date: 2026-10-28 · Status: waiting for Sami's approval

## Intent

Sami has around eight Ghostty windows/tabs open while working, many of them running Claude Code. He no longer knows which repo and branch is open where, what is happening in each, or which Claude session is waiting for an answer. The goal is a small native Mac app that keeps him up to date at a glance, pings him when Claude asks something, takes him straight to the right terminal, and lets him answer Claude's questions without hunting for the window.

Success: he never cycles through Ghostty windows to find "which one was waiting", and never discovers a stalled Claude session only after minutes have passed.

## Goals

- See every Ghostty terminal at once: repo, branch, and what is happening (Claude working / waiting / idle shell / some other command running).
- Get a clear signal when a Claude session needs him (a permission request, a multiple-choice question, Claude stopping and waiting for the next prompt).
- Jump to the right Ghostty terminal with one click.
- Answer Claude's permission requests and multiple-choice questions straight from the overlay.

## Non-goals (for now)

- iPhone notifications. They may come later, so the app's state model and event stream must not be tied to the UI (see "Future: iPhone").
- Supporting terminals other than Ghostty.
- Distribution (App Store, notarization for others). This is Sami's personal tool.
- Showing terminal contents / scrollback in the app.
- Typing free-form prompts to Claude from the app.

## Anti-goals (a failure even if it technically works)

- The overlay gets in the way: covers content, steals focus, or flickers while he is typing in a terminal.
- Answering from the app breaks or slows the normal terminal workflow. The terminal must stay fully usable on its own; the app is an addition, never a requirement.
- The app shows stale or wrong information (wrong branch, a "waiting" dot that is no longer waiting). A wrong status is worse than no status.
- Heavy resource use. It runs all day.

## Decided with Sami

- **Form:** a black "island" capsule. It was first placed at the top centre over the menu bar. **Changed on 2026-10-28 at Sami's request: it floats above everything and he can drag it anywhere on the screen.** It defaults to the top-right below the menu bar and remembers its position. The list opens downwards in the top half of the screen and upwards in the bottom half. It has three states, all approved from mockups:
  1. **Resting:** a small black pill with one dot per Ghostty terminal. Orange = waiting for Sami, green = working, grey = idle. Plus a short text such as "2 waiting".
  2. **Expanded (hover over the pill, or a global hotkey):** the island springs open into a list. Each row shows a status dot, repo name, branch, a one-line activity summary, and a ⌘1…⌘n shortcut. A click jumps to that Ghostty terminal. Moving the mouse away collapses it.
  3. **Question:** when Claude asks something, the island expands by itself for a moment and shows the repo/branch, the question (for a permission: the command or tool), and buttons ("Allow" / "Deny" / "Open window ↗", or the AskUserQuestion options). If he does not react, it collapses back to the pill and the dot stays orange.
- **Scope:** all Ghostty terminals, not just the ones running Claude.
- **Clicking a row** jumps directly to that Ghostty terminal.
- **Questions** can be answered from the island, or he can jump to the terminal.
- **Native Mac,** following Apple's design language (use the `apple-design` skill; motion with springs, interruptible, respects Reduce Motion).

## Technical facts verified in this session

- Ghostty 1.4.0 is installed and has an AppleScript dictionary (`Ghostty.sdef`). It exposes `window → tab → terminal`. A terminal has `id`, `name`, `working directory`, `pid`, `tty`. Commands include `focus`, `activate window`, `select tab`, `input text`, `send key`. Verified with `osascript`: the terminals' cwd, tty and pid can be read.
- Sami's current setup is actually **one Ghostty window with several tabs** (5 terminals at the time of checking). So the unit the app tracks is a **Ghostty terminal** (tab or split), not an OS window. "Window" in the UI means this unit.
- A Claude Code hook subprocess's parent process is `claude` with the same TTY as the Ghostty terminal (`ps -o tty= -p $PPID` → `ttys008`). **TTY is the key that joins a Claude session to a Ghostty terminal.**
- Claude Code 2.1.312. Hooks (docs: code.claude.com/docs/en/hooks):
  - Common input: `session_id`, `cwd`, `transcript_path`, `hook_event_name`, `permission_mode`.
  - `PermissionRequest` command/HTTP hooks may block and return `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny", "message"?}}}`. Default timeout 600 s. On timeout the output is discarded (expected: the normal terminal prompt then appears; **verify**).
  - `PreToolUse` on `AskUserQuestion` can answer it: `permissionDecision: "allow"` + `updatedInput` echoing `questions` plus `answers: {"<question text>": "<label>"}`.
  - `Notification` has a `notification_type` (`permission_prompt`, `idle_prompt`, `elicitation_dialog`, `agent_needs_input`, …). It cannot block.
  - HTTP hooks exist, but they cannot see the TTY, so **command hooks are used**.
- Toolchain: macOS 26.6, Xcode 27.1, Swift 6.4.

## Architecture (my call; the builder may refine it)

Three parts:

1. **Menu-bar-less agent app (`TerminalHandler.app`)**, SwiftUI + AppKit, `LSUIElement`. It owns all state and the island UI. It runs a small local server on a Unix domain socket in `~/Library/Application Support/TerminalHandler/`.
2. **Hook helper (`th-hook`)**, a small CLI binary inside the app bundle. Claude Code calls it for its hooks. It reads the hook JSON from stdin, finds its own TTY (from the parent `claude` process), adds it plus its pid, and sends everything to the app over the socket. For blocking events it waits for the app's answer and writes it to stdout. **If the app is not running or the socket fails, it exits immediately with no output**, so Claude behaves exactly as without the app (anti-goal: never break the terminal).
3. **Ghostty poller**, inside the app. It polls Ghostty's AppleScript (about once a second, only while Ghostty is running) for terminals: id, tty, cwd, pid, tab/window. For each cwd it resolves the git repo root and branch (reading `.git/HEAD` directly, cached and refreshed with an FSEvents watcher or cheap polling), and the terminal's foreground process (via the tty: `ps -t`), to tell "idle shell" from "npm run dev".

**State model:** `Terminal` (Ghostty id, tty, cwd, repo, branch, foreground process) ⟷ optional `ClaudeSession` (session_id, status: working / waitingPermission / waitingQuestion / idle (Stop) / ended, pending request, last activity text, timestamps), joined by tty. The model lives in a UI-independent layer so an iPhone path can later read the same event stream.

**Status derivation for Claude sessions (hooks):**
- `SessionStart` → session exists, idle.
- `UserPromptSubmit` / `PreToolUse` / `PostToolUse` → working (activity text from tool name + short input, e.g. "Edit · Invoices.swift").
- `PermissionRequest` → waiting (permission). Blocking, see below.
- `PreToolUse` with `AskUserQuestion` → waiting (question). Blocking, see below.
- `Notification` (`idle_prompt` etc.) and `Stop` → "done, waiting for your next prompt" (see the alert levels below).
- `SessionEnd`, or the tty disappearing from Ghostty → session ends.

**Alert levels (decided with Sami):**

| State | Dot | Counted as "waiting" | Auto-expand | Sound + system notification |
|---|---|---|---|---|
| Permission request / AskUserQuestion | orange | yes | yes | yes |
| Claude done, waiting for the next prompt | blue (quiet) | no | no | no |
| Claude working | green | no | no | no |
| Other command running (npm run dev, etc.) | green, dimmer | no | no | no |
| Idle shell / no Claude | grey | no | no | no |

**Scope of the session match (decided with Sami):** Claude always runs directly in Ghostty (no tmux, ssh or other terminals). A hook whose TTY does not match any Ghostty terminal is released at once with no output and ignored.

**Display:** the island starts on the main display. Because it can now be dragged, it may also be dropped on another display, and it is clamped to that display's visible area.

**Answering from the island: "the question is where you are" (my call):**
For `PermissionRequest` and `AskUserQuestion` the hook helper blocks and waits for the app:
- If that Ghostty terminal is **already focused and frontmost** when the question arrives, the app releases the hook at once with no decision → Claude shows its normal prompt in the terminal. The island shows only a subtle cue.
- Otherwise the island opens in its question state. An answer in the island goes back to the hook as allow/deny or as `answers`.
- If Sami goes to that terminal himself (clicks "Open window ↗", or focuses it otherwise) while the question is pending, the app releases the hook with no decision → the normal terminal prompt appears and he answers there.
- Hook timeout set clearly above the app's own wait (for example hook `timeout: 3600`). The app itself never holds a question forever without showing it.
- **Caveat:** Claude still evaluates deny/ask rules after an "allow". That is fine.
- **Verify this first (my call):** the first build step is a spike that tests whether a blocking `PermissionRequest`/`PreToolUse` hook that is released with no output brings back the normal terminal prompt. If it does not, the fallback is: the hook does not block at all (it only reports), the terminal shows its prompt normally, and an answer from the island is typed into the terminal with Ghostty's AppleScript `send key`/`input text` (the number key of the option + Enter). Answering from the island stays in scope in both cases.

**Jumping to a terminal:** Ghostty AppleScript `focus` on the terminal, plus `activate`. Accessibility permissions are not needed for this. AppleScript automation permission (Apple Events → Ghostty) is needed.

**Installing the hooks:** on first launch the app offers to add its hooks to `~/.claude/settings.json` (merging, keeping existing hooks, with a backup), and shows exactly what it adds. Removable from the same place.

## The island (UI details)

- An `NSPanel` (non-activating, `.statusBar`-level or above, joins all Spaces, ignores Mission Control), centred at the top. **It never steals keyboard focus** except when Sami clicks a button in it.
- The pill's height matches the menu bar. Expanding is a spring animation from the pill shape (morph, not fade). It can be interrupted: moving the mouse back during collapse reverses it.
- Hover opens it after a short delay (~150 ms) to avoid accidental opens. The global hotkey toggles it, and ⌘1…⌘n then jumps.
- Question state: auto-expands, a sound + a system notification (UNUserNotification) so it is noticed even when the screen is elsewhere. Several pending questions are shown one at a time, oldest first, with a counter.
- Dark island in both light and dark mode, as in the mockup. Text uses SF Pro / SF Mono, with a monospace font for branches and commands.
- The mockups are in `.superpowers/brainstorm/*/content/overlay.html` (not committed).

## Future: iPhone

Not built now. To keep it open: the state and events live in a model layer independent of the UI. Later, a small relay (for example APNs through his own server, or CloudKit) can subscribe to the same events. Do not design a protocol for this yet.

## Left to the builder

- Project structure (Xcode project vs. SwiftPM + app bundle script), as long as one `xcodebuild`/script builds and launches it.
- Exact polling rates and cache strategies.
- How the activity text is summarised.
- The global hotkey (suggestion: ⌃⌥Space; must be changeable).
- Tests: at least the state model / status derivation and the hook helper's I/O (including "app not running → empty exit").
