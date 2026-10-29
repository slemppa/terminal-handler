# Terminal Handler

A small floating island for macOS that keeps you on top of every [Ghostty](https://ghostty.org) terminal and every [Claude Code](https://claude.com/claude-code) session you have open.

- **One dot per terminal:** orange = Claude is waiting for you, blue = Claude finished its turn, green = Claude is working, dim green = some other command is running, grey = idle.
- **Hover to expand:** see each terminal's repo, git branch and what it is doing. Click a row to jump straight to that Ghostty tab.
- **Answer Claude from the island:** permission requests (Allow / Deny) and `AskUserQuestion` multiple-choice questions pop open the island with a sound and a notification.
- **The question follows you:** if you go to the terminal yourself (or click *Open window ↗*), the question is handed back to Claude's own prompt.
- **Drag it anywhere.** It floats above all apps and Spaces and remembers its position.
- **Never gets in Claude's way:** if the app isn't running, hangs, or is quit mid-question, Claude carries on exactly as without it (the hook gives up after 3 s without an acknowledgement, and held questions are returned after 30 min).

> The UI is currently in Finnish. Pull requests for localization are welcome.

## Requirements

- macOS 26 or later
- Ghostty 1.4 or later (uses its AppleScript dictionary)
- Claude Code with hooks (tested with 2.1.x)
- Xcode / Swift 6.2+ toolchain to build

## Build and install

```sh
git clone https://github.com/slemppa/terminal-handler.git
cd terminal-handler
scripts/bundle.sh          # builds, signs (Apple Development identity if found, else ad-hoc) and installs ~/Applications/TerminalHandler.app
open ~/Applications/TerminalHandler.app
```

On first launch:

1. macOS asks for permission to control Ghostty. Allow it.
2. Right-click the island → **Asenna Claude-hookit…** (*Install Claude hooks*). You see exactly what is added to `~/.claude/settings.json`; a backup is written first and your existing hooks are kept. Restart running Claude sessions to pick them up.

Remove the hooks from the same menu.

## Keyboard

- **⌃⌥Space** toggles the list; then **⌘1…⌘9** jumps to a terminal and **Esc** closes it.
- Change the hotkey with `defaults write fi.slemppa.TerminalHandler hotkeyKeyCode -int <keycode>` and `hotkeyModifiers -int <carbon modifiers>`.

## How it works

- `th-hook` is a tiny helper Claude Code runs for its hooks. It finds the TTY of the `claude` process that ran it and forwards the hook payload to the app over a Unix socket in `~/Library/Application Support/TerminalHandler/`.
- The app polls Ghostty over AppleScript for its terminals (id, TTY, working directory) and joins them to Claude sessions by TTY. Git repo and branch are read straight from `.git`.
- Blocking hooks (`PermissionRequest`, `PreToolUse` for `AskUserQuestion`) are held until you answer in the island, or released with no output so Claude shows its normal prompt.

Design notes: [`docs/superpowers/specs`](docs/superpowers/specs).

## Development

```sh
swift test     # THCore: session state, hook protocol, git, settings installer
swift build
```

## License

[MIT](LICENSE)
