import AppKit
import SwiftUI
import Talk2MeCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, hotkey, cleanup, dictionary, snippets, permissions, language

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .hotkey: "Hotkey"
        case .cleanup: "Cleanup with Claude"
        case .dictionary: "Dictionary"
        case .snippets: "Snippets"
        case .permissions: "Permissions"
        case .language: "Language"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .hotkey: "keyboard"
        case .cleanup: "sparkles"
        case .dictionary: "character.book.closed"
        case .snippets: "bolt"
        case .permissions: "lock.shield"
        case .language: "globe"
        }
    }
}

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
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var page: SettingsPage? = .general

    private let sample = "um so I was thinking we should uh move the meeting to thursday new paragraph also can you send me the slides"

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.systemImage).tag(page)
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Form { content(for: page ?? .general) }
                .formStyle(.grouped)
        }
        // A grouped Form scrolls and has no height of its own, so without one the window
        // sized to it can collapse to just its title bar.
        .frame(width: 760, height: 600)
        .task {
            apiKeySaved = KeychainStore.read() != nil
            languages = await OnDeviceDictation.supportedLocales().sorted { $0.identifier < $1.identifier }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            accessibilityGranted = Permissions.accessibilityGranted
            microphoneGranted = Permissions.microphoneStatus == .granted
        }
    }

    @ViewBuilder
    private func content(for page: SettingsPage) -> some View {
        switch page {
        case .general: general
        case .hotkey: hotkey
        case .cleanup: cleanup
        case .dictionary: DictionaryEditor(entries: $settings.dictionary)
        case .snippets: SnippetsEditor(snippets: $settings.snippets)
        case .permissions: permissions
        case .language: language
        }
    }

    private var general: some View {
        Section {
            Toggle("Open Talk2Me when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
            UpdateRow()
        }
    }

    @ViewBuilder
    private var hotkey: some View {
        Section {
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
    }

    @ViewBuilder
    private var cleanup: some View {
        Section {
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

        Section("Try it") {
            Button(testing ? "Cleaning up…" : "Test cleanup with a sample sentence") {
                Task { await runTest() }
            }
            .disabled(testing || settings.backend == .off)
            if !testOutput.isEmpty {
                Text(testOutput).textSelection(.enabled).font(.callout)
            }
        }
    }

    private var permissions: some View {
        Section {
            permissionRow("Accessibility (shortcut keys and pasting)", granted: accessibilityGranted) {
                Permissions.requestAccessibility()
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

    private var language: some View {
        Section {
            Picker("Dictation language", selection: $settings.localeID) {
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
            instructions: settings.cleanupInstructions,
            timeout: .seconds(settings.timeoutSeconds)
        )
        let seconds = Double(outcome.duration.components.seconds) + Double(outcome.duration.components.attoseconds) / 1e18
        testOutput = outcome.cleaned
            ? String(format: "%.1f s: ", seconds) + outcome.text
            : "Failed: \(outcome.failure ?? "unknown error")"
    }
}

/// A shortcut key choice: a preset from the menu, or any key recorded by pressing it.
/// The installed version, a button that asks GitHub for a newer release, and a blue button
/// that installs it.
struct UpdateRow: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    @State private var checking = false
    @State private var outcome: Result<UpdateChecker.Result, Error>?
    @State private var step: SelfUpdater.Step?
    @State private var installError: String?

    var body: some View {
        LabeledContent("Version \(version)") {
            HStack {
                if case .success(.available(let update)) = outcome {
                    Button(installTitle(update)) { Task { await install(update) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(step != nil)
                }
                Button(checking ? "Checking…" : "Check for Updates") {
                    Task { await check() }
                }
                .disabled(checking || step != nil)
            }
        }
        // Checks each time Settings opens, so a waiting update shows without a click.
        .task { await check() }
        switch outcome {
        case .success(.available(let update)):
            if let installError {
                HStack {
                    Text("Could not install: \(installError)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Link("Open release page", destination: update.page).font(.caption)
                }
            }
        case .success(.upToDate):
            Text("You have the latest version.").foregroundStyle(.secondary)
        case .failure(let error):
            Text("Could not check for updates: \(error.localizedDescription)")
                .font(.caption)
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private func installTitle(_ update: UpdateChecker.Update) -> String {
        switch step {
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case nil: "Update to \(update.version)"
        }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        do {
            outcome = .success(try await UpdateChecker.check(currentVersion: version))
        } catch {
            outcome = .failure(error)
        }
    }

    /// On success Talk2Me quits and the new version opens, so only failures come back here.
    private func install(_ update: UpdateChecker.Update) async {
        installError = nil
        defer { step = nil }
        do {
            try await SelfUpdater.install(update) { step = $0 }
        } catch {
            installError = error.localizedDescription
        }
    }
}

struct ShortcutPicker: View {
    let title: String
    @Binding var key: ShortcutKey
    let recordKey: (@escaping (ShortcutKey?) -> Void) -> Void
    let cancelRecording: () -> Void

    @State private var recording = false
    @State private var updated = false
    // Shortcut keys reach Talk2Me only through the event tap, which needs Accessibility.
    @State private var trusted = Permissions.accessibilityGranted

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
                .disabled(!trusted && !recording)
            }
            if !trusted {
                HStack {
                    Text("Talk2Me can't see key presses without Accessibility access.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Allow Accessibility…") { Permissions.requestAccessibility() }
                        .controlSize(.small)
                }
            } else if recording {
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
        .onReceive(Permissions.ticks) { _ in
            let now = Permissions.accessibilityGranted
            if now != trusted { trusted = now }
        }
    }
}
