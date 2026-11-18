# Prompt Bank v2: arm-to-clipboard paste + combo hotkeys — design

2026-11-18. Status: draft for approval. Supersedes the paste model of
`2026-11-18-prompt-bank-design.md`; everything not changed here still holds.

## Intent

Two changes to the shipped Prompt Bank, both from Andreas after using v1:

1. **Paste with real Cmd+V, not an app-driven paste.** Tapping a slot key no longer
   pastes; it **arms** the slot: the slot's text is loaded onto the system clipboard
   and the menu-bar icon shows the slot's number. The user pastes with ordinary
   Cmd+V — anywhere, as many times as they want. ("Session clipboard" in his words.)
2. **Combo hotkeys.** A shortcut may be modifier(s)+key — ⌘3, ⇧⌥P — not only a single
   key. Example loop: hold ⌘3 and talk → saved to slot 3; tap ⌘3 → armed; Cmd+V →
   pasted.

**Why:** pasting should use the muscle memory everyone already has (Cmd+V), and the
armed-slot icon answers "what will paste right now?". Combos stop the feature from
consuming four bare keys.

## Goals

- Tap a slot key → slot text onto the system clipboard, menu-bar icon shows the
  slot number, instantly (no 0.4 s wait — arming is harmless if a double-tap
  follows).
- Cmd+V pastes it — standard system paste, repeatable, no Talk2Me involvement.
- Icon shows the armed slot's number until the clipboard changes (user copies
  something else) or the slot is re-recorded; the slot's stored text is never
  affected by arming or pasting. Re-tap re-arms any time.
- Hold = record into slot, double-tap = hands-free ramble into slot — unchanged.
- Every key picker (hold, hands-free, orchestrate, prompt slots) accepts
  modifier(s)+key combos as well as today's single keys.

## Non-goals

- No change to normal dictation's paste (it still auto-pastes into the focused app —
  that is its whole purpose).
- No clipboard-history or multi-item clipboard; one armed slot at a time.
- No restoring the previous clipboard after arming — arming replaces the clipboard;
  that is the point. (The old transient-paste clipboard restore applies only to
  normal dictation now.)

## Anti-goals

- An armed state the user cannot see (the icon IS the state).
- Losing slot content: arming, pasting, copying-something-else never touch the
  stored text.

## Approaches considered

- **v1 (shipped): tap auto-pastes into the focused field.** Rejected by Andreas in
  use: he wants standard Cmd+V and the ability to aim after arming, paste repeatedly.
- **v2 (this design): tap arms the real clipboard + icon indicator.** Picked by
  Andreas. The known weakness (copying something else overwrites the armed text) is
  mitigated by the icon clearing and one-tap re-arm; the slot itself is never lost.
- Double-tap-arms variant rejected: double-tap stays the hands-free ramble recorder
  (Andreas's original core ask); tap is the arming gesture (my call, confirmed by
  his "use the command again" loop).

## Design

### Arm-to-clipboard (replaces tap-to-paste)

- State machine: `Action.paste(RecordingTarget)` is renamed in meaning only — it
  becomes the **arm** signal. The `slotTapping` 0.4 s expiry mechanism is REMOVED:
  a slot-key quick release arms immediately (`.arm(.promptSlot(n))` returned on
  quick release) while still remembering the tap for double-tap promotion, exactly
  like the Fn key's `lastTapAt` logic. Arming during the first tap of a double-tap
  is accepted: the clipboard gets loaded, then the ramble recording starts — harmless
  (my call). The `slotTapExpired` event and controller timer are deleted.
- Controller: on arm, write the slot text to `NSPasteboard.general` (plain string,
  no transient marker — it must survive for real Cmd+V use), remember
  `armedSlot: (index, changeCount)`, menu line "Prompt 2 armed — Cmd+V to paste."
  Empty slot → "Prompt 2 is empty.", nothing armed.
- Armed-state tracking: a lightweight poll (reuse the existing 2 s Permissions-style
  tick or NSPasteboard.changeCount check on refresh) clears the armed state when
  `changeCount` moves past ours. Re-recording the armed slot clears it too.
