# Orchestrate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second push-to-talk hotkey whose speech always reaches one dedicated, terminal-hosted Claude Code session (the orchestrator), which navigates folders and starts/focuses project sessions through Talk2Me-provided MCP tools.

**Architecture:** Pure logic (roles, state machine, AppleScript text builders, session registry, launch flags, JSON-RPC MCP server) lives in `Talk2MeCore` and is unit-tested. A new `talk2me-mcp` executable speaks MCP over stdio to the orchestrator's `claude` and scripts Terminal.app via `osascript`. The menu-bar app gains an `OrchestratorController` that spawns/reattaches/sends-to the orchestrator window, and `DictationController` routes orchestrate-tagged recordings to it.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, AppleScript via `osascript`, Claude Code CLI. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-11-17-orchestrate-design.md`

## Global Constraints

- macOS 26+, Apple silicon, Swift 6.2; app target builds in Swift 5 language mode.
- No new third-party dependencies; MCP server is hand-rolled JSON-RPC 2.0 over stdio.
- Terminal.app only in v1; state this in the Settings UI.
- Orchestrator may never edit files: `--disallowedTools "Edit,Write,NotebookEdit"` always present.
- Pre-approved tools, exactly: `mcp__talk2me__*`, `Read`, `Glob`, `Grep`, `Bash(ls:*)`, `Bash(git status:*)`. (No `find`/`tree`/`git log`: each can write to disk — `find -delete`/`-exec`, `tree -o`, `git log --output` — so they are excluded.)
- Launch flags, exactly: `--append-system-prompt`, `--mcp-config`, `--strict-mcp-config`, `--allowedTools`, `--disallowedTools`.
- Default orchestrate key: Left Option (`ShortcutKey.leftOption`); feature off until enabled in Settings (my call).
- Registry file: `~/Library/Application Support/Talk2Me/sessions.json`.
- MCP server name in config is `talk2me`, so tools surface as `mcp__talk2me__open_session` etc.
- Orchestrate dictations: personal dictionary applied, Claude cleanup skipped, snippets skipped.
- No hands-free for the orchestrate key; hold-only semantics identical to the hold key (tap/combination cancels).

## Review Focus

1. Transcript with quotes, backslashes or newlines must reach the REPL verbatim and never break the AppleScript — pinned in Task 3's escaping tests.
2. Orchestrate key set to the same key as hold/hands-free must not create ambiguous roles — pinned in Task 1's bindings test; Settings UI also refuses it (Task 10).
3. Orchestrate press while another dictation is holding/recording must be ignored — pinned in Task 2's state-machine tests.
4. `open_session` failure (missing folder) must come back as an MCP tool error, not a crash or silence — pinned in Task 6's error test; real validation in Task 7.
5. Dead Terminal windows in the registry must show as dead and never be focused — pinned in Task 4's `pruned(alive:)` test; liveness wiring in Task 7.

---

### Task 1: Orchestrate role and bindings

**Files:**
- Modify: `Sources/Talk2MeCore/ShortcutKey.swift`
- Test: `Tests/Talk2MeCoreTests/HotkeyStateMachineTests.swift` (bindings tests live here today via `ShortcutBindings`; add alongside)

**Interfaces:**
- Produces: `ShortcutRoles.orchestrate` (rawValue 4). `ShortcutBindings.make(hold:handsFree:orchestrate:)` with `orchestrate: ShortcutKey? = nil`; an orchestrate key equal to the hold or hands-free key is dropped (hold/hands-free win).

- [ ] **Step 1: Write failing tests**

```swift
@Test func orchestrateKeyGetsItsOwnRole() {
    let b = ShortcutBindings.make(hold: .fn, handsFree: .fn, orchestrate: .leftOption)
    #expect(b[.leftOption] == .orchestrate)
    #expect(b[.fn] == [.hold, .handsFree])
}

@Test func orchestrateEqualToHoldKeyIsDropped() {
    let b = ShortcutBindings.make(hold: .fn, handsFree: nil, orchestrate: .fn)
    #expect(b == [.fn: .hold])
}

@Test func orchestrateEqualToHandsFreeKeyIsDropped() {
    let b = ShortcutBindings.make(hold: .fn, handsFree: .rightOption, orchestrate: .rightOption)
    #expect(b[.rightOption] == .handsFree)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter HotkeyStateMachineTests` fails: no member `orchestrate`.
