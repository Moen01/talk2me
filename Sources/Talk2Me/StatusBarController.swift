import AppKit

/// The menu-bar icon and its menu.
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: DictationController
    private let stateLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resultLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Grant Accessibility access…", action: #selector(openAccessibility), keyEquivalent: "")
    private let openSettings: () -> Void

    init(controller: DictationController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()

        let menu = NSMenu()
        stateLine.isEnabled = false
        resultLine.isEnabled = false
        accessibilityItem.target = self
        menu.addItem(stateLine)
        menu.addItem(resultLine)
        menu.addItem(.separator())
        menu.addItem(accessibilityItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Talk2Me", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        refresh()
    }

    func refresh() {
        let (symbol, state): (String, String) = switch controller.phase {
        case .idle: ("waveform", controller.readiness)
        case .recording where controller.isHandsFree: ("mic.fill", "Hands-free: tap Fn to finish, Esc to discard")
        case .recording: ("mic.fill", "Listening… release Fn to finish")
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

    @objc private func showSettings() {
        openSettings()
    }
}
