import AppKit

// Writing to a claude process that already exited must fail with an error, not kill the app.
signal(SIGPIPE, SIG_IGN)

// A menu-bar app: no Dock icon, no main window.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
