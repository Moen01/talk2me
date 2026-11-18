# Prompt Bank Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Four hotkey-bound slots that capture dictations into a persistent buffer (hold/double-tap to record, short-tap to paste) so long rambles can never be lost to a focus change.

**Architecture:** The gesture logic (slot roles, tap-vs-hold-vs-double-tap, the deferred paste action) lives in `Talk2MeCore`'s `HotkeyStateMachine` and `ShortcutBindings`, fully unit-tested; the controller layer only schedules the one 0.4 s expiry timer and feeds it back as an event. `DictationController` routes `.promptSlot(n)` captures into `AppSettings.promptSlots` (UserDefaults-persisted, like dictionary/snippets) and pastes via the existing `TextInserter`. Settings gains a Prompt Bank page in the established idiom.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-18-prompt-bank-design.md`

## Global Constraints

- Feature off by default: `promptBankEnabled` false; no slot keys watched when off.
- Exactly 4 slots, named "Prompt 1"…"Prompt 4" in all user-facing text.
- Slot keys must be distinct from hold, hands-free, orchestrate AND each other; `ShortcutBindings.make` drops a conflicting prompt key (existing keys and earlier slots win); Settings refuses conflicts inline with live-conflict display (orchestrate-picker pattern).
- Capture pipeline: personal dictionary → Claude cleanup (raw fallback on failure — text is always saved); voice-command Snippets do NOT fire.
- Paste keeps the slot's content; only re-recording replaces it; Escape during a slot capture discards the new talk and keeps the old content.
- Paste fires only after the 0.4 s double-tap window expires (`doubleTapWindow`), so double-tap hands-free stays reachable on the same key.
- Word count in the menu line counts the stored text (cleaned or raw-fallback).
- UI/code naming: **Prompt Bank** / `promptBank` / `PromptSlot` — never "snippet" (that name is taken).

## Review Focus

1. A second tap arriving just AFTER the window (first tap pasted at 0.4 s) must start a fresh tap cycle, not hands-free — pinned in Task 2's `secondTapAfterExpiryStartsANewTapCycle`.
2. A `prompts` array shorter or longer than 4, or with duplicate keys (hand-edited defaults), must not crash or double-bind — pinned in Task 1's bindings tests.
3. A slot tap while another dictation is mid-cleanup must still paste (paste needs no microphone) — controller guards nothing on `phase` for paste; stated in Task 3 Step 2, checked in review.
4. An empty slot tap must emit no keystrokes — Task 3 Step 2 (menu line "Prompt 2 is empty.", no `TextInserter` call).
5. Losing the expiry timer (app quit between tap and 0.4 s) must leave no stuck state — `reset()` clears `slotTapping`; pinned in Task 2's `resetClearsPendingSlotTap`.

---

### Task 1: Slot roles, bindings, and PromptSlot

**Files:**
- Modify: `Sources/Talk2MeCore/ShortcutKey.swift`
- Create: `Sources/Talk2MeCore/PromptSlot.swift`
- Test: `Tests/Talk2MeCoreTests/HotkeyStateMachineTests.swift` (bindings tests live there), `Tests/Talk2MeCoreTests/PromptSlotTests.swift`

**Interfaces:**
- Produces:
  - `ShortcutRoles.promptSlot1/2/3/4` (rawValues 8, 16, 32, 64), `static func promptSlot(_ index: Int) -> ShortcutRoles`, `var promptSlotIndex: Int?` (0–3, nil when none).
  - `ShortcutBindings.make(hold:handsFree:orchestrate:prompts:)` with `prompts: [ShortcutKey?] = []`; entry i binds `.promptSlot(i)`; a prompt key equal to any already-bound key is dropped; entries beyond 4 ignored.
  - `public struct PromptSlot: Codable, Equatable, Sendable { public var text: String; public var savedAt: Date?; public init(text: String = "", savedAt: Date? = nil); public var wordCount: Int; public var isEmpty: Bool }` — wordCount splits on whitespace and newlines, empty text → 0.

