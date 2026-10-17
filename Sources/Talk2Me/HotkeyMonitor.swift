import AppKit
import Carbon.HIToolbox

/// Watches the keyboard system-wide for the Fn (globe) key with a Core Graphics event tap.
///
/// The tap runs on the main run loop, so every callback arrives on the main thread.
/// An active tap that can swallow keys needs the Accessibility permission.
final class HotkeyMonitor {
    /// Called with `true` when Fn goes down and `false` when it comes up.
    var onFnChange: ((Bool) -> Void)?
    /// Called for other key presses while `wantsKeyEvents` is true; return true to swallow the key.
    var onKeyDown: ((Int64) -> Bool)?
    var wantsKeyEvents: () -> Bool = { false }
    /// Hide Fn from other apps so it doesn't also open the emoji picker or Apple Dictation.
    var suppressFnKey = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fnIsDown = false

    var isRunning: Bool { tap != nil }

    /// Returns false when macOS refuses the tap, usually because Accessibility access is missing.
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
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
        fnIsDown = false
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap that answers too slowly; turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // 63 is Fn on Mac keyboards; 179 is the globe key on some newer ones.
            guard keyCode == Int64(kVK_Function) || keyCode == 179 else {
                return Unmanaged.passUnretained(event)
            }
            let down = event.flags.contains(.maskSecondaryFn)
            if down != fnIsDown {
                fnIsDown = down
                onFnChange?(down)
            }
            return suppressFnKey ? nil : Unmanaged.passUnretained(event)

        case .keyDown:
            if wantsKeyEvents(), onKeyDown?(event.getIntegerValueField(.keyboardEventKeycode)) == true {
                return nil
            }
            return Unmanaged.passUnretained(event)

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
