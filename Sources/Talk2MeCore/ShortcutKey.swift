import Foundation

/// A key used as a dictation shortcut: a modifier on its own (Fn, Right Option, …) or a regular key (F13, §, …).
public struct ShortcutKey: Codable, Hashable, Sendable {
    public let keyCode: Int64

    public init(keyCode: Int64) {
        self.keyCode = keyCode
    }

    public static let fn = ShortcutKey(keyCode: 63)
    public static let rightOption = ShortcutKey(keyCode: 61)
    public static let rightCommand = ShortcutKey(keyCode: 54)
    public static let rightControl = ShortcutKey(keyCode: 62)
    public static let leftOption = ShortcutKey(keyCode: 58)
    public static let leftCommand = ShortcutKey(keyCode: 55)

    /// Offered as one-click choices in Settings.
    public static let presets: [ShortcutKey] = [.fn, .rightOption, .rightCommand, .rightControl, .leftOption, .leftCommand]

    public static let escapeKeyCode: Int64 = 53
    /// Return and keypad Enter finish hands-free mode.
    public static let enterKeyCodes: Set<Int64> = [36, 76]
    static let capsLockKeyCode: Int64 = 57
    /// The globe key on some newer Mac keyboards reports this code instead of Fn's 63.
    static let globeKeyCode: Int64 = 179

    /// Event-flag bits that say whether one specific modifier key is down. Left and right keys
    /// have separate device bits (NX_DEVICE*KEYMASK in IOLLEvent.h); Fn uses the secondary-Fn flag.
    static let modifierFlagMasks: [Int64: UInt64] = [
        63: 0x80_0000, 179: 0x80_0000, // Fn / globe
        55: 0x08, 54: 0x10, // left, right Command
        58: 0x20, 61: 0x40, // left, right Option
        59: 0x01, 62: 0x2000, // left, right Control
        56: 0x02, 60: 0x04, // left, right Shift
    ]

    /// Escape and Enter control hands-free mode, and Caps Lock toggles instead of holding,
    /// so none of them can be a shortcut.
    public static func isAllowed(keyCode: Int64) -> Bool {
        keyCode != escapeKeyCode && keyCode != capsLockKeyCode && !enterKeyCodes.contains(keyCode)
    }

    public var isModifier: Bool { Self.modifierFlagMasks[keyCode] != nil }
    public var isFn: Bool { keyCode == 63 || keyCode == Self.globeKeyCode }

    /// Whether a key event with this key code belongs to this shortcut key.
    public func matches(_ code: Int64) -> Bool {
        code == keyCode || (isFn && (code == 63 || code == Self.globeKeyCode))
    }

    /// For modifier keys: whether this key is down in a flags-changed event's flags.
    public func isDown(flags: UInt64) -> Bool {
        guard let mask = Self.modifierFlagMasks[keyCode] else { return false }
        return flags & mask != 0
    }

    /// A readable name for keys that don't type a character. Character keys are named
    /// from the current keyboard layout by the app.
    public var builtInName: String? {
        Self.names[keyCode]
    }

    static let names: [Int64: String] = [
        63: "Fn (globe)", 179: "Fn (globe)",
        55: "Left Command", 54: "Right Command",
        58: "Left Option", 61: "Right Option",
        59: "Left Control", 62: "Right Control",
        56: "Left Shift", 60: "Right Shift",
        49: "Space", 48: "Tab", 51: "Delete", 117: "Forward Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}

/// What pressing a shortcut key does. One key can do both (Fn by default).
public struct ShortcutRoles: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Hold to dictate.
    public static let hold = ShortcutRoles(rawValue: 1)
    /// Double-tap to start hands-free mode.
    public static let handsFree = ShortcutRoles(rawValue: 2)
    /// Open the Orchestrate sidebar.
    public static let orchestrate = ShortcutRoles(rawValue: 4)
    /// Capture to prompt slot 1.
    public static let promptSlot1 = ShortcutRoles(rawValue: 8)
    /// Capture to prompt slot 2.
    public static let promptSlot2 = ShortcutRoles(rawValue: 16)
    /// Capture to prompt slot 3.
    public static let promptSlot3 = ShortcutRoles(rawValue: 32)
    /// Capture to prompt slot 4.
    public static let promptSlot4 = ShortcutRoles(rawValue: 64)

    /// Return the prompt slot role for the given index (0–3).
    public static func promptSlot(_ index: Int) -> ShortcutRoles {
        switch index {
        case 0: return .promptSlot1
        case 1: return .promptSlot2
        case 2: return .promptSlot3
        case 3: return .promptSlot4
        default: return [] // index out of range → empty set, binds nothing
        }
    }

    /// The prompt slot index (0–3) if these roles include a prompt slot, nil otherwise.
    /// Uses contains(_:) so it still works when a slot is combined with other roles.
    public var promptSlotIndex: Int? {
        if contains(.promptSlot1) { return 0 }
        if contains(.promptSlot2) { return 1 }
        if contains(.promptSlot3) { return 2 }
        if contains(.promptSlot4) { return 3 }
        return nil
    }
}

/// Which keys to watch, and what each one does.
public enum ShortcutBindings {
    public static func make(hold: ShortcutKey, handsFree: ShortcutKey?, orchestrate: ShortcutKey? = nil, prompts: [ShortcutKey?] = []) -> [ShortcutKey: ShortcutRoles] {
        var bindings: [ShortcutKey: ShortcutRoles] = [:]

        // Add hold key
        bindings[hold] = .hold

        // Add hands-free key
        if let handsFree {
            if handsFree == hold {
                bindings[hold, default: []].insert(.handsFree)
            } else {
                bindings[handsFree, default: []].insert(.handsFree)
            }
        }

        // Add orchestrate key if different from both hold and hands-free
        if let orchestrate {
            if orchestrate != hold && orchestrate != handsFree {
                bindings[orchestrate] = .orchestrate
            }
        }

        // Add prompt keys, limiting to 4 entries, skipping those that collide with existing bindings
        var promptKeysAlreadyBound: Set<ShortcutKey> = []
        for (index, promptKey) in prompts.enumerated() {
            guard index < 4, let promptKey = promptKey else { continue }

            // Skip if already bound to a different role
            if bindings[promptKey] != nil || promptKeysAlreadyBound.contains(promptKey) {
                continue
            }

            bindings[promptKey] = .promptSlot(index)
            promptKeysAlreadyBound.insert(promptKey)
        }

        return bindings
    }
}