- [ ] **Step 1: Write failing tests**

```swift
@Test func promptKeysGetTheirSlotRoles() {
    let b = ShortcutBindings.make(hold: .fn, handsFree: .fn, orchestrate: nil,
                                  prompts: [.rightCommand, nil, .rightControl, nil])
    #expect(b[.rightCommand] == .promptSlot(0))
    #expect(b[.rightControl] == .promptSlot(2))
    #expect(b[.rightCommand]?.promptSlotIndex == 0)
}

@Test func promptKeyCollidingWithBoundKeyIsDropped() {
    let b = ShortcutBindings.make(hold: .fn, handsFree: .fn, orchestrate: .leftOption,
                                  prompts: [.fn, .leftOption, .rightCommand, .rightCommand])
    #expect(b[.fn] == [.hold, .handsFree])
    #expect(b[.leftOption] == .orchestrate)
    #expect(b[.rightCommand] == .promptSlot(2))   // the later duplicate is dropped
}

@Test func oversizedPromptArrayIsIgnoredBeyondFour() {
    let prompts: [ShortcutKey?] = [.rightCommand, nil, nil, nil, .rightControl]
    let b = ShortcutBindings.make(hold: .fn, handsFree: nil, prompts: prompts)
    #expect(b[.rightControl] == nil)
}
```

PromptSlotTests: `wordCount` of `"hello world\nagain"` is 3, of `""` is 0; `isEmpty` true only for empty text; Codable round-trip keeps text and savedAt.

- [ ] **Step 2: Run to verify failure** — `swift test --filter HotkeyStateMachineTests` and `--filter PromptSlotTests`.
- [ ] **Step 3: Implement** (roles + make extension + PromptSlot).
- [ ] **Step 4: Run to verify pass**, then full `swift test`.
- [ ] **Step 5: Commit** — `feat: add prompt slot roles and PromptSlot storage type`

### Task 2: Slot gestures in the state machine

**Files:**
- Modify: `Sources/Talk2MeCore/HotkeyStateMachine.swift`
- Test: `Tests/Talk2MeCoreTests/HotkeyStateMachineTests.swift`

**Interfaces:**
- Consumes: `ShortcutRoles.promptSlot(_:)`, `promptSlotIndex` (Task 1).
- Produces:
  - `RecordingTarget` gains `case promptSlot(Int)`.
  - `Action` gains `case paste(RecordingTarget)`.
  - `State` gains `case slotTapping(slot: Int, since: TimeInterval)` — entered after a quick tap of a slot key; the CONTROLLER schedules a timer for `doubleTapWindow` and then calls the new event.
  - `mutating func slotTapExpired(at time: TimeInterval) -> Action?` — in `slotTapping(slot:since:)` with `time - since >= doubleTapWindow` returns `.paste(.promptSlot(slot))` and goes idle; in any other state returns nil.
  - Slot key behavior mirrors the combined Fn key exactly, with the slot as target: down in idle → `.startRecording(.promptSlot(n))` + `.holding`; long release → `.stopRecording`; quick release → `.cancelRecording` + `slotTapping`; second press of the SAME slot key while `slotTapping` within the window → records again and its quick release promotes to `.handsFree` (Enter/key/Escape then behave as hands-free does today, recording still targeted at the slot via the start action); a DIFFERENT bound key pressed during `slotTapping` abandons the pending paste and is handled as from idle; `otherKeyDown` during `slotTapping` abandons the pending paste and passes through; `reset()` clears it.

- [ ] **Step 1: Write failing tests**

