# Prompt Bank v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tap a slot key to ARM it — slot text onto the real clipboard, number in the menu bar, paste with ordinary Cmd+V — and let every hotkey be a modifier+key combo (⌘3), not only a single key.

**Architecture:** `ShortcutKey` grows a `modifiers` mask (default 0 — old stored keys load unchanged) with chord matching helpers in Core; `HotkeyMonitor` dispatch becomes a most-specific-chord scan and its capture turns two-phase. The state machine's slot-tap expiry mechanism (`slotTapping` timer dance) is deleted: a quick release arms immediately (`.arm`), double-tap promotion keeps working via tap memory. The controller writes the armed text to `NSPasteboard`, tracks armed state by comparing clipboard text to the slot, and the menu-bar icon shows the number while recording or armed.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing, CGEvent taps, NSPasteboard. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-18-prompt-bank-v2-design.md` (supersedes the paste model of `2026-11-18-prompt-bank-design.md`; all else there still binds)

## Global Constraints

- Existing users' stored keys (single Ints in UserDefaults) must load unchanged: `modifiers` defaults to 0 everywhere, storage adds parallel modifier fields rather than changing existing ones.
- Arming replaces the system clipboard, plain string, NO transient marker, NO clipboard restore. Normal dictation's TextInserter behavior is untouched (its restore of armed text is ruled correct).
- Armed-state truth = current clipboard string equals the armed slot's text (never changeCount).
- Gestures on a slot key: hold = record, quick release = ARM instantly (no 0.4 s wait), double-tap = hands-free ramble (first tap's arm is accepted); Enter/Escape/key-again in hands-free unchanged.
- Chord matching: candidates match when key code matches AND required modifiers ⊆ event flags; most specific (largest modifier mask) wins; extra modifiers tolerated. The "key + ⌘/⌃/⌥ held is someone else's shortcut" passthrough applies only to bindings with `modifiers == 0`.
- Combos available in ALL four pickers, required in none; slot presets ⌃⌥1…⌃⌥4; chord names render as "⌃⌥1", "⌘3" (symbol order ⌃⌥⇧⌘ then the key name).
- Menu lines, exactly: "Prompt 2 armed — Cmd+V to paste." / "Prompt 2 is empty." Menu-bar icon `n.circle` while recording into slot n OR while slot n is armed; recording wins.
- Modifier-only keys still work everywhere (they are `modifiers == 0` keys with a modifier keyCode, as today).

## Review Focus

1. Upgrade path: a user with Fn/Right-Option/slot keys stored pre-v2 must get identical behavior after update — pinned in Task 1's decode-defaults test and Task 4's storage round-trip test.
2. Bare key bound (e.g. F13 as hold) pressed WITH ⌘ held must still pass through to the app (old rule), while a bound ⌘F13 chord must fire — pinned in Task 1's matching tests.
3. Releasing the modifier before the base key during a chord hold-record must end the recording, not leave it stuck — pinned in Task 3's monitor logic (manual verification; Core picks release semantics in Task 1's `releasedBy` test).
4. Arm → user copies something else → icon must clear on the next poll; re-tap re-arms — Task 4 logic, manual e2e step.
5. Double-tap ramble into an armed slot: after re-record, old armed clipboard text no longer matches → icon clears (stale arm never shown) — Task 4's string-compare rule, manual e2e step.

---

### Task 1: Chords in ShortcutKey

**Files:**
- Modify: `Sources/Talk2MeCore/ShortcutKey.swift`
- Test: `Tests/Talk2MeCoreTests/HotkeyStateMachineTests.swift` (ShortcutKeyTests suite lives there)

**Interfaces:**
- Produces:
  - `ShortcutKey` gains `public let modifiers: UInt64` (CGEventFlags raw bits, default 0): `init(keyCode: Int64, modifiers: UInt64 = 0)`. Codable must decode legacy payloads lacking the field (decodeIfPresent → 0). Synthesized Equatable/Hashable now includes modifiers.
  - `public static let chordModifierMask: UInt64` — the union of the device-independent ⌘⌃⌥⇧ mask bits (use CGEventFlags maskCommand/Control/Alternate/Shift raw values).
  - `func matchesChord(code: Int64, flags: UInt64) -> Bool` — key code matches AND `(flags & Self.chordModifierMask) ⊇ modifiers`. (For `modifiers == 0` this is just the code match — the caller applies the old passthrough rule.)
  - `var isChord: Bool` (`modifiers != 0`); chords are never `isModifier`.
  - `var chordPrefix: String` — "⌃⌥⇧⌘" subset in that order, empty for 0. (Full display name = `chordPrefix` + existing key-name logic; app-side naming stays in `KeyboardLayout.name(of:)`, Task 3 extends it.)
  - `static func presetChord(_ digit: Int) -> ShortcutKey` — ⌃⌥+digit (keyCodes 18/19/20/21 for 1–4) for the slot presets.
  - `releasedBy(code: Int64, flags: UInt64) -> Bool` — true when the base key code is released OR a required modifier bit is no longer in flags.

