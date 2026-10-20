import AVFAudio
import AVFoundation
import Combine
import Foundation
import Talk2MeCore

/// Runs one dictation at a time: hold key → record → on-device transcript → Claude cleanup → paste.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, transcribing, cleaning, inserting
    }

    private(set) var phase: Phase = .idle { didSet { changed() } }
    private(set) var isHandsFree = false { didSet { changed() } }
    private(set) var lastResult = "No dictation yet." { didSet { changed() } }
    private var prepareError: String? { didSet { changed() } }
    /// For the menu bar; SwiftUI views observe the controller instead.
    var onChange: (() -> Void)?
    /// Microphone loudness (0...1) while recording, on the main thread.
    var onLevel: ((Float) -> Void)?

    private func changed() {
        objectWillChange.send()
        onChange?()
    }

    var holdKeyName: String { KeyboardLayout.name(of: settings.holdKey) }

    var readiness: String {
        if let prepareError { return "Dictation unavailable: \(prepareError)" }
        guard let prepared else { return "Preparing on-device dictation…" }
        return "Ready: hold \(holdKeyName) to dictate (\(prepared.locale.identifier))."
    }

    private let settings: AppSettings
    private let capture = AudioCapture()
    private let inserter = TextInserter()
    private var machine = HotkeyStateMachine()
    private var prepared: (localeID: String, locale: Locale, format: AVAudioFormat)? { didSet { changed() } }
    private var current: (session: DictationSession, started: Task<Error?, Never>)?
    private var cachedAPIKey: String?

    /// Audio after the hold key is released, so the last word is not clipped.
    private let releaseTail: Duration = .milliseconds(150)
    /// Finishing normally takes well under a second, even after a long hands-free dictation.
    private let transcriptionTimeout: Duration = .seconds(30)

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Key presses matter only while a shortcut key is down or hands-free mode is on.
    var wantsKeyEvents: Bool {
        switch machine.state {
        case .holding, .tapping, .handsFree: true
        case .idle, .awaitingRelease: false
        }
    }

    var handsFreeKeyName: String { KeyboardLayout.name(of: settings.handsFreeKey) }

    // MARK: - Setup

    func prepareDictation() async {
        let id = settings.localeID
        prepared = nil
        prepareError = nil
        do {
            let (locale, format) = try await OnDeviceDictation.prepare(locale: Locale(identifier: id))
            prepared = (id, locale, format)
        } catch {
            prepareError = error.localizedDescription
        }
    }

    func updateAPIKeyCache(_ key: String?) {
        cachedAPIKey = key
    }

    // MARK: - Hotkey input

    func shortcutChanged(_ roles: ShortcutRoles, down: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        perform(down ? machine.shortcutDown(roles, at: now) : machine.shortcutUp(roles, at: now))
    }

    /// The user picked different shortcuts: drop any recording tied to the old ones.
    func shortcutsWereReplaced() {
        if phase == .recording { cancelRecording() }
        machine.reset()
        isHandsFree = false
        changed()
    }

    /// Returns true when the key was used (Enter finishing or Escape discarding hands-free)
    /// and should not reach the app being typed in.
    func keyDown(_ keyCode: Int64) -> Bool {
        let wasHandsFree = machine.state == .handsFree
        let action = machine.otherKeyDown(keyCode, at: ProcessInfo.processInfo.systemUptime)
        perform(action)
        return wasHandsFree && action != nil
    }

    /// Called from the event tap, which macOS turns off if it answers slowly and which delays
    /// every key press until it returns. The state machine has already decided; starting the
    /// microphone and updating the UI wait for the next main-loop turn, in order.
    private func perform(_ action: HotkeyStateMachine.Action?) {
        DispatchQueue.main.async { [self] in
            switch action {
            case .startRecording: startRecording()
            case .stopRecording: stopRecording()
            case .cancelRecording: cancelRecording()
            case nil: break
            }
            isHandsFree = machine.state == .handsFree
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard phase == .idle else {
            // Still finishing the previous dictation.
            machine.reset()
            return
        }
        guard let prepared, prepared.localeID == settings.localeID else {
            lastResult = "Not ready yet: \(readiness)"
            machine.reset()
            Task { await prepareDictation() }
            return
        }
        let session = DictationSession(locale: prepared.locale, format: prepared.format)
        do {
            try capture.start { [weak self] buffer in
                session.append(buffer)
                let level = AudioCapture.level(of: buffer)
                DispatchQueue.main.async { self?.onLevel?(level) }
            }
        } catch {
            lastResult = "Microphone error: \(error.localizedDescription)"
            machine.reset()
            return
        }
        let started = Task<Error?, Never> {
            do { try await session.start(); return nil } catch { return error }
        }
        current = (session, started)
        phase = .recording
    }

    private func cancelRecording() {
        capture.stop()
        if let current {
            // Cancelling before the analyzer has started would race its start.
            Task {
                _ = await current.started.value
                await current.session.cancel()
            }
        }
        current = nil
        if phase == .recording { phase = .idle }
    }

    private func stopRecording() {
        guard let current else {
            // The start was refused (e.g. the previous dictation is still being cleaned up): leave that phase alone.
            if phase == .recording { phase = .idle }
            return
        }
        self.current = nil
        phase = .transcribing
        Task { await finish(current.session, started: current.started) }
    }

    private func finish(_ session: DictationSession, started: Task<Error?, Never>) async {
        try? await Task.sleep(for: releaseTail)
        capture.stop()

        // A stuck analyzer would block every later dictation; cancelling it makes finish() return.
        let watchdog = Task {
            try await Task.sleep(for: transcriptionTimeout)
            await session.cancel()
        }
        defer { watchdog.cancel() }

        if let error = await started.value {
            lastResult = "Transcription could not start: \(error.localizedDescription)"
            phase = .idle
            return
        }
        let raw: String
        do {
            raw = try await session.finish()
        } catch {
            lastResult = "Transcription failed: \(error.localizedDescription)"
            phase = .idle
            return
        }
        guard session.receivedAudio else {
            // After an update macOS can still report access as granted while sending no audio,
            // because the permission belongs to the old build's signature.
            let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "the microphone"
            lastResult = Permissions.microphoneStatus == .granted
                ? "No sound from \(device). If Talk2Me was just updated, allow it again in System Settings > Privacy & Security > Microphone. Otherwise hold the key a little longer."
                : "No microphone access. Allow Talk2Me in System Settings > Privacy & Security > Microphone."
            phase = .idle
            return
        }
        guard !raw.isEmpty else {
            lastResult = "Heard nothing."
            phase = .idle
            return
        }

        phase = .cleaning
        let outcome = await CleanupRouter.run(
            transcript: raw,
            backend: makeBackend(),
            model: settings.model,
            instructions: CleanupPrompt.system(extraInstructions: settings.extraInstructions),
            timeout: .seconds(settings.timeoutSeconds)
        )

        phase = .inserting
        let inserted = await inserter.insert(outcome.text)
        lastResult = describe(outcome, inserted)
        phase = .idle
    }

    // MARK: - Cleanup

    func makeBackend() -> (any CleanupBackend)? {
        switch settings.backend {
        case .off:
            return nil
        case .claudeCode:
            guard let path = ClaudeCodeBackend.locate(customPath: settings.claudePath) else {
                return MissingClaudeCode()
            }
            return ClaudeCodeBackend(executable: path)
        case .apiKey:
            let key = cachedAPIKey
            return AnthropicMessagesBackend { key }
        }
    }

    private func describe(_ outcome: CleanupOutcome, _ inserted: TextInserter.Outcome) -> String {
        let seconds = String(format: "%.1f", Double(outcome.duration.components.seconds)
            + Double(outcome.duration.components.attoseconds) / 1e18)
        var parts: [String] = []
        switch inserted {
        case .pasted: parts.append("Pasted")
        case .copiedOnly(let reason): parts.append(reason)
        }
        if outcome.cleaned {
            parts.append("cleaned by \(settings.model.displayName) in \(seconds) s.")
        } else if let failure = outcome.failure {
            parts.append("raw transcript (\(failure))")
        } else {
            parts.append("raw transcript.")
        }
        return parts.joined(separator: ", ")
    }
}

/// Stands in when Claude Code can't be found, so the router reports why instead of silently skipping.
private struct MissingClaudeCode: CleanupBackend {
    func cleanUp(_ transcript: String, model: ClaudeModel, instructions: String) async throws -> String {
        throw CleanupError.claudeNotFound
    }
}