```swift
@Test func slotHoldRecordsIntoSlot() {
    var m = HotkeyStateMachine()
    #expect(m.shortcutDown(.promptSlot(1), at: 0) == .startRecording(.promptSlot(1)))
    #expect(m.shortcutUp(.promptSlot(1), at: 1) == .stopRecording)
}

@Test func slotQuickTapThenExpiryPastes() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    #expect(m.shortcutUp(.promptSlot(0), at: 0.1) == .cancelRecording)
    #expect(m.slotTapExpired(at: 0.6) == .paste(.promptSlot(0)))
    #expect(m.state == .idle)
}

@Test func slotDoubleTapGoesHandsFree() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(2), at: 0)
    _ = m.shortcutUp(.promptSlot(2), at: 0.1)
    #expect(m.shortcutDown(.promptSlot(2), at: 0.3) == .startRecording(.promptSlot(2)))
    #expect(m.shortcutUp(.promptSlot(2), at: 0.4) == nil)       // promoted, keeps recording
    #expect(m.state == .handsFree)
    #expect(m.otherKeyDown(36, at: 2) == .stopRecording)        // Enter finishes
}

@Test func expiredTapDoesNotPasteTwice() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    _ = m.shortcutUp(.promptSlot(0), at: 0.1)
    _ = m.slotTapExpired(at: 0.6)
    #expect(m.slotTapExpired(at: 0.7) == nil)
}

@Test func secondTapAfterExpiryStartsANewTapCycle() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    _ = m.shortcutUp(.promptSlot(0), at: 0.1)
    _ = m.slotTapExpired(at: 0.6)                                // pasted
    _ = m.shortcutDown(.promptSlot(0), at: 0.7)
    #expect(m.shortcutUp(.promptSlot(0), at: 0.75) == .cancelRecording) // new first tap, not hands-free
    if case .slotTapping = m.state {} else { Issue.record("expected slotTapping") }
}

@Test func differentKeyDuringSlotTapAbandonsPaste() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    _ = m.shortcutUp(.promptSlot(0), at: 0.1)
    #expect(m.shortcutDown(.hold, at: 0.2) == .startRecording(.focusedApp))
    #expect(m.slotTapExpired(at: 0.6) == nil)
}

@Test func otherKeyDuringSlotTapAbandonsPaste() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    _ = m.shortcutUp(.promptSlot(0), at: 0.1)
    _ = m.otherKeyDown(5, at: 0.2)
    #expect(m.slotTapExpired(at: 0.6) == nil)
}

@Test func slotComboCancelsLikeHoldKey() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(3), at: 0)
    #expect(m.otherKeyDown(5, at: 0.1) == .cancelRecording)
}

@Test func escapeDuringSlotHandsFreeCancels() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(1), at: 0)
    _ = m.shortcutUp(.promptSlot(1), at: 0.1)
    _ = m.shortcutDown(.promptSlot(1), at: 0.3)
    _ = m.shortcutUp(.promptSlot(1), at: 0.4)
    #expect(m.otherKeyDown(ShortcutKey.escapeKeyCode, at: 1) == .cancelRecording)
}

@Test func resetClearsPendingSlotTap() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    _ = m.shortcutUp(.promptSlot(0), at: 0.1)
    m.reset()
    #expect(m.slotTapExpired(at: 0.6) == nil)
}
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement.** Internal bookkeeping (whether `slotTapping` reuses `lastTapAt` or carries its own fields) is the builder's; the tests above are the contract. Existing hold/hands-free/orchestrate tests must stay green untouched.
- [ ] **Step 4: Full `swift test` PASS.**
- [ ] **Step 5: Commit** — `feat: add prompt-slot gestures to the hotkey state machine`

### Task 3: Settings storage and dictation routing

**Files:**
- Modify: `Sources/Talk2Me/AppSettings.swift`, `Sources/Talk2Me/DictationController.swift`, `Sources/Talk2Me/AppDelegate.swift`, `Sources/Talk2Me/StatusBarController.swift`

**Interfaces:**
- Consumes: Task 1 types, Task 2 actions/events.
- Produces:
  - `AppSettings`: `@Published var promptBankEnabled: Bool` (default false, key `promptBankEnabled`), `@Published var promptKeys: [ShortcutKey?]` (always exactly 4; stored as JSON-encoded `[Int]` with `-1` for unbound, key `promptKeyCodes`; disallowed/short/long stored arrays normalize to 4 on load), `@Published var promptSlots: [PromptSlot]` (always exactly 4, JSON, key `promptSlots`). `shortcutBindings` passes `prompts: promptBankEnabled ? promptKeys : []`.
  - `DictationController`: handles `.paste(.promptSlot(n))` from `perform` → `pasteSlot(n)`; after every state-machine event, if `machine.state` is `slotTapping(slot:since:)` schedules a one-shot main-queue timer for `doubleTapWindow` that feeds `machine.slotTapExpired(at:)` back through `perform` (any new event cancels the previous timer). Capture finish for `.promptSlot(n)`: dictionary → cleanup (reuse the existing `.cleaning` path and `CleanupRouter`) → `settings.promptSlots[n] = PromptSlot(text:savedAt:)`, `lastResult` = `"Saved to Prompt \(n+1) (\(slot.wordCount) words)."` with the existing cleanup-failure suffix convention when raw was stored; snippets skipped; nothing pasted. `pasteSlot(n)`: empty → `lastResult = "Prompt \(n+1) is empty."`, no inserter call, regardless of `phase`; else `inserter.insert(text)` → `"Pasted Prompt \(n+1)."` or the copied-only reason.
  - `AppDelegate`: bindings-change `MergeMany` additionally observes `$promptBankEnabled` and `$promptKeys`.
  - `DictationController` exposes `var recordingTargetLabel: String?` — `"Prompt \(n+1)"` while the current recording targets a slot, nil otherwise; `StatusBarController.refresh` appends it to the recording state line ("Recording → Prompt 2"), per the spec's "menu-bar state line says which slot is being filled".

- [ ] **Step 1: Implement AppSettings fields** following the exact didSet/init pattern (`AppSettings.swift:38-48, 88-93` show the orchestrate trio).
- [ ] **Step 2: Implement DictationController routing** (perform, timer, finish branch before the snippets check, pasteSlot). Paste must not consult `phase` — it needs no microphone.
- [ ] **Step 3: Wire AppDelegate publishers.**
- [ ] **Step 4: Verify** — `swift build` clean; full `swift test` green (existing suites only; this layer's logic is pinned by Task 2's machine tests).
- [ ] **Step 5: Commit** — `feat: capture and paste prompt-bank slots`

### Task 4: Settings UI, README

**Files:**
- Modify: `Sources/Talk2Me/SettingsView.swift`, `README.md`

**Interfaces:**
- Consumes: Task 3 settings.

- [ ] **Step 1: Settings page** — `SettingsPage` case `promptBank` ("Prompt Bank", icon `tray.full`), between orchestrate and permissions. Page: enable toggle; when on, four rows "Prompt 1"…"Prompt 4", each with a key picker (presets + record-a-key, generalizing/reusing the `OrchestrateKeyPicker` pattern at `SettingsView.swift:474` — conflicts refused inline against hold, hands-free (when enabled), orchestrate (when enabled), and the other three prompt keys, with the live-conflict display), a one-line preview of the slot text (first ~60 chars, secondary style) with relative age ("2 h ago", `RelativeDateTimeFormatter`), and a Clear button that empties the slot. Footnote: "Hold a key and talk to save into the slot. Tap the key to paste it. Recording again replaces the slot."
- [ ] **Step 2: README** — "Prompt Bank" section after Orchestrate: what it is, off by default, hold-to-record / tap-to-paste / double-tap for long rambles, re-record replaces, survives restarts.
- [ ] **Step 3: Verify** — `swift build`, full `swift test`, `./scripts/build-app.sh` all pass.
- [ ] **Step 4: Commit** — `feat: add Prompt Bank settings page and docs`