- [ ] **Step 1: Write failing tests**

```swift
@Test func legacySingleKeyDecodesWithZeroModifiers() throws {
    let data = Data(#"{"keyCode":63}"#.utf8)
    let key = try JSONDecoder().decode(ShortcutKey.self, from: data)
    #expect(key == .fn)
    #expect(key.modifiers == 0)
}

@Test func chordAndBareKeyAreDistinct() {
    let bare = ShortcutKey(keyCode: 20)
    let cmd3 = ShortcutKey(keyCode: 20, modifiers: CGEventFlags.maskCommand.rawValue)
    #expect(bare != cmd3)
    #expect(Set([bare, cmd3]).count == 2)
}

@Test func chordMatchingToleratesExtraModifiers() {
    let cmd3 = ShortcutKey(keyCode: 20, modifiers: CGEventFlags.maskCommand.rawValue)
    let flags = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlphaShift.rawValue
    #expect(cmd3.matchesChord(code: 20, flags: flags))
    #expect(!cmd3.matchesChord(code: 20, flags: CGEventFlags.maskShift.rawValue))
}

@Test func chordReleaseByModifierOrBaseKey() {
    let cmd3 = ShortcutKey(keyCode: 20, modifiers: CGEventFlags.maskCommand.rawValue)
    #expect(cmd3.releasedBy(code: 20, flags: CGEventFlags.maskCommand.rawValue))   // base key up
    #expect(cmd3.releasedBy(code: 999, flags: 0))                                   // ⌘ released
    #expect(!cmd3.releasedBy(code: 999, flags: CGEventFlags.maskCommand.rawValue)) // unrelated key up
}

@Test func chordPrefixOrdersSymbols() {
    let key = ShortcutKey(keyCode: 35,
        modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue)
    #expect(key.chordPrefix == "⌃⇧⌘")
}
```

(Import CoreGraphics in the test file if CGEventFlags is not visible; alternatively pin the raw constants. Builder's choice — assertions stand.)

- [ ] **Step 2: Run to verify failure** — `swift test --filter HotkeyStateMachineTests`.
- [ ] **Step 3: Implement.** Custom `init(from:)` with `decodeIfPresent` for modifiers; everything else per Interfaces.
- [ ] **Step 4: Full `swift test` PASS** (existing suites green — Equatable change must not break them; fix any test relying on keyCode-only equality by intent, not by weakening).
- [ ] **Step 5: Commit** — `feat: teach ShortcutKey modifier chords`

### Task 2: Arm replaces the slot-tap expiry

**Files:**
- Modify: `Sources/Talk2MeCore/HotkeyStateMachine.swift`
- Test: `Tests/Talk2MeCoreTests/HotkeyStateMachineTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `Action.paste(RecordingTarget)` renamed to `arm(RecordingTarget)`; `slotTapping` state, `slotTapExpired(at:)`, and `slotSecondTapHolding` are DELETED.
  - Slot quick release returns `.arm(.promptSlot(n))` immediately. The single-action API stays: `.arm` IMPLIES the recording that the press started is discarded — the controller cancels its live recording session when it handles `.arm` (decision, pinned by the tests below; the machine never emits a separate cancel for this path).
  - Double-tap memory: per-slot tap memory (`lastSlotTap: (slot: Int, at: TimeInterval)?`) mirroring `lastTapAt`: a second press of the same slot key within `doubleTapWindow` returns `.startRecording(.promptSlot(n))` and its quick release promotes to `.handsFree` (unchanged outcome, new bookkeeping). The first tap still armed — accepted by spec.

- [ ] **Step 1: Rewrite the slot test battery** — update existing slot tests and add:

```swift
@Test func slotQuickTapArmsImmediately() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    #expect(m.shortcutUp(.promptSlot(0), at: 0.1) == .arm(.promptSlot(0)))
    #expect(m.state == .idle)
}

