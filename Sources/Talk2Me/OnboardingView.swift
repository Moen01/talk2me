import AppKit
import SwiftUI
import Talk2MeCore

/// The first-run setup guide: permissions, connecting Claude, choosing a shortcut, and a practice run.
/// The sidebar shows which steps are done, so you can jump to whatever still needs you.
struct OnboardingView: View {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, permissions, claude, shortcut, tryIt, ready

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .permissions: "Permissions"
            case .claude: "Connect Claude"
            case .shortcut: "Shortcut"
            case .tryIt: "Try it"
            case .ready: "Ready"
            }
        }

        var symbol: String {
            switch self {
            case .welcome: "hand.wave"
            case .permissions: "hand.raised"
            case .claude: "sparkles"
            case .shortcut: "keyboard"
            case .tryIt: "waveform"
            case .ready: "checkmark.seal"
            }
        }
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: DictationController
    let recordKey: (@escaping (ShortcutKey?) -> Void) -> Void
    let cancelRecording: () -> Void
    let finish: () -> Void

    @State private var step: Step = .welcome
    @StateObject private var setup = SetupStatus()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch step {
                        case .welcome: WelcomeStep()
                        case .permissions: PermissionsStep(setup: setup)
                        case .claude: ConnectClaudeStep(settings: settings, controller: controller, setup: setup)
                        case .shortcut: ShortcutStep(settings: settings, recordKey: recordKey, cancelRecording: cancelRecording)
                        case .tryIt: TryItStep(settings: settings, controller: controller, setup: setup)
                        case .ready: ReadyStep(settings: settings, setup: setup) { step = $0 }
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                Divider()
                footer
            }
        }
        .frame(width: 780, height: 600)
        .task { await setup.refresh(settings: settings) }
        .onReceive(Permissions.ticks) { _ in setup.refreshPermissions() }
    }

    // MARK: Frame

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Set up Talk2Me").font(.headline)
            }
            .padding(.bottom, 14)
            ForEach(Step.allCases) { item in
                Button { step = item } label: {
                    HStack(spacing: 8) {
                        StepStatusIcon(state: setup.state(of: item, settings: settings), symbol: item.symbol)
                        Text(item.title)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(step == item ? Color.accentColor.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("Open this again from the menu-bar icon: Setup Guide…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            Spacer()
            Button {
                Task { await setup.refresh(settings: settings) }
            } label: {
                Label(setup.checking ? "Checking…" : "Check Again", systemImage: "arrow.clockwise")
            }
            .disabled(setup.checking)
            .help("Check every step again, after you changed something in System Settings or Terminal")
            if step == .ready {
                Button("Start Using Talk2Me", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip Setup", action: finish)
                Button(step == .welcome ? "Get Started" : "Next") { move(1) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(16)
    }

    private func move(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        step = next
    }
}

// MARK: - Status

/// What is already in place, shared by the sidebar, the steps and the summary.
@MainActor
final class SetupStatus: ObservableObject {
    enum State { case done, attention, optional, none }

    @Published private(set) var microphone = Permissions.microphoneStatus == .granted
    @Published private(set) var accessibility = Permissions.accessibilityGranted
    @Published private(set) var claude: ClaudeCodeBackend.Status?
    @Published private(set) var checking = false
    // Read once and after a save: the Keychain is too slow to ask on every redraw.
    @Published var apiKeySaved = KeychainStore.read() != nil
    @Published var practiced = false

    func refreshPermissions() {
        let mic = Permissions.microphoneStatus == .granted
        let ax = Permissions.accessibilityGranted
        if mic != microphone { microphone = mic }
        if ax != accessibility { accessibility = ax }
    }

    func refresh(settings: AppSettings) async {
        checking = true
        defer { checking = false }
        refreshPermissions()
        apiKeySaved = KeychainStore.read() != nil
        await refreshClaude(settings: settings)
    }

    func refreshClaude(settings: AppSettings) async {
        guard let path = ClaudeCodeBackend.locate(customPath: settings.claudePath) else {
            claude = nil
            return
        }
        claude = await ClaudeCodeBackend.status(of: path)
    }

    func claudeReady(_ settings: AppSettings) -> Bool {
        switch settings.backend {
        case .off: false
        case .apiKey: apiKeySaved
        case .claudeCode: claude.map { $0.loggedIn && $0.supports(settings.model) } ?? false
        }
    }

    func state(of step: OnboardingView.Step, settings: AppSettings) -> State {
        switch step {
        case .welcome, .ready: .none
        case .permissions: microphone && accessibility ? .done : .attention
        case .claude: settings.backend == .off ? .optional : claudeReady(settings) ? .done : .attention
        case .shortcut: .done
        case .tryIt: practiced ? .done : .optional
        }
    }
}

// MARK: - Steps

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
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
            .frame(maxWidth: 460, alignment: .leading)
        }
    }
}

private struct PermissionsStep: View {
    @ObservedObject var setup: SetupStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(symbol: "hand.raised", title: "Allow access",
                       subtitle: "Talk2Me needs two permissions. You can change them later in System Settings.")
            VStack(spacing: 10) {
                SetupRow(ok: setup.microphone, title: "Microphone",
                         detail: "To hear you while you hold your shortcut.") {
                    if !setup.microphone {
                        Button("Allow…") {
                            Task {
                                if Permissions.microphoneStatus == .undetermined {
                                    _ = await Permissions.requestMicrophone()
                                } else {
                                    Permissions.openMicrophoneSettings()
                                }
                                setup.refreshPermissions()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                SetupRow(ok: setup.accessibility, title: "Accessibility",
                         detail: "To notice your shortcut key and type the text into other apps. Turn on Talk2Me in the list that opens.") {
                    if !setup.accessibility {
                        Button("Allow…") {
                            Permissions.requestAccessibility()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .frame(maxWidth: 500)
        }
    }
}

private struct ConnectClaudeStep: View {
    @ObservedObject var settings: AppSettings
    let controller: DictationController
    @ObservedObject var setup: SetupStatus

    @State private var checking = false
    @State private var apiKeyDraft = ""
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false

    private var claudePath: URL? { ClaudeCodeBackend.locate(customPath: settings.claudePath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
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
                } else if let status = setup.claude, status.loggedIn {
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
                SecureField(setup.apiKeySaved ? "Saved in your Keychain" : "Paste your key (sk-ant-…)", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty, KeychainStore.save(key) else { return }
                    controller.updateAPIKeyCache(key)
                    apiKeyDraft = ""
                    setup.apiKeySaved = true
                }
                .disabled(apiKeyDraft.isEmpty)
            }
            if setup.apiKeySaved {
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
        checking = true
        await setup.refreshClaude(settings: settings)
        checking = false
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let outcome = await CleanupRouter.run(
            transcript: "um so this is uh a quick test of talk to me new paragraph it works",
            backend: controller.makeBackend(),
            model: settings.model,
            instructions: settings.cleanupInstructions,
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
        VStack(alignment: .leading, spacing: 24) {
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
    @ObservedObject var setup: SetupStatus
    @State private var practice = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(symbol: "waveform", title: "Try it",
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
        }
        .onAppear { focused = true }
        // Only a dictation that reached the paste step counts, not typing into the box.
        .onChange(of: controller.phase) { old, new in
            if old == .inserting, new == .idle { setup.practiced = true }
        }
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

private struct ReadyStep: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var setup: SetupStatus
    let go: (OnboardingView.Step) -> Void
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(symbol: "checkmark.seal", title: "You're set",
                       subtitle: "Talk2Me lives in your menu bar. Hold \(KeyboardLayout.name(of: settings.holdKey)) in any app to dictate.")
            VStack(spacing: 10) {
                SetupRow(ok: setup.microphone && setup.accessibility, title: "Permissions",
                         detail: setup.microphone && setup.accessibility
                             ? "Microphone and Accessibility are allowed."
                             : "Talk2Me can't hear you or paste until both are allowed.") {
                    if !(setup.microphone && setup.accessibility) { Button("Fix…") { go(.permissions) } }
                }
                SetupRow(ok: settings.backend == .off ? nil : setup.claudeReady(settings), title: "Claude cleanup",
                         detail: claudeDetail) {
                    if !setup.claudeReady(settings) { Button(settings.backend == .off ? "Connect…" : "Fix…") { go(.claude) } }
                }
                SetupRow(ok: true, title: "Shortcut",
                         detail: "Hold \(KeyboardLayout.name(of: settings.holdKey)) to dictate." + (settings.handsFreeEnabled
                             ? " Double-tap \(KeyboardLayout.name(of: settings.handsFreeKey)) for hands-free." : "")) {
                    Button("Change…") { go(.shortcut) }
                }
                SetupRow(ok: setup.practiced ? true : nil, title: "Practice",
                         detail: setup.practiced ? "You tried a dictation." : "Optional: try one dictation before you start.") {
                    if !setup.practiced { Button("Try It…") { go(.tryIt) } }
                }
            }
            .frame(maxWidth: 500)
            Toggle("Open Talk2Me when I log in", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
        }
    }

    private var claudeDetail: String {
        switch settings.backend {
        case .off: "Off: you get the raw transcript. Optional."
        case .apiKey: setup.apiKeySaved ? "Using your API key with \(settings.model.displayName)." : "No API key saved yet."
        case .claudeCode:
            setup.claudeReady(settings)
                ? "Using your Claude subscription with \(settings.model.displayName)."
                : "Claude Code is not installed, not signed in, or too old for \(settings.model.displayName)."
        }
    }
}

// MARK: - Building blocks

/// One thing to have in place: done (true), needs you (false) or optional (nil), with its fix beside it.
private struct SetupRow<Actions: View>: View {
    let ok: Bool?
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StepStatusIcon(state: ok == true ? .done : ok == false ? .attention : .optional, symbol: "circle")
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct StepStatusIcon: View {
    let state: SetupStatus.State
    let symbol: String

    var body: some View {
        switch state {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .attention: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .optional: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        case .none: Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .bold))
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
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