- [ ] **Step 3: Implement** — add `public static let orchestrate = ShortcutRoles(rawValue: 4)`; extend `make` with the default-nil third parameter (existing two-argument call sites keep compiling).
- [ ] **Step 4: Run to verify pass** — same filter, PASS.
- [ ] **Step 5: Commit** — `feat: add orchestrate shortcut role`

### Task 2: Role-tagged recordings in the state machine

**Files:**
- Modify: `Sources/Talk2MeCore/HotkeyStateMachine.swift`
- Test: `Tests/Talk2MeCoreTests/HotkeyStateMachineTests.swift`

**Interfaces:**
- Produces: `public enum RecordingTarget: Equatable, Sendable { case focusedApp, orchestrator }`. `Action.startRecording` becomes `case startRecording(RecordingTarget)`; `stopRecording`/`cancelRecording` unchanged. An orchestrate-only key behaves exactly like the hold key (hold to record, quick tap cancels, other-key combo cancels, no double-tap), but starts with `.orchestrator`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func orchestrateHoldStartsOrchestratorRecording() {
    var m = HotkeyStateMachine()
    #expect(m.shortcutDown(.orchestrate, at: 0) == .startRecording(.orchestrator))
    #expect(m.shortcutUp(.orchestrate, at: 1) == .stopRecording)
}

@Test func orchestrateQuickTapCancels() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.orchestrate, at: 0)
    #expect(m.shortcutUp(.orchestrate, at: 0.1) == .cancelRecording)
}

@Test func orchestrateComboCancels() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.orchestrate, at: 0)
    #expect(m.otherKeyDown(5, at: 0.1) == .cancelRecording)
}

@Test func holdKeyStillTargetsFocusedApp() {
    var m = HotkeyStateMachine()
    #expect(m.shortcutDown(.hold, at: 0) == .startRecording(.focusedApp))
}

@Test func orchestrateIgnoredWhileHolding() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.hold, at: 0)
    #expect(m.shortcutDown(.orchestrate, at: 0.1) == nil)
}

@Test func orchestrateReleaseDoesNotEndAnotherKeysHold() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.hold, at: 0)
    #expect(m.shortcutUp(.orchestrate, at: 1) == nil)
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter HotkeyStateMachineTests`.
- [ ] **Step 3: Implement** — `shortcutDown` in `.idle`: roles containing `.orchestrate` behave as the hold branch with target `.orchestrator`; roles containing `.hold` use `.focusedApp`. Update every existing test/callsite from `.startRecording` to `.startRecording(.focusedApp)`.
- [ ] **Step 4: Run full core tests** — `swift test`, PASS (existing suites updated, nothing else broken).
- [ ] **Step 5: Commit** — `feat: tag recordings with a target in the hotkey state machine`

### Task 3: Terminal AppleScript builders and escaping

**Files:**
- Create: `Sources/Talk2MeCore/TerminalScript.swift`
- Test: `Tests/Talk2MeCoreTests/TerminalScriptTests.swift`

**Interfaces:**
- Produces (all pure `String`-building, no execution):
  - `TerminalScript.escape(_ text: String) -> String` — `\` → `\\`, `"` → `\"`, newline → `\n`, carriage return dropped.
  - `TerminalScript.openWindow(command: String) -> String` — tells Terminal to `do script command`, activate, and its last expression evaluates to the new window's id (so `osascript` prints it).
  - `TerminalScript.send(_ text: String, toWindowID: Int) -> String` — `do script "<escaped>" in window id N` without creating a window.
  - `TerminalScript.focusWindow(id: Int) -> String` — set frontmost, activate Terminal.
  - `TerminalScript.windowExists(id: Int) -> String` — evaluates to `true`/`false`.
  - `TerminalScript.ttyOfWindow(id: Int) -> String` — evaluates to the tab's tty path.

- [ ] **Step 1: Write failing tests** — pin escaping and embedding:

```swift
@Test func escapesQuotesBackslashesAndNewlines() {
    #expect(TerminalScript.escape(#"say "hi" \ bye"#) == #"say \"hi\" \\ bye"#)
    #expect(TerminalScript.escape("a\nb") == #"a\nb"#)
}

@Test func sendTargetsTheWindow() {
    let s = TerminalScript.send(#"open "x""#, toWindowID: 7)
    #expect(s.contains(#"do script "open \"x\"" in window id 7"#))
    #expect(s.contains(#"tell application "Terminal""#))
}
```

Plus one test each asserting `openWindow`/`focusWindow`/`windowExists`/`ttyOfWindow` contain their key phrases (`do script`, `set frontmost`, `exists window id`, `tty of selected tab of window id`).

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement the six functions.**
- [ ] **Step 4: Run to verify pass** — `swift test --filter TerminalScriptTests`.
- [ ] **Step 5: Commit** — `feat: add Terminal AppleScript builders`

