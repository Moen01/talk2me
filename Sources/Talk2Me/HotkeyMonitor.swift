import AppKit
import Talk2MeCore

/// Watches the keyboard system-wide for the user's shortcut keys with a Core Graphics event tap,
/// and can capture the next key press when the user records a new shortcut.
///
/// The tap runs on the main run loop, so every callback arrives on the main thread.
/// An active tap that can swallow keys needs the Accessibility permission.
final class HotkeyMonitor {
    /// Called when a shortcut key goes down (`true`) or up (`false`), with what that key does.
    var onShortcut: ((ShortcutRoles, Bool) -> Void)?
    /// Called for other key presses while `wantsKeyEvents` is true; return true to swallow the key.
    var onKeyDown: ((Int64) -> Bool)?
    var wantsKeyEvents: () -> Bool = { false }
    /// Hide Fn from other apps so it doesn't also open the emoji picker or Apple Dictation.
    var suppressFnKey = true

    /// The keys to watch and what each one does.
    var bindings: [ShortcutKey: ShortcutRoles] = ShortcutBindings.make(hold: .fn, handsFree: .fn) {
        didSet {
            guard bindings != oldValue else { return }
            // Never leave a recording running on a key that is no longer watched.
            for key in downKeys { onShortcut?(oldValue[key] ?? [], false) }
            downKeys = []
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var downKeys: Set<ShortcutKey> = []
    private var capture: ((ShortcutKey?) -> Void)?

    var isRunning: Bool { tap != nil }

    /// Returns false when macOS refuses the tap, usually because Accessibility access is missing.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        downKeys = []
    }

    /// The next key press becomes the result instead of reaching any app.
    /// Escape cancels and reports nil; Enter and Caps Lock are not accepted.
    func captureNextKey(_ completion: @escaping (ShortcutKey?) -> Void) {
        capture?(nil)
        capture = completion
    }

    func cancelCapture() {
        finishCapture(nil)
    }

    private func finishCapture(_ key: ShortcutKey?) {
        let completion = capture
        capture = nil
        completion?(key)
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS disables a tap that answers too slowly; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if capture != nil {
            return handleCapture(type, event, code)
        }

        switch type {
        case .flagsChanged:
            guard let (key, roles) = binding(for: code, modifier: true) else { return pass }
            setDown(key, roles, key.isDown(flags: event.flags.rawValue))
            // Only Fn is hidden: other modifiers keep working normally in other apps.
            return key.isFn && suppressFnKey ? nil : pass

        case .keyDown:
            if let (key, roles) = binding(for: code, modifier: false) {
                // With Command, Control or Option held it is someone else's shortcut, unless we already hold it.
                let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
                if !downKeys.contains(key), !event.flags.isDisjoint(with: shortcutFlags) { return pass }
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { setDown(key, roles, true) }
                return nil
            }
            if wantsKeyEvents(), onKeyDown?(code) == true { return nil }
            return pass

        case .keyUp:
            if let (key, roles) = binding(for: code, modifier: false), downKeys.contains(key) {
                setDown(key, roles, false)
                return nil
            }
            return pass

        default:
            return pass
        }
    }

    private func binding(for code: Int64, modifier: Bool) -> (ShortcutKey, ShortcutRoles)? {
        bindings.first { key, _ in key.isModifier == modifier && key.matches(code) }.map { ($0.key, $0.value) }
    }

    private func setDown(_ key: ShortcutKey, _ roles: ShortcutRoles, _ down: Bool) {
        guard down != downKeys.contains(key) else { return }
        if down { downKeys.insert(key) } else { downKeys.remove(key) }
        onShortcut?(roles, down)
    }

    private func handleCapture(_ type: CGEventType, _ event: CGEvent, _ code: Int64) -> Unmanaged<CGEvent>? {
        switch type {
        case .flagsChanged:
            let key = ShortcutKey(keyCode: code)
            // Take a modifier on its press; let releases and Caps Lock through.
            guard key.isModifier, key.isDown(flags: event.flags.rawValue) else {
                return Unmanaged.passUnretained(event)
            }
            finishCapture(key.isFn ? .fn : key)
            return nil
        case .keyDown:
            if code == ShortcutKey.escapeKeyCode {
                finishCapture(nil)
            } else if ShortcutKey.isAllowed(keyCode: code) {
                finishCapture(ShortcutKey(keyCode: code))
            }
            return nil
        case .keyUp:
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