@Test func slotDoubleTapStillRamblesAfterArm() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(2), at: 0)
    #expect(m.shortcutUp(.promptSlot(2), at: 0.1) == .arm(.promptSlot(2)))
    #expect(m.shortcutDown(.promptSlot(2), at: 0.3) == .startRecording(.promptSlot(2)))
    #expect(m.shortcutUp(.promptSlot(2), at: 0.4) == nil)
    #expect(m.state == .handsFree)
}

@Test func slowSecondSlotTapArmsAgain() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    _ = m.shortcutUp(.promptSlot(0), at: 0.1)
    _ = m.shortcutDown(.promptSlot(0), at: 1.0)   // outside window
    #expect(m.shortcutUp(.promptSlot(0), at: 1.1) == .arm(.promptSlot(0)))
}

@Test func slotLongHoldStillSaves() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(1), at: 0)
    #expect(m.shortcutUp(.promptSlot(1), at: 1) == .stopRecording)
}

@Test func longSecondHoldStillSavesAndNextTapArms() {
    var m = HotkeyStateMachine()
    _ = m.shortcutDown(.promptSlot(0), at: 0)
    _ = m.shortcutUp(.promptSlot(0), at: 0.1)        // arm
    _ = m.shortcutDown(.promptSlot(0), at: 0.3)      // second press…
    #expect(m.shortcutUp(.promptSlot(0), at: 2.0) == .stopRecording)  // …held long: saves
    _ = m.shortcutDown(.promptSlot(0), at: 10)
    #expect(m.shortcutUp(.promptSlot(0), at: 10.1) == .arm(.promptSlot(0)))
}
```

Delete `slotQuickTapThenExpiryPastes`, `expiredTapDoesNotPasteTwice`, `secondTapAfterExpiryStartsANewTapCycle`, `differentKeyDuringSlotTapAbandonsPaste`, `otherKeyDuringSlotTapAbandonsPaste`, `resetClearsPendingSlotTap` (the states/events they pin no longer exist). Keep combo-cancel and escape tests, updated to the new action names.

- [ ] **Step 2: Run to verify failures.**
- [ ] **Step 3: Implement** (delete state/event/flag; arm-on-quick-release; per-slot tap memory; update doc comments). Deleting `slotTapping`/`slotTapExpired` breaks the app target (`DictationController` references them) — make the MINIMAL compile fix there only (remove dead references, `case .arm: break` placeholder); the real arm handling is Task 4.
- [ ] **Step 4: Full `swift test` PASS and `swift build` clean.**
- [ ] **Step 5: Commit** — `feat: arm on slot tap, drop the paste expiry machinery`

### Task 3: Chord dispatch and two-phase capture in HotkeyMonitor

**Files:**
- Modify: `Sources/Talk2Me/HotkeyMonitor.swift`, `Sources/Talk2Me/KeyboardLayout.swift` (name rendering)

**Interfaces:**
- Consumes: `matchesChord`, `releasedBy`, `isChord`, `chordPrefix` (Task 1).
- Produces:
  - keyDown dispatch: collect bindings where `key.matchesChord(code:flags:)`; pick the largest `modifiers` mask. A `modifiers == 0` match keeps the existing rule (pass through when ⌘/⌃/⌥ held and key not already down: `HotkeyMonitor.swift:105-106`). A chord match swallows the event and `setDown(key, roles, true)`.
  - keyUp AND flagsChanged while a chord is in `downKeys`: if `key.releasedBy(code:flags:)` → `setDown(key, roles, false)` (swallow the base-key keyUp; let flagsChanged pass unless it is a bound modifier-only key, as today).
  - `captureNextKey` two-phase: modifier keyDowns accumulate a pending mask (shown nowhere — capture UI already says "press a key"); a regular keyDown while mask non-zero completes with `ShortcutKey(keyCode: code, modifiers: pendingMask & ShortcutKey.chordModifierMask)`; all modifiers released with no base key → completes with the modifier-only key (today's result, on release); Escape cancels. Fn cannot be part of a chord mask (it stays a key of its own).
  - `KeyboardLayout.name(of:)` prefixes `chordPrefix` for chords ("⌃⌥1").

- [ ] **Step 1: Implement** (no unit seam — app target; Core helpers are the tested logic).
- [ ] **Step 2: Verify** — `swift build` clean; full `swift test` green; `./scripts/build-app.sh` passes.
- [ ] **Step 3: Commit** — `feat: chord hotkey dispatch and two-phase key capture`

### Task 4: Arm in the controller, storage, icon

**Files:**
- Modify: `Sources/Talk2Me/DictationController.swift`, `Sources/Talk2Me/AppSettings.swift`, `Sources/Talk2Me/StatusBarController.swift`, `Sources/Talk2Me/AppDelegate.swift` (only if publisher list needs the new modifier fields)

**Interfaces:**
- Consumes: `Action.arm(RecordingTarget)` (Task 2), chords (Tasks 1/3).
- Produces:
  - DictationController: DELETE `slotTapTimer`/`scheduleSlotTapTimerIfNeeded` and `pasteSlot`. New `armSlot(_ n: Int)`: empty slot → `lastResult = "Prompt \(n+1) is empty."`; else write `settings.promptSlots[n].text` to `NSPasteboard.general` (clearContents + setString, plain string, no transient type), set `private(set) var armedSlotIndex: Int?` = n, `lastResult = "Prompt \(n+1) armed — Cmd+V to paste."`. `perform` handles `.arm(.promptSlot(n))`: if a recording is live from the tap's press, cancel it (the machine no longer emits a separate cancel), then `armSlot(n)`.
  - Armed truth check `refreshArmedState()`: if `armedSlotIndex` set and `NSPasteboard.general.string(forType: .string) != settings.promptSlots[n].text` → clear to nil (+ onChange). Called from the existing status-refresh tick (StatusBarController already refreshes on onChange; add the check in its existing periodic path — the Permissions.ticks-style 2 s timer in SettingsView does NOT run when settings is closed, so give StatusBarController its own lightweight 2 s Timer calling `controller.refreshArmedState()` then `refresh()`; my call per spec "lightweight poll").
  - Re-recording slot n (capture finish) clears `armedSlotIndex` when it equals n (text changed → stale).
  - AppSettings: parallel modifier storage — `holdKeyModifiers`, `handsFreeKeyModifiers`, `orchestrateKeyModifiers` (Int, default 0) and `promptKeyModifiers` ([Int], default zeros) — composed into the existing `ShortcutKey` properties at init and decomposed in didSet (keyCode fields stay as-is for backward compat).
  - StatusBarController: icon `n.circle` while `recordingSlotIndex` + `.recording` (existing) OR `armedSlotIndex` non-nil (new; recording wins); orchestrator/status lines unchanged.
- [ ] **Step 1: Implement AppSettings modifier storage** (follow the trio/array patterns in place).
- [ ] **Step 2: Implement controller arm path + delete timer/paste machinery.**
- [ ] **Step 3: Implement icon + poll in StatusBarController.**
- [ ] **Step 4: Verify** — `swift build`, full `swift test`, `./scripts/build-app.sh` all green.
- [ ] **Step 5: Commit** — `feat: arm slots to the clipboard with an armed icon`

### Task 5: Pickers, presets, docs

**Files:**
- Modify: `Sources/Talk2Me/SettingsView.swift`, `README.md`

**Interfaces:**
- Consumes: chord capture (Task 3), `ShortcutKey.presetChord(_:)` (Task 1), settings fields (Task 4).

- [ ] **Step 1: Pickers** — `ShortcutPicker` and `PromptKeyPicker` display chord names (they already render via `KeyboardLayout.name`; verify menus/labels handle the prefix); PromptKeyPicker preset menu offers ⌃⌥1…⌃⌥4 (`ShortcutKey.presetChord(1...4)`) ahead of the single-key presets; conflict logic needs no change (ShortcutKey equality now includes modifiers). Record-a-key path works for chords via Task 3's capture.
- [ ] **Step 2: Copy** — Prompt Bank footnote becomes: "Hold a key and talk to save into the slot. Tap the key to load it — then paste with Cmd+V. Recording again replaces the slot." README Prompt Bank section rewritten to the arm model (tap loads the clipboard, number shows in the menu bar while loaded, Cmd+V pastes, repeatable) and a line that any shortcut may be a combo like ⌘3.
- [ ] **Step 3: Verify** — `swift build`, full `swift test`, `./scripts/build-app.sh`; list manual e2e steps in the report (bind ⌃⌥1, hold+talk, tap, Cmd+V in a text field, copy something else → icon clears, re-tap → re-armed).
- [ ] **Step 4: Commit** — `feat: chord presets and arm-model copy in Settings and README`
