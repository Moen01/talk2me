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
    private var tapRetryTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DictationController(settings: settings)
        statusBar = StatusBarController(controller: controller) { [weak self] in self?.showSettings() }
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

        Task {
            if Permissions.microphoneStatus == .undetermined { _ = await Permissions.requestMicrophone() }
            await controller.prepareDictation()
        }
        startHotkeys()

        if !settings.hasOpenedSettings {
            settings.hasOpenedSettings = true
            showSettings()
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
        Permissions.promptForAccessibility()
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
}
