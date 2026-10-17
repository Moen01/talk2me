import Foundation

/// Turns shortcut key presses into recording actions.
///
/// - Hold the hold key: record while held, transcribe on release.
/// - Double-tap the hands-free key: keep recording without holding. Press Enter or the
///   key again to finish, or Escape to discard.
/// - A quick single tap of the hold key, or using it with another key (Fn+Delete), discards the recording.
public struct HotkeyStateMachine: Sendable {
    public enum Action: Equatable, Sendable {
        case startRecording
        case stopRecording
        case cancelRecording
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

    public init(tapThreshold: TimeInterval = 0.25, doubleTapWindow: TimeInterval = 0.4) {
        self.tapThreshold = tapThreshold
        self.doubleTapWindow = doubleTapWindow
    }

    public mutating func shortcutDown(_ roles: ShortcutRoles, at time: TimeInterval) -> Action? {
        switch state {
        case .idle:
            if roles.contains(.hold) {
                state = .holding(since: time, roles: roles)
                return .startRecording
            }
            guard roles.contains(.handsFree) else { return nil }
            if let last = lastTapAt, time - last <= doubleTapWindow {
                // Second tap of a hands-free-only key: start right away.
                lastTapAt = nil
                state = .handsFree
                return .startRecording
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
            guard time - since < tapThreshold else {
                state = .idle
                lastTapAt = nil
                return .stopRecording
            }
            if heldRoles.contains(.handsFree), let last = lastTapAt, time - last <= doubleTapWindow + tapThreshold {
                // Second quick tap: keep the recording that this press started.
                state = .handsFree
                lastTapAt = nil
                return nil
            }
            state = .idle
            lastTapAt = heldRoles.contains(.handsFree) ? time : nil
            return .cancelRecording
        case .tapping(let since):
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
    }
}