### Task 4: Session registry

**Files:**
- Create: `Sources/Talk2MeCore/SessionRegistry.swift`
- Test: `Tests/Talk2MeCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Produces:
  - `public struct OrchestratorSession: Codable, Equatable, Sendable { var name: String; var folder: String; var windowID: Int }`
  - `public struct SessionRegistry: Codable, Equatable, Sendable` with `var orchestratorWindowID: Int?`, `var sessions: [OrchestratorSession]`,
    `static func load(from: URL) -> SessionRegistry` (missing/corrupt file → empty registry),
    `func save(to: URL) throws` (creates parent directory),
    `mutating func register(folder: String, windowID: Int) -> String` (returns the session name: folder's last path component, `-2`/`-3`… suffix when taken),
    `func pruned(alive: (Int) -> Bool) -> SessionRegistry` (drops dead sessions and a dead orchestrator id),
    `static func defaultURL() -> URL` (`~/Library/Application Support/Talk2Me/sessions.json`).

- [ ] **Step 1: Write failing tests** — round-trip save/load in a temp directory; corrupt data loads as empty; `register` names `catacloud-api`, then `catacloud-api-2` for the same folder name; `pruned` drops dead window ids and keeps live ones.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass** — `swift test --filter SessionRegistryTests`.
- [ ] **Step 5: Commit** — `feat: add orchestrator session registry`

### Task 5: Orchestrator launch configuration

**Files:**
- Create: `Sources/Talk2MeCore/OrchestratorLaunch.swift`
- Test: `Tests/Talk2MeCoreTests/OrchestratorLaunchTests.swift`

**Interfaces:**
- Produces:
  - `OrchestratorLaunch.systemPrompt: String` — role: navigator and dispatcher; never edit files or do project work; use the MCP tools for session/window actions; read-only exploration for explaining folders; keep answers short (spoken-to user, reads in a terminal). Exact wording builder's.
  - `OrchestratorLaunch.allowedTools: [String]` and `disallowedTools: [String]` — the Global Constraints lists verbatim.
  - `OrchestratorLaunch.claudeArguments(mcpConfigPath: String) -> [String]` — `["--append-system-prompt", systemPrompt, "--mcp-config", path, "--strict-mcp-config", "--allowedTools", allowedTools.joined(separator: ","), "--disallowedTools", disallowedTools.joined(separator: ",")]`.
  - `OrchestratorLaunch.shellCommand(claudePath: String, rootFolder: String, mcpConfigPath: String) -> String` — `cd <root> && <claude> <args>`, every part single-quote shell-escaped (`'` → `'\''`); this string is what `TerminalScript.openWindow(command:)` receives.
  - `OrchestratorLaunch.mcpConfigJSON(serverPath: String) -> String` — `{"mcpServers":{"talk2me":{"command":"<path>"}}}`.

- [ ] **Step 1: Write failing tests** — arguments contain each flag with its exact value; `shellCommand` escapes a root folder containing `'` and a space; config JSON decodes and has `mcpServers.talk2me.command == serverPath`.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run to verify pass** — `swift test --filter OrchestratorLaunchTests`.
- [ ] **Step 5: Commit** — `feat: add orchestrator launch configuration`

### Task 6: MCP server core

