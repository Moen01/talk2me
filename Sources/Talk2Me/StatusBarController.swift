import AppKit

/// The menu-bar icon and its menu.
@MainActor
final class StatusBarController: NSObject {
    struct Actions {
        var openSettings: () -> Void
        var openSetupGuide: () -> Void
        var openAbout: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let actions: Actions
    private let stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resultLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")

    init(controller: DictationController, actions: Actions) {
        self.controller = controller
        self.actions = actions
        super.init()

        let menu = NSMenu()
        stateLine.isEnabled = false
        resultLine.isEnabled = false
        menu.addItem(stateLine)
        menu.addItem(resultLine)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        menu.addItem(menuItem(title: "Settings…", action: #selector(showSettings), key: ","))
        menu.addItem(menuItem(title: "Setup Guide…", action: #selector(showSetupGuide), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "About Talk2Me", action: #selector(showAbout), key: ""))
        menu.addItem(NSMenuItem(title: "Quit Talk2Me", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        accessibilityItem.target = self
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
        case .recording: ("mic.fill", "Listening… release \(controller.holdKeyName) to finish")
        case .transcribing: ("ellipsis.circle", "Transcribing on this Mac…")
        case .cleaning: ("sparkles", "Cleaning up with Claude…")
        case .inserting: ("text.cursor", "Pasting…")
        }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Talk2Me: \(state)")
        stateLine.title = state
        resultLine.title = "Last: \(controller.lastResult)"
        accessibilityItem.isHidden = Permissions.accessibilityGranted
    }

    @objc private func openAccessibility() {
        Permissions.promptForAccessibility()
        Permissions.openAccessibilitySettings()
    }

    @objc private func showSettings() { actions.openSettings() }
    @objc private func showSetupGuide() { actions.openSetupGuide() }
    @objc private func showAbout() { actions.openAbout() }
}
