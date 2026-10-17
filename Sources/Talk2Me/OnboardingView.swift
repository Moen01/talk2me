import AppKit
import SwiftUI
import Talk2MeCore

/// The first-run setup guide: permissions, connecting Claude, choosing a shortcut, and a practice run.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, claude, shortcut, tryIt
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: DictationController
    let recordKey: (@escaping (ShortcutKey?) -> Void) -> Void
    let cancelRecording: () -> Void
    let finish: () -> Void

    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: step.rawValue, count: Step.allCases.count)
                .padding(.top, 34)
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep()
                case .claude: ConnectClaudeStep(settings: settings, controller: controller)
                case .shortcut: ShortcutStep(settings: settings, recordKey: recordKey, cancelRecording: cancelRecording)
                case .tryIt: TryItStep(settings: settings, controller: controller)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 48)
            .padding(.top, 20)
            .transition(.opacity)

            Divider()
            HStack {
                if step != .welcome {
                    Button("Back") { move(-1) }
                        .controlSize(.large)
                }
                Spacer()
                Button(primaryTitle) {
                    if step == .tryIt { finish() } else { move(1) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 640, height: 640)
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get Started"
        case .tryIt: "Finish"
        default: "Continue"
        }
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { step = next }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 28) {
            StepHeader(symbol: "waveform", title: "Welcome to Talk2Me",
                       subtitle: "Hold a key, speak, and your words appear in any app, cleaned up by Claude.")
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "lock.shield", title: "Private by default",
                           text: "Your voice is turned into text on this Mac. Audio is never uploaded or saved.")
                FeatureRow(symbol: "sparkles", title: "Polished by Claude",
                           text: "Punctuation, filler words and spoken formatting like \"new paragraph\" are fixed for you.")
                FeatureRow(symbol: "text.cursor", title: "Works everywhere",
                           text: "Mail, Slack, Notes, your code editor: anywhere you can type.")
            }
            .frame(maxWidth: 440)
        }
    }
}

private struct PermissionsStep: View {
    @State private var microphone = Permissions.microphoneStatus == .granted
    @State private var accessibility = Permissions.accessibilityGranted

