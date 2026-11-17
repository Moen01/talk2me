# Orchestrate — design

2026-11-17. Status: draft for approval.

## Intent

Add a second push-to-talk target to Talk2Me, called **Orchestrate**. The user holds a
separate key and speaks; the words go to one dedicated, long-lived Claude Code session
(the **orchestrator**) — no matter which app has focus. The orchestrator does not write
code. Its only job is to move around the file system, explain folders, start new Claude
Code sessions in a folder the user names, and bring those sessions to the front so the
user's normal push-to-talk lands in them.

**Why:** Andreas runs several Claude Code sessions at once and controls them by voice.
Today speech always goes to the focused app, so there is no way to "step out" and talk
to a director that switches contexts for him. Orchestrate is that director: a voice-
controlled traffic switch between projects and sessions.

## Goals

- Hold the orchestrate key, speak, release: the transcript reaches the orchestrator
  session, regardless of focus.
- The orchestrator can, reliably: open a new Claude Code session in a given folder (new
  Terminal window, focused), focus an existing session it started, list its sessions,
  and explain/navigate folders read-only.
- Sessions the orchestrator starts are plain Claude Code sessions. The user controls
  them with the normal push-to-talk into whichever window is focused.
- The orchestrator session survives between dictations (persistent interactive
  session in a real terminal, visible scrollback).
- The orchestrator terminal window comes to the front when the user speaks to it, so
  the answer is visible.

## Non-goals

- v1 supports Terminal.app only. Other terminals (iTerm, Ghostty) later.
- No hands-free mode for the orchestrate key in v1 (hold only).
- Talk2Me does not render orchestrator output; the terminal shows it.
- No user-editable orchestrator system prompt in v1 (built-in constant).

## Anti-goals

- The orchestrator must never edit files or write code. If it starts doing project
  work itself, the feature has failed — project work belongs to spawned sessions.
- No chat UI inside Talk2Me. Rebuilding a terminal badly is a failure mode.
- No invisible background work: everything the orchestrator does is visible in its
  terminal window.

## Constraints

- macOS 26+, Apple silicon, Swift 6.2, SwiftPM. No new third-party dependencies; the
  MCP server is hand-rolled JSON-RPC over stdio.
- Claude Code subscription login; the orchestrator is a normal `claude` interactive
  session the user could also type into.
- New TCC permission: Automation (Apple Events, Talk2Me → Terminal). Must be surfaced
  in readiness/status text the way Microphone and Accessibility are today. A second
  grant (Terminal → Terminal) may be prompted when the MCP server scripts Terminal;
  builder verifies in a spike.

## Approaches considered

1. **Terminal + prompt only.** Open `claude` in a terminal with an orchestrator system
   prompt; it improvises window management with osascript in its Bash tool. Cheapest,
   but spawning/focusing is improvised each time and sessions are untracked. Rejected.
2. **Terminal + Talk2Me-provided MCP tools.** Same terminal-hosted orchestrator, but
   Talk2Me ships a small MCP server giving it exact verbs (`open_session`,
   `focus_session`, `list_sessions`). Deterministic where it must be, Claude-flexible
   where that is fine. **Picked by Andreas.**
3. **Headless orchestrator inside Talk2Me** with its own chat panel. No focus tricks,
   but requires building chat + tool-approval UI and hides the session in-app, against
   the "separate terminal" requirement. Rejected.

## Design

### Hotkey role

- `ShortcutRoles` gains a third option, `orchestrate`, alongside `hold` and
  `handsFree` (`Sources/Talk2MeCore/ShortcutKey.swift`).
