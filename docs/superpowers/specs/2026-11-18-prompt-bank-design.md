# Prompt Bank — design

2026-11-18. Status: draft for approval.

## Intent

Add a **Prompt Bank** to Talk2Me: up to four slots, each bound to a hotkey the user
picks. Holding a slot's key (or double-tapping it for hands-free) records speech into
that slot as text — nothing is pasted anywhere. A short tap of the same key later
pastes the slot's text into whatever field has focus. Recording into a slot again
replaces its old content. Slots survive app restarts.

**Why:** Andreas dictates long prompts for Claude sessions. Today a long ramble is
pasted into whatever has focus the moment it finishes — click into the wrong window
mid-talk and the text is lost or lands in the wrong place. The Prompt Bank is a safe
buffer: talk first without worrying, aim and paste afterwards, and keep up to four
prompts staged at once.

## Goals

- Hold a slot key, talk, release: the transcript is saved into that slot, visible
  nowhere else. Double-tap starts a hands-free capture for long rambles (Enter or the
  key again finishes, Escape discards — identical gestures to dictation today).
- Short-tap a slot key: its text is pasted into the focused app (same paste-and-
  restore-clipboard mechanism normal dictation uses).
- Re-recording replaces the slot's content. Pasting does NOT clear it (a misfired
  paste must never destroy the ramble — content only dies when recorded over).
- Slots persist across app restarts.
- Feature is off by default; enabled with a toggle in Settings (like Orchestrate).

## Non-goals

- No slot management UI beyond Settings (no floating palette, no menu-bar list of
  slot contents; the menu bar only reports the last action).
- No more than four slots in v1.
- No naming/labelling of slots in v1 — they are "Prompt 1..4".
- Not a clipboard-history tool; the system clipboard is only touched during the
  paste itself (and restored afterwards, as dictation does today).

## Anti-goals

- A paste that can be sabotaged by the system clipboard (the rejected approach B).
- Losing a capture because the user clicked somewhere: once transcription finishes,
  the text is in the slot no matter what has focus.
- Colliding with the existing "Snippets" feature (voice commands). Different name
  everywhere: **Prompt Bank** in UI, `promptBank`/`PromptSlot` in code.

## Constraints

- macOS 26+, Swift 6.2, SwiftPM, no new dependencies.
- Slot keys must not collide with the hold key, the hands-free key, the orchestrate
  key, or each other. Settings refuses conflicts with an inline explanation and shows
  live conflicts when other keys change (same pattern as the orchestrate key picker).
- Feature toggle off ⇒ no slot keys are watched at all.

## Approaches considered

- **A. Slot key does both: hold = record, short tap = paste directly.** One step to
  paste, immune to clipboard overwrites. **Picked by Andreas.**
- **B. Tap loads the system clipboard, user pastes with Cmd+V.** Matches "Control-V"
  muscle memory but is two steps and anything copied in between silently destroys the
  staged text — the exact failure the feature exists to prevent. Rejected.

## Design

### Roles and state machine

- `ShortcutRoles` gains four options: `promptSlot1...promptSlot4` (rawValues 8, 16,
  32, 64). `ShortcutBindings.make` gains `prompts: [ShortcutKey?]` (4 entries);
  a prompt key equal to any other bound key is dropped (existing keys win).
- `RecordingTarget` gains `.promptSlot(Int)` (index 0–3).
- State machine semantics for a slot key:
  - Hold past the tap threshold → record into the slot (`.startRecording(.promptSlot(n))`),
    release stops — exactly the hold key's semantics.
  - Quick tap → **paste intent**, BUT only after the double-tap window (0.4 s)
    expires with no second tap: a second tap within the window starts a hands-free
    capture into the slot instead.
  - **Timer/ownership split (my call):** the state machine stays a pure function of
    events and timestamps. A quick slot tap moves it into a new `slotTapping(slot:,
    since:)` state (separate from the existing `tapping`, which stays hands-free-only)
    and returns no action. The controller schedules a one-shot 0.4 s timer; on expiry
    it feeds a new event (`slotTapExpired(at:)`) into the machine, which returns
    `.paste(.promptSlot(n))` if still in `slotTapping`. A second tap before expiry
    returns the hands-free start action and the controller cancels the timer. All
    transitions pinned by tests with explicit timestamps.
  - Slot keys follow the hold key's rules for key type and combos: any key the picker
    accepts is allowed (modifier or regular key; a regular key is taken over fully,
    as the hold key is today), and a slot key used together with another key cancels
    the capture, same as Fn+Delete today.
  - Slot keys must be distinct from hold, hands-free, orchestrate AND each other —
    enforced in Settings with the inline-refusal + live-conflict pattern, and
    `ShortcutBindings.make` drops a conflicting prompt key (existing keys win).