    var body: some View {
        VStack(spacing: 28) {
            StepHeader(symbol: "hand.raised", title: "Allow access",
                       subtitle: "Talk2Me needs two permissions. You can change them later in System Settings.")
            VStack(spacing: 12) {
                PermissionCard(symbol: "mic", title: "Microphone",
                               text: "To hear you while you hold your shortcut.",
                               granted: microphone) {
                    Task {
                        if Permissions.microphoneStatus == .undetermined {
                            microphone = await Permissions.requestMicrophone()
                        } else {
                            Permissions.openMicrophoneSettings()
                        }
                    }
                }
                PermissionCard(symbol: "keyboard", title: "Accessibility",
                               text: "To notice your shortcut key and type the text into other apps. Turn on Talk2Me in the list that opens.",
                               granted: accessibility) {
                    Permissions.promptForAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
            .frame(maxWidth: 480)
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            microphone = Permissions.microphoneStatus == .granted
            accessibility = Permissions.accessibilityGranted
        }
    }
}

private struct ConnectClaudeStep: View {
    @ObservedObject var settings: AppSettings
    let controller: DictationController

    @State private var status: ClaudeCodeBackend.Status?
    @State private var checking = false
    @State private var apiKeyDraft = ""
    @State private var apiKeySaved = KeychainStore.read() != nil
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    private var claudePath: URL? { ClaudeCodeBackend.locate(customPath: settings.claudePath) }

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(symbol: "sparkles", title: "Connect Claude",
                       subtitle: "Claude tidies up what you say. Pick how Talk2Me reaches it.")
            Picker("", selection: $settings.backend) {
                Text("Claude subscription").tag(CleanupBackendKind.claudeCode)
                Text("API key").tag(CleanupBackendKind.apiKey)
                Text("Skip for now").tag(CleanupBackendKind.off)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            Card {
                switch settings.backend {
                case .claudeCode: subscriptionCard
                case .apiKey: apiKeyCard
                case .off:
                    Label("You'll get the raw transcript without cleanup. You can connect Claude any time in Settings.",
                          systemImage: "text.alignleft")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 480)

            if settings.backend != .off {
                HStack {
                    Picker("Model", selection: $settings.model) {
                        ForEach(ClaudeModel.allCases) { Text($0.displayName).tag($0) }
                    }
                    .frame(maxWidth: 280)
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                        .disabled(testing)
                }
                if let testResult {
                    Label(testResult.text, systemImage: testResult.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(testResult.ok ? .green : .orange)
                        .font(.callout)
                        .frame(maxWidth: 480, alignment: .leading)
                        .lineLimit(3)
                }
            }
        }
        .task(id: settings.backend) {
            testResult = nil
            if settings.backend == .claudeCode { await refreshStatus() }
        }
        .onChange(of: settings.model) { testResult = nil }
    }

    @ViewBuilder private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let claudePath {
                if checking {
                    HStack { ProgressView().controlSize(.small); Text("Checking Claude Code…") }
                } else if let status, status.loggedIn {
                    Label(signedInText(status), systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                    if let version = status.version {
                        Text("Claude Code \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                    if !status.supports(settings.model) {
                        Label("\(settings.model.displayName) needs Claude Code \(settings.model.minimumClaudeCodeVersion ?? "") or newer.",
                              systemImage: "arrow.up.circle")
                            .foregroundStyle(.orange)
                        Button("Update Claude Code") {
                            TerminalCommand.run("'\(claudePath.path)' update", name: "update")
                        }
                    }
                } else {
                    Label("Claude Code isn't signed in yet", systemImage: "person.crop.circle.badge.questionmark")
                        .font(.headline)
                    Text("Sign in once with your Claude account. A Terminal window opens for it.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Sign In…") { TerminalCommand.run("'\(claudePath.path)' auth login", name: "sign-in") }
                            .buttonStyle(.borderedProminent)
                        Button("Check Again") { Task { await refreshStatus() } }
                    }
                }
            } else {
                Label("Claude Code isn't installed", systemImage: "shippingbox")
                    .font(.headline)
                Text("Install Claude Code, then sign in with your Claude account.")
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Get Claude Code", destination: URL(string: "https://claude.com/product/claude-code")!)
                    Button("Check Again") { Task { await refreshStatus() } }
                }
            }
            Text("Talk2Me runs your own Claude Code and never sees your Claude login.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SecureField(apiKeySaved ? "Saved in your Keychain" : "Paste your key (sk-ant-…)", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, KeychainStore.save(key) else { return }
                    controller.updateAPIKeyCache(key)
                    apiKeyDraft = ""
                    apiKeySaved = true
                }
                .disabled(apiKeyDraft.isEmpty)
            }
            if apiKeySaved {
                Label("Key saved in your Keychain", systemImage: "key.fill")
                    .foregroundStyle(.green)
            }
            HStack(spacing: 4) {
                Text("Usage is billed to your key.")
                Link("Get an API key", destination: URL(string: "https://platform.claude.com/settings/keys")!)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signedInText(_ status: ClaudeCodeBackend.Status) -> String {
        if status.authMethod == "claude.ai", let plan = status.subscriptionType {
            return "Signed in · Claude \(plan.capitalized) plan"
        }
        return "Signed in"
    }

    private func refreshStatus() async {
        guard let claudePath else { status = nil; return }
        checking = true
        status = await ClaudeCodeBackend.status(of: claudePath)
        checking = false
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let outcome = await CleanupRouter.run(
            transcript: "um so this is uh a quick test of talk to me new paragraph it works",
            backend: controller.makeBackend(),
            model: settings.model,
            instructions: CleanupPrompt.system(extraInstructions: settings.extraInstructions),
            timeout: .seconds(max(settings.timeoutSeconds, 30))
        )
        let seconds = Double(outcome.duration.components.seconds) + Double(outcome.duration.components.attoseconds) / 1e18
        testResult = outcome.cleaned
            ? (true, String(format: "Connected. Claude answered in %.1f s.", seconds))
            : (false, outcome.failure ?? "No answer from Claude.")
    }
}

private struct ShortcutStep: View {
    @ObservedObject var settings: AppSettings
    let recordKey: (@escaping (ShortcutKey?) -> Void) -> Void
    let cancelRecording: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            StepHeader(symbol: "keyboard", title: "Choose your shortcut",
                       subtitle: "Hold it to talk, let go to paste. A key you rarely use on its own works best.")
            KeyCap(name: KeyboardLayout.name(of: settings.holdKey))
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    ShortcutPicker(title: "Hold to dictate", key: $settings.holdKey,
                                   recordKey: recordKey, cancelRecording: cancelRecording)
                    Divider()
                    Toggle("Hands-free mode for longer dictation", isOn: $settings.handsFreeEnabled)
                    if settings.handsFreeEnabled {
                        ShortcutPicker(title: "Double-tap", key: $settings.handsFreeKey,
                                       recordKey: recordKey, cancelRecording: cancelRecording)
                        Text("Then speak freely. Press Enter to paste, or Esc to discard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if settings.holdKey.isFn || (settings.handsFreeEnabled && settings.handsFreeKey.isFn) {
                        Divider()
                        Toggle("Stop Fn from opening the emoji picker", isOn: $settings.suppressFnKey)
                    }
                }
            }
            .frame(maxWidth: 480)
        }
    }
}