- Settings gets a key picker for it, using the existing capture UI. Default key:
  **Left Option** (Andreas's choice). Left Option still types special characters
  (Option+2, Option+Shift+8, …) because a shortcut key used together with another key
  is ignored, the same way Fn+Delete works today.
- The recording pipeline is the same one dictation uses. The state machine / controller
  must carry *which role started the recording*, so the finish step routes to the
  orchestrator instead of pasting. Exact state-machine shape is left to the builder;
  the existing hold-key semantics (tap ignored, combos ignored) apply unchanged.

### Speech path for an orchestrate dictation

record → on-device transcript → personal dictionary replacement → **send raw to the
orchestrator**. Claude cleanup is skipped: the orchestrator is Claude and reads raw
transcripts fine, and skipping saves seconds per utterance (my call). Snippets do not
fire on orchestrate dictations — that channel is commands to the orchestrator, not
general dictation (my call).

Delivery: AppleScript `do script "<text>" in window id <N>` of Terminal writes the
text plus newline to that tab's tty, reaching the running `claude` REPL without
touching focus or the clipboard. Builder verifies this against a running claude REPL
in a spike; fallback is activate-window + Cmd+V paste + Return keystroke (reusing
`TextInserter` mechanics). After sending, Talk2Me brings the orchestrator window to
the front. Text must be AppleScript-escaped (quotes, backslashes).

### Orchestrator session lifecycle

- Started lazily on the first orchestrate dictation, or manually from the menu bar
  ("Start Orchestrator").
- Launch (via AppleScript to Terminal.app): new window, `cd <root folder>` and run
  `claude` with: `--append-system-prompt <orchestrator prompt>`,
  `--mcp-config <path to talk2me-mcp config>`, `--strict-mcp-config` (so only our
  server loads), and Edit/Write tools disallowed. Exact flag spellings verified by the
  builder against the installed Claude Code version.
- Root folder is a setting (default: home folder).
- **Tool permissions inside the orchestrator.** A default interactive session stops at
  an in-terminal approval menu on first use of each tool — a voice channel cannot drive
  that menu, so the voice flow would break mid-sentence. Policy: pre-approve the
  Talk2Me MCP tools (`mcp__talk2me__*`), the read-only built-ins (Read, Glob, Grep)
  and a short allowlist of read-only Bash prefixes (`ls`, `find`, `tree`,
  `git status`, `git log`) via `--allowedTools`. Edit, Write and NotebookEdit are hard-
  disallowed. Any other Bash command still raises Claude Code's normal visible prompt
  in the terminal — deliberate: the voice verbs never block, edits are mechanically
  impossible, and anything unexpected is gated in plain sight rather than silently
  allowed or denied. The first-launch "do you trust this folder?" dialog is handled
  once during onboarding or suppressed; mechanism left to the builder.
- **Continuity.** The orchestrator's Terminal window id is persisted in
  `sessions.json`. When Talk2Me relaunches and that window is still alive (window
  exists and its tty is running a `claude` process — checked via `ps`), Talk2Me
  reattaches to it instead of opening a duplicate. When the window is gone, respawn is
  a **fresh** session: the registry carries session knowledge across restarts, and
  `--continue` in the root folder could resume an unrelated conversation the user had
  there (default root is home), which is worse than starting clean.
- Talk2Me stores the Terminal window id. Before each send it checks the window still
  exists; if not, it respawns the orchestrator and says so in the menu-bar status line.
- Menu bar shows orchestrator state (not running / running / unreachable).

### MCP server: `talk2me-mcp`

New SwiftPM executable product, bundled inside Talk2Me.app, spoken to by `claude` over
stdio (JSON-RPC 2.0; implements `initialize`, `tools/list`, `tools/call`). Core logic
lives in `Talk2MeCore` so it is unit-testable. Tools:

| Tool | Does |
| --- | --- |
| `open_session(folder)` | Validates the folder exists, opens a new Terminal window running `claude` in it, focuses it, registers it. Returns the session name. |
| `focus_session(name)` | Brings that session's window to the front. Errors clearly if the window is gone. |
| `list_sessions()` | Names, folders, and alive/dead per session. |
| `reveal_folder(path)` | Opens the folder in Finder — "point at it" for plain folders. |

The MCP server runs its own AppleScript via `osascript`; it does not talk to the
Talk2Me app process. Session registry: JSON file at
`~/Library/Application Support/Talk2Me/sessions.json`, written by the MCP server, read
by Talk2Me for menu display. Liveness is checked against Terminal at read time; the
file is a cache, not the truth.

### Orchestrator system prompt (built-in)

Role: navigator and dispatcher. Never edit files; never do project work. Use
`open_session` / `focus_session` / `list_sessions` / `reveal_folder` for session and
window actions; read-only shell and file reading for explaining folders. Keep answers
short — the user reads them in a terminal and is usually about to speak again. Exact
wording left to the builder.

### Settings UI

New "Orchestrate" sidebar section: enable toggle, orchestrate key picker, root folder
picker. Terminal app is fixed to Terminal.app in v1 (stated in the UI).

## Decided by Andreas

- Approach 2 (terminal-hosted orchestrator + Talk2Me MCP tools).
- Separate terminal for the orchestrator; he controls spawned sessions through normal
  push-to-talk into the focused window.
- Default orchestrate key: Left Option.

## My calls (correctable)

- Terminal.app in v1; delivery via `do script in window id` with paste fallback.
- Skip Claude cleanup and snippets on the orchestrate channel.
- Orchestrator window comes to front on every orchestrate utterance.
- Registry as a JSON file; MCP server self-contained (no IPC with the app).
- Lazy start on first use; auto-respawn when the window is gone.
- Permission policy: voice verbs pre-approved, edits hard-disallowed, unexpected Bash
  prompts visibly in the terminal (no `--dangerously-skip-permissions`, no full
  auto-approve). The never-edit anti-goal is enforced mechanically, not by prompt
  wording alone.
- Reattach to a still-alive orchestrator window on Talk2Me relaunch; respawn fresh
  (no `--continue`) when the window is gone.

## Left to the builder

- State-machine changes for role-tagged recordings.
- AppleScript escaping and the `do script` spike; flag spelling verification.
- JSON-RPC/MCP message details; registry schema; respawn edge cases.
- Orchestrator prompt wording.
- Mechanism for the first-launch trust dialog (one-time onboarding step is acceptable).
- The tty-process check used for reattach (`ps` against the Terminal tab's tty).

## Open questions for Andreas

- His original message trailed off: "maybe I should also have, for now, …" — unknown
  extra wish, possibly a third function. Not blocking v1.

## Spike results

### REPL submission via `do script … in window id N` (2026-11-17)

Verified the unproven delivery assumption against a live `claude` interactive REPL.
Result: **`do script` submits the line** — no paste fallback needed.

Procedure and verbatim outcome:

1. Opened a Terminal window running plain `claude` with the repo's own openWindow
   script form (set-diff), captured window id `1787`:
   ```
   osascript -e 'tell application "Terminal"
       set prevIDs to (get id of windows)
       do script "cd /tmp && /opt/homebrew/bin/claude"
       activate
       set nextIDs to (get id of windows)
       ... (set-diff) ... → 1787
   end tell'
   ```
2. Waited ~6s for the REPL to draw, then sent the test line with the exact send form:
   ```
   osascript -e 'tell application "Terminal"
       do script "hello from talk2me spike" in window id 1787
   end tell'
   ```
3. Waited ~8s, then read the tab:
   `osascript -e 'tell application "Terminal" to contents of selected tab of window id 1787'`.
   Observed (excerpt):
   ```
   ❯ hello from talk2me spike

   ⏺ Hear you. Talk2me spike work. What need build?

   ✻ Baked for 4s
   ```
   The REPL shows the text as a **sent** message (`❯` prompt line) and claude
   **responded** — so `do script` submits a line (newline / `\r`) into the running
   interactive REPL. It did not sit unsubmitted.
4. Closed the window: `tell application "Terminal" to close window id 1787 saving no`
   (exit 0).

Conclusion: `OrchestratorController.send` keeps the single `do script` delivery path.
The activate + Cmd+V + Return paste fallback described under "Speech path" is **not
needed** and is not implemented.
