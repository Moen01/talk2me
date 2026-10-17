import Foundation

/// Turns Fn presses into recording actions.
///
/// - Hold Fn: record while held, transcribe on release.
/// - Tap Fn twice quickly: hands-free; tap Fn again to finish, or press Escape to discard.
/// - A quick single tap, or Fn used with another key (Fn+Delete), discards the recording.
public struct HotkeyStateMachine: Sendable {
    public enum Action: Equatable, Sendable {
        case startRecording
        case stopRecording
        case cancelRecording
    }

    public enum State: Equatable, Sendable {
        case idle
        case holding(since: TimeInterval)
        case handsFree
        /// Waiting for Fn to come up after a press that already decided the outcome.
        case awaitingRelease
    }

    public static let escapeKeyCode: Int64 = 53

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

    public mutating func fnDown(at time: TimeInterval) -> Action? {
        switch state {
        case .idle:
            state = .holding(since: time)
            return .startRecording
        case .handsFree:
            state = .awaitingRelease
            return .stopRecording
        case .holding, .awaitingRelease:
            return nil
        }
    }

    public mutating func fnUp(at time: TimeInterval) -> Action? {
        switch state {
        case .holding(let since):
            guard time - since < tapThreshold else {
                state = .idle
                lastTapAt = nil
                return .stopRecording
            }
            if let last = lastTapAt, time - last <= doubleTapWindow + tapThreshold {
                // Second quick tap: keep the recording that this press started.
                state = .handsFree
                lastTapAt = nil
                return nil
            }
            state = .idle
            lastTapAt = time
            return .cancelRecording
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
            // Fn is being used as a modifier (Fn+Delete, Fn+arrow), not for dictation.
            state = .awaitingRelease
            lastTapAt = nil
            return .cancelRecording
        case .handsFree where keyCode == Self.escapeKeyCode:
            state = .idle
            return .cancelRecording
        default:
            return nil
        }
    }

    /// Back to idle, e.g. after an error stopped the recording.
    public mutating func reset() {
        state = .idle
        lastTapAt = nil
    }
}