- Escape during a slot hands-free capture discards it; the slot keeps its previous
  content (my call: a discarded capture must not destroy the old prompt).

### Capture pipeline

record → on-device transcript → personal dictionary → **Claude cleanup as normal
dictation does** (my call: slot text is paste-anywhere text and long rambles benefit
most from cleanup; on cleanup failure/timeout the raw transcript is saved, so nothing
is ever lost) → stored in the slot. Voice-command Snippets do NOT fire on slot
captures (my call: a capture is content, not a command). The menu-bar line reports
"Saved to Prompt 2 (134 words)." or the cleanup-failure variant.

### Paste

Short tap with content → `TextInserter.insert` (existing paste + clipboard restore);
menu line "Pasted Prompt 2." Empty slot → no keystrokes, menu line "Prompt 2 is
empty." Secure-input and no-accessibility fallbacks behave as dictation does today
(copied instead, with the explanatory line).

### Storage

`[PromptSlot]` (4 entries: `text: String`, `savedAt: Date?`) stored as JSON in
UserDefaults via AppSettings, like dictionary and snippets today (my call: consistent
with existing persistence; four prompts are a few KB at most). AppSettings carries
both the keys (`@Published var promptKeys: [ShortcutKey?]`, 4 entries, all nil by
default) and the content (`@Published var promptSlots: [PromptSlot]`); the
DictationController reads and writes slots through `settings`, no second store (my
call: follows the dictionary/snippets pattern; splitting a four-element array into
its own store buys nothing at this size).

The menu-bar word count ("Saved to Prompt 2 (134 words).") counts the **stored**
text — cleaned when cleanup succeeded, raw when it fell back — so the number always
describes what is actually in the slot (my call).

### Settings UI

New sidebar page **Prompt Bank** (icon `tray.full`), after Orchestrate:
- Enable toggle.
- Four rows, one per slot: key picker (presets + record-a-key, refusing conflicts
  inline), a one-line preview of the saved text with its age ("2 h ago"), and a
  Clear button per slot.
- Footnote: "Hold a key and talk to save into the slot. Tap the key to paste it.
  Recording again replaces the slot."

### Recording indicator / feedback

While recording into a slot, the existing indicator runs as usual; the menu-bar state
line says which slot is being filled. No new indicator visuals in v1 (my call).

## Decided by Andreas

- Approach A (tap pastes directly; hold/double-tap records).
- Four slots; feature toggled, off by default, like Orchestrate.
- Re-record replaces; slots are a safety buffer against losing long rambles.

## My calls (correctable)

- Slots keep content after paste (only re-recording replaces it) — he proposed
  delete-after-paste; rejected because one misfired paste would lose the ramble.
- Claude cleanup runs on captures; snippets don't.
- Escape-discard keeps the previous slot content.
- Persistence in UserDefaults; previews + Clear buttons in Settings; no slot naming.
- Name: Prompt Bank (avoids colliding with the existing Snippets feature).
- Paste fires only after the 0.4 s double-tap window expires (hands-free must stay
  reachable); the ~0.4 s paste latency is the accepted cost.

## Left to the builder

- Exact state-machine/controller split for the tap-paste timer, pinned by tests.
- ShortcutRoles plumbing for four slots (OptionSet bits vs a parallel index — keep
  `HotkeyMonitor` untouched if possible).
- Settings layout details within the established SettingsView idioms.
- Word-count line formatting.

## Open questions for Andreas

None blocking.
