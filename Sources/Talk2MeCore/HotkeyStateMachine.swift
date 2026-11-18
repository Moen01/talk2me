import Foundation

/// Turns shortcut key presses into recording actions.
///
/// - Hold the hold key: record while held, transcribe on release.
/// - Double-tap the hands-free key: keep recording without holding. Press Enter or the
///   key again to finish, or Escape to discard.
/// - A quick single tap of the hold key, or using it with another key (Fn+Delete), discards the recording.
/// - Hold the orchestrate key: record for the orchestrator instead of the focused app.
/// - Hold a prompt-slot key to record into its slot. Quick tap arms the slot (the controller pastes
///   it when handling `.arm`). Double-tap (second press within `doubleTapWindow`) starts a
///   hands-free capture; Enter/Escape/key-again finishes or discards.
public struct HotkeyStateMachine: Sendable {
    /// Which app or feature will receive the finished recording.
    public enum RecordingTarget: Equatable, Sendable {
        /// Paste the transcript into whichever app is focused.
        case focusedApp
        /// Route the transcript to the orchestrator (Task 9).
        case orchestrator
        /// Paste the transcript into prompt slot n (0–3).
        case promptSlot(Int)
    }

    public enum Action: Equatable, Sendable {
        case startRecording(RecordingTarget)
        case stopRecording
        case cancelRecording
        /// Arm a prompt slot for pasting: the controller pastes the slot's saved content.
        /// Implies the recording started by the same key-down is discarded.
        case arm(RecordingTarget)
    }

    public enum State: Equatable, Sendable {
        case idle
        /// The hold key is down and recording.
        case holding(since: TimeInterval, roles: ShortcutRoles)
        /// A hands-free-only key is down, not recording yet; it may be the first half of a double-tap.
        case tapping(since: TimeInterval)
        case handsFree
        /// Waiting for a key to come up after a press that already decided the outcome.
        case awaitingRelease
    }

    /// A press shorter than this is a tap, not a dictation.
    public var tapThreshold: TimeInterval
    /// The second tap must start within this time of the first tap's release.
    public var doubleTapWindow: TimeInterval
    public private(set) var state: State = .idle
    private var lastTapAt: TimeInterval?
    /// Remembers the last slot quick-tap so a second press of the same slot within
    /// `doubleTapWindow` promotes to hands-free instead of arming again.
    private var lastSlotTap: (slot: Int, at: TimeInterval)?
    /// Set when a slot key's second tap begins its hold, so the quick release promotes to .handsFree.
    private var slotSecondTapHolding: Bool = false

    public init(tapThreshold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.4) {
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public mutating func shortcutDown(_ roles: ShortcutRoles, at time: TimeInterval) -> Action? {
        switch state {
        case .idle:
            if roles.contains(.orchestrate) {
                // Orchestrate-only key: hold-to-record exactly like the hold key, but targets the orchestrator.
                state = .holding(since: time, roles: roles)
                return .startRecording(.orchestrator)
            }
            if roles.contains(.hold) {
                state = .holding(since: time, roles: roles)
                return .startRecording(.focusedApp)
            }
            if let slot = roles.promptSlotIndex {
                // Check if this is a double-tap on the same slot within the window.
                if let last = lastSlotTap, last.slot == slot, time - last.at <= doubleTapWindow {
                    // Second press of same slot: start a real recording (hands-free outcome on quick release).
                    slotSecondTapHolding = true
                    lastSlotTap = nil
                    state = .holding(since: time, roles: roles)
                    return .startRecording(.promptSlot(slot))
                }
                // First press: start recording (will be discarded on quick release → arm).
                state = .holding(since: time, roles: roles)
                return .startRecording(.promptSlot(slot))
            }
            guard roles.contains(.handsFree) else { return nil }
            if let last = lastTapAt, time - last <= doubleTapWindow {
                // Second tap of a hands-free-only key: start right away.
                lastTapAt = nil
                state = .handsFree
                return .startRecording(.focusedApp)
            }
            state = .tapping(since: time)
            return nil
        case .handsFree:
            state = .awaitingRelease
            return .stopRecording
        case .holding, .tapping, .awaitingRelease:
            return nil
        }
    }

    public mutating func shortcutUp(_ roles: ShortcutRoles, at time: TimeInterval) -> Action? {
        switch state {
        case .holding(let since, let heldRoles):
            // With separate hold and hands-free keys, only the held key's release ends the hold.
            guard roles == heldRoles else { return nil }
            guard time - since < tapThreshold else {
                // Long hold: save the recording.
                state = .idle
                lastTapAt = nil
                // Clear slot tap memory — the next tap starts fresh.
                lastSlotTap = nil
                slotSecondTapHolding = false
                return .stopRecording
            }
            // Slot key double-tap: second quick release promotes to hands-free.
            if heldRoles.promptSlotIndex != nil, slotSecondTapHolding {
                slotSecondTapHolding = false
                state = .handsFree
                return nil
            }
            // Slot key first quick tap: arm the slot immediately (implies recording is discarded).
            if let slot = heldRoles.promptSlotIndex {
                state = .idle
                lastSlotTap = (slot: slot, at: time)
                return .arm(.promptSlot(slot))
            }
            if heldRoles.contains(.handsFree), !heldRoles.contains(.orchestrate), let last = lastTapAt, time - last <= doubleTapWindow + tapThreshold {
                // Second quick tap: keep the recording that this press started.
                state = .handsFree
                lastTapAt = nil
                return nil
            }
            state = .idle
            lastTapAt = heldRoles.contains(.handsFree) ? time : nil
            return .cancelRecording
        case .tapping(let since):
            // Only a hands-free-only key starts tapping, so any other key's release is not this tap.
            guard roles == .handsFree else { return nil }
            state = .idle
            lastTapAt = time - since < tapThreshold ? time : nil
            return nil
        case .awaitingRelease:
            state = .idle
            return nil
        case .idle, .handsFree:
            return nil
        }
    }

    public mutating func otherKeyDown(_ keyCode: Int64, at time: TimeInterval) -> Action? {
        switch state {
        case .holding:
            // The key is being used as part of a shortcut (Fn+Delete, Right Command+C).
            state = .awaitingRelease
            lastTapAt = nil
            slotSecondTapHolding = false
            return .cancelRecording
        case .tapping:
            state = .awaitingRelease
            lastTapAt = nil
            return nil
        case .handsFree where keyCode == ShortcutKey.escapeKeyCode:
            state = .idle
            return .cancelRecording
        case .handsFree where ShortcutKey.enterKeyCodes.contains(keyCode):
            state = .idle
            return .stopRecording
        default:
            return nil
        }
    }

    /// Back to idle, e.g. after an error stopped the recording or the shortcuts changed.
    public mutating func reset() {
        state = .idle
        lastTapAt = nil
        lastSlotTap = nil
        slotSecondTapHolding = false
    }
}
