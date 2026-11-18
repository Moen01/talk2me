import AppKit

/// The menu-bar icon and its menu.
@MainActor
final class StatusBarController: NSObject {
    struct Actions {
        var openSettings: () -> Void
        var openSetupGuide: () -> Void
        var openAbout: () -> Void
        var startOrchestrator: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let orchestrator: OrchestratorController
    private let settings: AppSettings
    private let actions: Actions
    private let stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resultLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
    // Orchestrator items — hidden when orchestrate is disabled.
    private let orchestratorSeparator = NSMenuItem.separator()
    private let orchestratorLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let startOrchestratorItem: NSMenuItem

    init(controller: DictationController, orchestrator: OrchestratorController, settings: AppSettings, actions: Actions) {
        self.controller = controller
        self.orchestrator = orchestrator
        self.settings = settings
        self.actions = actions
        startOrchestratorItem = NSMenuItem(title: "Start Orchestrator", action: nil, keyEquivalent: "")
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        stateLine.isEnabled = false
        resultLine.isEnabled = false
        orchestratorLine.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(resultLine)
        menu.addItem(orchestratorSeparator)
        menu.addItem(orchestratorLine)
        menu.addItem(startOrchestratorItem)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(menuItem(title: "Settings…", action: #selector(showSettings), key: ","))
        menu.addItem(menuItem(title: "Setup Guide…", action: #selector(showSetupGuide), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "About Talk2Me", action: #selector(showAbout), key: ""))
        menu.addItem(NSMenuItem(title: "Quit Talk2Me", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        accessibilityItem.target = self
        startOrchestratorItem.target = self
        startOrchestratorItem.action = #selector(startOrchestrator)
        self.item.menu = menu
        refresh()
    }

    private func menuItem(title: String, action: Selector, key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    func refresh() {
        let (symbol, state): (String, String) = switch controller.phase {
        case .idle: ("waveform", controller.readiness)
        case .recording where controller.isHandsFree: ("mic.fill", "Hands-free: press Enter to finish, Esc to discard")
        case .recording:
            if let label = controller.recordingTargetLabel {
                ("mic.fill", "Recording → \(label)")
            } else {
                ("mic.fill", "Listening… release \(controller.holdKeyName) to finish")
            }
        case .transcribing: ("ellipsis.circle", "Transcribing on this Mac…")
        case .cleaning: ("sparkles", "Cleaning up with Claude…")
        case .inserting: ("text.cursor", "Pasting…")
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Talk2Me: \(state)")
        stateLine.title = state
        resultLine.title = "Last: \(controller.lastResult)"
        accessibilityItem.isHidden = Permissions.accessibilityGranted

        let orchestrateEnabled = settings.orchestrateEnabled
        orchestratorSeparator.isHidden = !orchestrateEnabled
        orchestratorLine.isHidden = !orchestrateEnabled
        startOrchestratorItem.isHidden = !orchestrateEnabled

        if orchestrateEnabled {
            // lastStatus carries the real outcome: "Running.", a failure line, or the
            // Automation-denied line — the menu shows exactly why a start did not take.
            orchestratorLine.title = "Orchestrator: \(orchestrator.lastStatus)"
            switch orchestrator.state {
            case .notRunning:
                startOrchestratorItem.isEnabled = true
            case .running:
                // Disable while running so the user can't start a second instance.
                startOrchestratorItem.isEnabled = false
            }
        }
    }

    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
    }

    @objc private func startOrchestrator() {
        actions.startOrchestrator()
    }

    @objc private func showSettings() { actions.openSettings() }
    @objc private func showSetupGuide() { actions.openSetupGuide() }
    @objc private func showAbout() { actions.openAbout() }
}
