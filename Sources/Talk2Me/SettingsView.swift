import AppKit
import SwiftUI
import Talk2MeCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let controller: DictationController
    let recordKey: (@escaping (ShortcutKey?) -> Void) -> Void
    let cancelRecording: () -> Void
    let languageChanged: () -> Void

    @State private var apiKeyDraft = ""
    @State private var apiKeySaved = false
    @State private var languages: [Locale] = []
    @State private var testOutput = ""
    @State private var testing = false
    @State private var accessibilityGranted = Permissions.accessibilityGranted
    @State private var microphoneGranted = Permissions.microphoneStatus == .granted

    private let sample = "um so I was thinking we should uh move the meeting to thursday new paragraph also can you send me the slides"

    var body: some View {
        Form {
            Section("Shortcuts") {
                ShortcutPicker(title: "Hold to dictate", key: $settings.holdKey,
                               recordKey: recordKey, cancelRecording: cancelRecording)
                Toggle("Hands-free mode", isOn: $settings.handsFreeEnabled)
                if settings.handsFreeEnabled {
                    ShortcutPicker(title: "Double-tap for hands-free", key: $settings.handsFreeKey,
                                   recordKey: recordKey, cancelRecording: cancelRecording)
                    Text("For longer dictation. Press Enter to finish and paste, or Esc to discard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if settings.holdKey.isFn || (settings.handsFreeEnabled && settings.handsFreeKey.isFn) {
                    Toggle("Hide Fn from other apps (stops the emoji picker opening)", isOn: $settings.suppressFnKey)
                    Button("Open Keyboard settings to set \"Press globe key\" to \"Do Nothing\"") {
                        Permissions.openKeyboardSettings()
                    }
                    .buttonStyle(.link)
                }
            }

            Section("Cleanup with Claude") {
                Picker("Backend", selection: $settings.backend) {
                    ForEach(CleanupBackendKind.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Model", selection: $settings.model) {
                    ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(settings.backend == .off)
                Stepper(value: $settings.timeoutSeconds, in: 3...60, step: 1) {
                    Text("Give up after \(Int(settings.timeoutSeconds)) s and paste the raw transcript")
                }
                TextField("Extra instructions (optional)", text: $settings.extraInstructions, axis: .vertical)
                    .lineLimit(2...5)
            }

            if settings.backend == .claudeCode {
                Section("Claude Code") {
                    LabeledContent("Found at", value: ClaudeCodeBackend.locate(customPath: settings.claudePath)?.path ?? "not found")
                    TextField("Custom path (leave empty to search)", text: $settings.claudePath)
                    Text("Sign in once in Terminal with `claude auth login`. Talk2Me never sees your Claude login; it runs your own Claude Code, the way T3 Code does.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.backend == .apiKey {
                Section("Claude API key") {
                    SecureField(apiKeySaved ? "Saved in the Keychain" : "sk-ant-…", text: $apiKeyDraft)
                    HStack {
                        Button("Save key") {
                            let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !key.isEmpty, KeychainStore.save(key) else { return }
                            controller.updateAPIKeyCache(key)
                            apiKeyDraft = ""
                            apiKeySaved = true
                        }
                        .disabled(apiKeyDraft.isEmpty)
                        Button("Remove key", role: .destructive) {
                            KeychainStore.delete()
                            controller.updateAPIKeyCache(nil)
                            apiKeySaved = false
                        }
                        .disabled(!apiKeySaved)
                    }
                    Text("Create a key at platform.claude.com. Usage is billed to that key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Dictation") {
                Picker("Language", selection: $settings.localeID) {
                    if !languages.contains(where: { $0.identifier == settings.localeID }) {
                        Text(settings.localeID).tag(settings.localeID)
                    }
                    ForEach(languages, id: \.identifier) { locale in
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .tag(locale.identifier)
                    }
                }
                .onChange(of: settings.localeID) { languageChanged() }
            }

            Section("Try it") {
                Button(testing ? "Cleaning up…" : "Test cleanup with a sample sentence") {
                    Task { await runTest() }
                }
                .disabled(testing || settings.backend == .off)
                if !testOutput.isEmpty {
                    Text(testOutput).textSelection(.enabled).font(.callout)
                }
            }

            Section("Permissions") {
                permissionRow("Accessibility (shortcut keys and pasting)", granted: accessibilityGranted) {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                permissionRow("Microphone", granted: microphoneGranted) {
                    Task {
                        if Permissions.microphoneStatus == .undetermined {
                            microphoneGranted = await Permissions.requestMicrophone()
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .task {
            apiKeySaved = KeychainStore.read() != nil
            languages = await OnDeviceDictation.supportedLocales().sorted { $0.identifier < $1.identifier }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = Permissions.accessibilityGranted
            microphoneGranted = Permissions.microphoneStatus == .granted
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
            Spacer()
            if !granted { Button("Grant…", action: action) }
        }
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        let outcome = await CleanupRouter.run(
            transcript: sample,
            backend: controller.makeBackend(),
            model: settings.model,
            instructions: CleanupPrompt.system(extraInstructions: settings.extraInstructions),
            timeout: .seconds(settings.timeoutSeconds)
        )
        let seconds = Double(outcome.duration.components.seconds) + Double(outcome.duration.components.attoseconds) / 1e18
        testOutput = outcome.cleaned
            ? String(format: "%.1f s: ", seconds) + outcome.text
            : "Failed: \(outcome.failure ?? "unknown error")"
    }
}

/// A shortcut key choice: a preset from the menu, or any key recorded by pressing it.
private struct ShortcutPicker: View {
    let title: String
    @Binding var key: ShortcutKey
    let recordKey: (@escaping (ShortcutKey?) -> Void) -> Void
    let cancelRecording: () -> Void

    @State private var recording = false
    @State private var updated = false

    private var options: [ShortcutKey] {
        ShortcutKey.presets.contains(key) ? ShortcutKey.presets : ShortcutKey.presets + [key]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(title, selection: $key) {
                    ForEach(options, id: \.self) { option in
                        Text(KeyboardLayout.name(of: option)).tag(option)
                    }
                }
                Button(recording ? "Cancel" : "Record a key…") {
                    if recording {
                        cancelRecording()
                        return
                    }
                    updated = false
                    recording = true
                    recordKey { captured in
                        recording = false
                        guard let captured else { return }
                        key = captured
                        updated = true
                    }
                }
            }
            if recording {
                Text("Press the key you want to use… (Esc cancels)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if updated {
                Text("Shortcut updated.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !key.isModifier {
                Text("\(KeyboardLayout.name(of: key)) won't type anything in other apps while Talk2Me is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