private struct TryItStep: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: DictationController
    @State private var practice = ""
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 20) {
            StepHeader(symbol: "checkmark.circle", title: "Try it",
                       subtitle: "Click in the box, hold \(KeyboardLayout.name(of: settings.holdKey)) and say something. Let go to paste.")
            TextEditor(text: $practice)
                .font(.body)
                .focused($focused)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(maxWidth: 480, minHeight: 130, maxHeight: 150)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                .overlay(alignment: .topLeading) {
                    if practice.isEmpty {
                        Text("Your words appear here…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
            Label(statusText, systemImage: statusSymbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480, alignment: .leading)
                .lineLimit(2)
            Toggle("Open Talk2Me when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
                .frame(maxWidth: 480, alignment: .leading)
            Text("Talk2Me lives in your menu bar. Click its icon for Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { focused = true }
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: controller.lastResult == "No dictation yet." ? controller.readiness : "Last: \(controller.lastResult)"
        case .recording: controller.isHandsFree ? "Hands-free: press Enter when you're done." : "Listening…"
        case .transcribing: "Transcribing on this Mac…"
        case .cleaning: "Cleaning up with Claude…"
        case .inserting: "Pasting…"
        }
    }

    private var statusSymbol: String {
        switch controller.phase {
        case .idle: "info.circle"
        case .recording: "mic.fill"
        case .transcribing, .cleaning, .inserting: "ellipsis.circle"
        }
    }
}

// MARK: - Building blocks

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FeatureRow: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.indigo)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionCard: View {
    let symbol: String
    let title: String
    let text: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.indigo)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Allow…", action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct KeyCap: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background)
                    .shadow(color: .black.opacity(0.18), radius: 0, x: 0, y: 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
    }
}

private struct StepDots: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: index == current ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// Opens a Terminal window running one command, for steps that need the user's own Terminal
/// (signing in to Claude Code, updating it).
enum TerminalCommand {
    static func run(_ command: String, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("talk2me-\(name).command")
        let script = """
        #!/bin/zsh
        clear
        \(command)
        echo
        echo "Done. You can close this window and go back to Talk2Me."
        """
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}
