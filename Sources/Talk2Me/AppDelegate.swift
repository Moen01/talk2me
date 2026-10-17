import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private let hotkeys = HotkeyMonitor()
    private var controller: DictationController!
    private var statusBar: StatusBarController!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var tapRetryTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DictationController(settings: settings)
        statusBar = StatusBarController(controller: controller, actions: .init(
            openSettings: { [weak self] in self?.showSettings() },
            openSetupGuide: { [weak self] in self?.showOnboarding() },
            openAbout: { [weak self] in self?.showAbout() }
        ))
        controller.onChange = { [weak self] in self?.statusBar.refresh() }

        if settings.backend == .apiKey {
            controller.updateAPIKeyCache(KeychainStore.read())
        }

        hotkeys.suppressFnKey = settings.suppressFnKey
        hotkeys.bindings = settings.shortcutBindings
        hotkeys.onShortcut = { [weak self] roles, down in self?.controller.shortcutChanged(roles, down: down) }
        hotkeys.wantsKeyEvents = { [weak self] in self?.controller.wantsKeyEvents ?? false }
        hotkeys.onKeyDown = { [weak self] code in self?.controller.keyDown(code) ?? false }
        settings.$suppressFnKey
            .sink { [weak self] value in self?.hotkeys.suppressFnKey = value }
            .store(in: &subscriptions)
        // @Published fires before the stored value changes, so read the new bindings on the next turn.
        Publishers.Merge3(
            settings.$holdKey.map { _ in () },
            settings.$handsFreeKey.map { _ in () },
            settings.$handsFreeEnabled.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self else { return }
            let bindings = self.settings.shortcutBindings
            guard bindings != self.hotkeys.bindings else { return }
            self.hotkeys.bindings = bindings
            self.controller.shortcutsWereReplaced()
        }
        .store(in: &subscriptions)
        settings.$backend
            .sink { [weak self] backend in
                if backend == .apiKey { self?.controller.updateAPIKeyCache(KeychainStore.read()) }
            }
            .store(in: &subscriptions)

        Task { await controller.prepareDictation() }
        startHotkeys()

        // First launch: the setup guide asks for permissions itself, one at a time.
        if settings.hasCompletedOnboarding {
            Task {
                if Permissions.microphoneStatus == .undetermined { _ = await Permissions.requestMicrophone() }
            }
        } else {
            showOnboarding()
        }
    }

    /// The event tap needs Accessibility access; keep retrying until the user grants it.
    private func startHotkeys() {
        if hotkeys.start() {
            tapRetryTimer?.invalidate()
            tapRetryTimer = nil
            statusBar.refresh()
            return
        }
        if settings.hasCompletedOnboarding { Permissions.promptForAccessibility() }
        tapRetryTimer?.invalidate()
        tapRetryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Permissions.accessibilityGranted, self.hotkeys.start() else { return }
                self.tapRetryTimer?.invalidate()
                self.tapRetryTimer = nil
                self.statusBar.refresh()
            }
        }
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(
                settings: settings,
                controller: controller,
                recordKey: { [weak self] completion in self?.hotkeys.captureNextKey(completion) },
                cancelRecording: { [weak self] in self?.hotkeys.cancelCapture() },
                languageChanged: { [weak self] in
                    guard let self else { return }
                    Task { await self.controller.prepareDictation() }
                }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Talk2Me Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                settings: settings,
                controller: controller,
                recordKey: { [weak self] completion in self?.hotkeys.captureNextKey(completion) },
                cancelRecording: { [weak self] in self?.hotkeys.cancelCapture() },
                finish: { [weak self] in self?.onboardingWindow?.close() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Welcome to Talk2Me"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                // Closing the guide counts as done; it stays available from the menu.
                MainActor.assumeIsolated { self?.settings.hasCompletedOnboarding = true }
            }
            onboardingWindow = window
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let credits = NSAttributedString(
            string: "Hold a key to dictate. Speech is transcribed on your Mac and cleaned up by Claude.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Talk2Me",
            .applicationVersion: version,
            .credits: credits,
        ])
    }
}