**Files:**
- Create: `Sources/Talk2MeCore/MCPServer.swift`
- Test: `Tests/Talk2MeCoreTests/MCPServerTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks (tool behavior injected).
- Produces:
  - `public protocol OrchestratorTools { func openSession(folder: String) throws -> String; func focusSession(name: String) throws -> String; func listSessions() throws -> String; func revealFolder(path: String) throws -> String }`
  - `public struct MCPServer { public init(tools: any OrchestratorTools); public func handle(_ line: Data) -> Data? }` — newline-delimited JSON-RPC 2.0. Implements `initialize` (echo client's `protocolVersion`, `serverInfo.name = "talk2me"`, `capabilities.tools = {}`), `notifications/initialized` → nil, `tools/list` → the four tools with JSON-schema inputs (`folder`, `name`, `path` string params), `tools/call` → dispatch by name, tool `throws` → `result.isError = true` with the message as text content, unknown method → error `-32601`, unparseable input → error `-32700`.

- [ ] **Step 1: Write failing tests** — initialize echoes protocolVersion and names the server; tools/list returns exactly `["open_session","focus_session","list_sessions","reveal_folder"]`; tools/call `open_session` reaches a stub and returns its string as text content; a stub that throws yields `isError == true` and the thrown message; unknown method → code -32601; notification returns nil.
- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** — small Codable request/response structs; `AnyCodable`-style values avoided by hand-building response JSON with `JSONSerialization`.
- [ ] **Step 4: Run to verify pass** — `swift test --filter MCPServerTests`.
- [ ] **Step 5: Commit** — `feat: add stdio MCP server core`

### Task 7: talk2me-mcp executable and packaging

**Files:**
- Modify: `Package.swift`
- Create: `Sources/Talk2MeMCP/main.swift`
- Modify: `scripts/build-app.sh`

**Interfaces:**
- Consumes: `MCPServer`, `OrchestratorTools` (Task 6), `TerminalScript` (Task 3), `SessionRegistry` (Task 4), `OrchestratorLaunch` (Task 5), `ClaudeCodeBackend.locate()` (existing).
- Produces: product `talk2me-mcp`, bundled at `Talk2Me.app/Contents/MacOS/talk2me-mcp`. `LiveOrchestratorTools: OrchestratorTools` — `openSession` validates the folder exists (throws a clear message otherwise), builds `cd <folder> && <claude>` (plain claude, no flags) via the Task 5 shell-escaping helper, runs `TerminalScript.openWindow` through `/usr/bin/osascript -e`, parses the printed window id, registers in `SessionRegistry` at `defaultURL()`, focuses the window, returns "Opened session <name> in <folder>". `focusSession` looks up by name, checks `windowExists`, throws "session <name>'s window is gone" when dead. `listSessions` prunes with a live `windowExists` check and lists name, folder, alive/dead. `revealFolder` uses `NSWorkspace`-free AppleScript or `/usr/bin/open` on a validated path.

- [ ] **Step 1: Add target and product** — `.executableTarget(name: "Talk2MeMCP", dependencies: ["Talk2MeCore"])`, product `.executable(name: "talk2me-mcp", targets: ["Talk2MeMCP"])`.
- [ ] **Step 2: Implement main.swift** — read stdin line by line, `MCPServer(tools: LiveOrchestratorTools()).handle(line)`, write responses + newline to stdout, flush each.
- [ ] **Step 3: Smoke-test the pipe**

Run: `swift build --product talk2me-mcp && printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}\n' | .build/debug/talk2me-mcp`
Expected: one JSON line with `"serverInfo":{"name":"talk2me"` and the echoed protocolVersion.

- [ ] **Step 4: Bundle and sign** — in `build-app.sh`: `swift build -c "$CONFIG" --product talk2me-mcp`, copy to `$APP/Contents/MacOS/talk2me-mcp`, add a `codesign` call for it (same identity/entitlement-free) before the app-bundle `codesign`.
- [ ] **Step 5: Verify packaging** — `./scripts/build-app.sh` succeeds; `codesign --verify --strict build/Talk2Me.app` passes.
- [ ] **Step 6: Commit** — `feat: ship talk2me-mcp stdio server in the app bundle`

### Task 8: OrchestratorController, permissions, plist

**Files:**
- Create: `Sources/Talk2Me/OrchestratorController.swift`
- Modify: `Resources/Info.plist`, `Resources/Talk2Me.entitlements`
- Modify: `Sources/Talk2Me/AppSettings.swift`

**Interfaces:**
- Consumes: `TerminalScript`, `SessionRegistry`, `OrchestratorLaunch`, `ClaudeCodeBackend.locate()`.
- Produces:
  - `AppSettings`: `@Published var orchestrateEnabled: Bool` (default false), `@Published var orchestrateKey: ShortcutKey` (default `.leftOption`), `@Published var orchestrateRoot: String` (default home folder). `shortcutBindings` passes `orchestrate: orchestrateEnabled ? orchestrateKey : nil`.
  - `@MainActor final class OrchestratorController`: `init(settings: AppSettings)`, `private(set) var state: State` (`enum State { case notRunning, running(windowID: Int) }`), `var onChange: (() -> Void)?`, `func send(_ text: String) async -> String` (returns the menu-bar line), `func startIfNeeded() async`.
    Behavior: `send` ensures a live orchestrator — registry's `orchestratorWindowID` + `windowExists` + `claude`/`node` seen by `ps -t <tty>` → reattach; otherwise write `mcpConfigJSON` to `~/Library/Application Support/Talk2Me/mcp.json`, `openWindow` with `OrchestratorLaunch.shellCommand`, store the window id in the registry. Then `TerminalScript.send(text, toWindowID:)`, then `focusWindow`. AppleScript runs through `/usr/bin/osascript -e` with `Process` off the main thread; Apple-Events denial surfaces as a readable failure line ("Allow Talk2Me to control Terminal in System Settings > Privacy & Security > Automation").
  - Info.plist: `NSAppleEventsUsageDescription` — "Talk2Me opens and controls Terminal windows for the Orchestrate voice channel."
  - Entitlements: `com.apple.security.automation.apple-events` = true.

