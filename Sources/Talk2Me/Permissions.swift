import AppKit
import AVFAudio
import ApplicationServices

/// The two permissions the app needs, and shortcuts to the right System Settings panes.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Permissions change in System Settings, outside the app, so views that show them poll on
    /// this one shared timer (a `Timer.publish` written in `body` would be rebuilt on every redraw).
    static let ticks = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Shows the system prompt that sends the user to Accessibility settings.
    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var microphoneStatus: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    static func requestMicrophone() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// What every "Allow Accessibility" button does. Builds are ad-hoc signed, so each new build has
    /// a new signature, and the switch left on for an older build no longer counts while it still
    /// looks on. Removing Talk2Me's entry first lets macOS ask again for this build.
    static func requestAccessibility() {
        if let id = Bundle.main.bundleIdentifier {
            let reset = Process()
            reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            reset.arguments = ["reset", "Accessibility", id]
            try? reset.run()
            reset.waitUntilExit()
        }
        promptForAccessibility()
        openAccessibilitySettings()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
