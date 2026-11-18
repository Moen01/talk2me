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
    /// Two-phase capture state: chord modifier bits held so far, and the first modifier's key code,
    /// so an all-released sequence with no base key still yields a modifier-only key (today's result).
    private var captureMask: UInt64 = 0
    private var captureFirstModifier: Int64?

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
        captureMask = 0
        captureFirstModifier = nil
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
            // A released modifier can break a held chord even if that modifier is not itself bound.
            // Pass code -1 so only the modifier condition in releasedBy can fire, never a base-key match.
            for (key, roles) in downBindings() where key.isChord
                && key.releasedBy(code: -1, flags: event.flags.rawValue) {
                setDown(key, roles, false)
            }
            guard let (key, roles) = binding(for: code, modifier: true) else { return pass }
            setDown(key, roles, key.isDown(flags: event.flags.rawValue))
            // Only Fn is hidden: other modifiers keep working normally in other apps.
            return key.isFn && suppressFnKey ? nil : pass

        case .keyDown:
            if let (key, roles) = bestKeyDownMatch(code: code, flags: event.flags.rawValue) {
                if key.isChord {
                    // A chord is ours: swallow it, and (unless it is an autorepeat) go down.
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { setDown(key, roles, true) }
                    return nil
                }
                // Plain key (modifiers == 0): keep the old passthrough rule.
                // With Command, Control or Option held it is someone else's shortcut, unless we already hold it.
                let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
                if !downKeys.contains(key), !event.flags.isDisjoint(with: shortcutFlags) { return pass }
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { setDown(key, roles, true) }
                return nil
            }
            if wantsKeyEvents(), onKeyDown?(code) == true { return nil }
            return pass

        case .keyUp:
            var swallow = false
            // Lift every down key this keyUp breaks (base-key release or a dropped modifier).
            for (key, roles) in downBindings() where key.releasedBy(code: code, flags: event.flags.rawValue) {
                // Only swallow when this is the chord's / key's own base keyUp, not a modifier side effect.
                if code == key.keyCode { swallow = true }
                setDown(key, roles, false)
            }
            return swallow ? nil : pass

        default:
            return pass
        }
    }

    private func binding(for code: Int64, modifier: Bool) -> (ShortcutKey, ShortcutRoles)? {
        bindings.first { key, _ in key.isModifier == modifier && key.matches(code) }.map { ($0.key, $0.value) }
    }

    /// The non-modifier binding (chord or plain key) that a keyDown activates, preferring the most
    /// specific one — the largest modifier mask — so ⌃⌥1 wins over a plain "1".
    private func bestKeyDownMatch(code: Int64, flags: UInt64) -> (ShortcutKey, ShortcutRoles)? {
        bindings
            .filter { key, _ in !key.isModifier && key.matchesChord(code: code, flags: flags) }
            .max { a, b in a.key.modifiers < b.key.modifiers }
            .map { ($0.key, $0.value) }
    }

    /// The currently-down keys paired with their roles, for release handling.
    private func downBindings() -> [(ShortcutKey, ShortcutRoles)] {
        downKeys.map { ($0, bindings[$0] ?? []) }
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
            let flags = event.flags.rawValue
            // Fn is never part of a chord: on its press, complete with the plain Fn key as today.
            if key.isFn, key.isDown(flags: flags) {
                finishCapture(.fn)
                return nil
            }
            // Other modifier presses accumulate a chord mask; remember the first one for the
            // all-released fallback (a modifier-only key, today's result, delivered on release).
            // The device-independent chord bits live in the event flags, so read them from there.
            if key.isModifier, key.isDown(flags: flags) {
                let chordBits = flags & ShortcutKey.chordModifierMask
                if chordBits != 0 {
                    if captureFirstModifier == nil { captureFirstModifier = code }
                    captureMask |= chordBits
                    return nil
                }
            }
            // A modifier release while a mask is pending: if every held chord modifier is now gone,
            // the user never pressed a base key — complete with the modifier-only key they started with.
            if captureMask != 0, (flags & captureMask) == 0 {
                let first = captureFirstModifier
                finishCapture(first.map { ShortcutKey(keyCode: $0) })
                return nil
            }
            // Caps Lock and other flag noise pass through.
            return Unmanaged.passUnretained(event)
        case .keyDown:
            if code == ShortcutKey.escapeKeyCode {
                finishCapture(nil)
            } else if ShortcutKey.isAllowed(keyCode: code) {
                // Read live flags from this keyDown event: captureMask only tracks modifiers that
                // arrived as flagsChanged events, so it misses modifiers already held when capture
                // started, and sticks with ones released before the base key.
                let mask = event.flags.rawValue & ShortcutKey.chordModifierMask
                finishCapture(ShortcutKey(keyCode: code, modifiers: mask))
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