- [ ] **Step 1: Add the three settings** (keys `orchestrateEnabled`, `orchestrateKeyCode`, `orchestrateRoot`) following the stored-key pattern at `AppSettings.swift:72`.
- [ ] **Step 2: Add plist key and entitlement.**
- [ ] **Step 3: Implement OrchestratorController.**
- [ ] **Step 4: Build** — `swift build --product Talk2Me` compiles.
- [ ] **Step 5: Spike verification (manual, scripted)** — with a `claude` REPL open in a Terminal window, run `osascript -e 'tell application "Terminal" to do script "hello from talk2me" in window id <that id>'`. Confirm the text lands in the REPL and submits. If `do script` does not submit into the REPL, switch `send` to the design's fallback (activate + Cmd+V + Return via `TextInserter`-style CGEvents) and note it in the design doc. Also confirm what the first orchestrator launch shows: Claude Code's one-time "trust this folder?" prompt in the new window is acceptable per the design (one-time onboarding step); record in the design doc how it behaved.
- [ ] **Step 6: Commit** — `feat: add orchestrator controller and Terminal automation permission`

### Task 9: Route orchestrate dictations

**Files:**
- Modify: `Sources/Talk2Me/DictationController.swift`
- Modify: `Sources/Talk2Me/AppDelegate.swift`

**Interfaces:**
- Consumes: `Action.startRecording(RecordingTarget)` (Task 2), `OrchestratorController.send` (Task 8).
- Produces: `DictationController.var sendToOrchestrator: ((String) async -> String)?`; recordings remember their target; orchestrate finish path = transcript → `PersonalDictionary.apply` → `sendToOrchestrator` → `lastResult` from its return; snippets and cleanup skipped; `phase` goes `.transcribing` → `.inserting` → `.idle` (no `.cleaning`).

- [ ] **Step 1: Thread the target** — `perform` stores the target from `.startRecording(target)`; `finish` branches on it before the snippets check (`DictationController.swift:219`).
- [ ] **Step 2: Wire in AppDelegate** — create `OrchestratorController`, set `controller.sendToOrchestrator`, extend the bindings `Publishers.Merge3` at `AppDelegate.swift:45` to also observe `$orchestrateEnabled`/`$orchestrateKey` (becomes `MergeMany`).
- [ ] **Step 3: Build and run existing tests** — `swift build && swift test`, all PASS.
- [ ] **Step 4: Commit** — `feat: route orchestrate dictations to the orchestrator session`

### Task 10: Settings UI, menu bar, README, end-to-end

**Files:**
- Modify: `Sources/Talk2Me/SettingsView.swift`, `Sources/Talk2Me/StatusBarController.swift`, `README.md`

**Interfaces:**
- Consumes: Task 8 settings and controller state.

- [ ] **Step 1: Settings page** — new `SettingsPage` case `orchestrate` ("Orchestrate", icon `arrow.triangle.branch`): enable toggle; key picker reusing the existing record-key UI, refusing a key equal to the hold or hands-free key with an inline explanation; root-folder picker (`NSOpenPanel`, directories only); a footnote "Opens sessions in Terminal.app. Speech on this key goes to the orchestrator, not the focused app." The existing Permissions page gains an Automation row (granted / not granted, with a System Settings link) shown when orchestrate is enabled, alongside Microphone and Accessibility.
- [ ] **Step 2: Menu bar** — orchestrator line in the status menu (state + last send result) and a "Start Orchestrator" item, both only when `orchestrateEnabled`.
- [ ] **Step 3: README** — an "Orchestrate" section: what it is, default key Left Option, the Automation permission, Terminal.app-only.
- [ ] **Step 4: Full verification** — `swift test` PASS; `./scripts/build-app.sh` PASS; manual end-to-end: enable in Settings, hold Left Option, say "open the talk2me folder and start a session there", confirm a new Terminal window opens `claude` in that folder and comes frontmost, then normal Fn dictation lands in it.
- [ ] **Step 5: Commit** — `feat: add Orchestrate settings, menu items and docs`
