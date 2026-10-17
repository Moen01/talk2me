import Carbon.HIToolbox
import CoreGraphics
import Talk2MeCore

/// Reads the current keyboard layout to translate between key codes and characters.
enum KeyboardLayout {
    /// The character a key types with no modifiers, e.g. "§" or "v".
    static func character(for keyCode: CGKeyCode) -> String? {
        withLayout { layout in translate(layout, keyCode) }
    }

    /// The key that types `character`, so Cmd+V works on layouts where V is not on the US position.
    static func keyCode(producing character: String) -> CGKeyCode? {
        withLayout { layout in
            (0..<128).map(CGKeyCode.init).first { translate(layout, $0) == character }
        }
    }

    /// What Settings and the menu call a shortcut key.
    static func name(of key: ShortcutKey) -> String {
        if let name = key.builtInName { return name }
        if let character = character(for: CGKeyCode(key.keyCode))?.trimmingCharacters(in: .whitespacesAndNewlines),
           !character.isEmpty {
            return "\"\(character.uppercased())\" key"
        }
        return "Key \(key.keyCode)"
    }

    private static func withLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T?) -> T? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            return body(layout)
        }
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ keyCode: CGKeyCode) -> String? {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
            layout, keyCode, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