- Menu-bar icon: shows `n.circle` while recording into slot n (unchanged) AND while
  slot n is armed (new). Recording display wins when both apply.

### Combo hotkeys

- `ShortcutKey` gains `modifiers: UInt64` (CGEventFlags-style mask, default 0 —
  existing stored single keys decode unchanged; Codable with default keeps old
  UserDefaults values valid).
- Matching in `HotkeyMonitor`: a combo binding matches on keyDown when the key code
  matches AND the required modifier mask is contained in the event flags (extra
  modifiers tolerated: ⌘3 fires even with caps lock on; my call). The combo keyDown
  is swallowed. keyUp of the base key, or release of a required modifier, counts as
  the shortcut's release. The existing "key with Command/Control/Option held is
  someone else's shortcut" passthrough applies only to bindings with no modifiers.
- Single-key bindings behave exactly as today (including Fn suppression and
  modifier-alone keys).
- Capture UI ("Record a key…"): records the chord — base key + modifiers held at
  that keyDown. Modifier-only chords remain valid (that's a v1 single key).
  Key names render as "⌘3", "⇧⌥P" (symbols in preset/menu order ⌃⌥⇧⌘).
- All four pickers (hold, hands-free, orchestrate, prompt slots) get combo support
  through the shared capture path. Slot presets offered as ⌃⌥1…⌃⌥4 (my call:
  Control+Option is rarely taken by apps; ⌘1…⌘4 collide with browser tabs).
- Conflict rules unchanged: equality now includes modifiers (⌘3 and ⇧3 are
  different keys).

## Constraints

- No new dependencies; existing users' stored single-key settings must load
  unchanged (Codable default for `modifiers`).
- Combo gestures must support hold (record), quick tap (arm), double-tap
  (hands-free) — same state machine, same thresholds.
- README and the Prompt Bank settings footnote must be rewritten for the new paste
  model ("Tap the key to load it — then paste with Cmd+V.").

## My calls (correctable)

- Tap arms instantly; no wait. First tap of a double-tap also arms (harmless).
- Extra held modifiers don't block a combo match.
- Armed icon clears on clipboard change or slot re-record; nothing else clears it.
- Slot presets ⌃⌥1…⌃⌥4; combos allowed in every picker, required in none.
- Arming does not preserve/restore the previous clipboard (inherent to the model).

## Builder-check resolutions (my calls)

- **Key identity:** `ShortcutKey` keeps its struct + Dictionary role; `modifiers`
  joins `keyCode` in synthesized Equatable/Hashable (bare `3` and `⌘3` are distinct
  dictionary keys). `HotkeyMonitor` dispatch changes from direct lookup to a scan of
  the (tiny) bindings table: candidates match when the key code matches and the
  required modifier mask is contained in the event flags; the MOST SPECIFIC match
  wins (largest modifier mask), so ⌘3 beats a bare-3 binding while ⌘ is held.
- **Chord capture is two-phase:** while recording a key, modifier presses accumulate
  into a pending mask; a regular keyDown while modifiers are held captures the chord
  (base key + mask); releasing all modifiers without a base key captures a
  modifier-only key (today's behavior, completed on release instead of press, so a
  chord still has its chance). Escape cancels, as today.
- **TextInserter interaction needs no code change — rule, don't fix:** normal
  dictation snapshots the clipboard (which may hold armed text), pastes, and
  restores. Restoring the armed text is CORRECT: dictation never leaves its text on
  the clipboard by design, and the armed slot staying armed through a dictation
  keeps the icon truthful. Because the restore bumps `changeCount`, the armed-state
  poll must compare the clipboard STRING to the armed slot's text, not changeCount.

## Left to the builder

- State-machine simplification details (removing slotTapping/slotTapExpired; tests
  updated to pin arm-on-quick-release + double-tap promotion).
- CGEventFlags mask normalization (device-independent bits only).
- Picker display-name formatting for chords.
- Armed-state poll mechanics.

## Open questions for Andreas

None blocking.
