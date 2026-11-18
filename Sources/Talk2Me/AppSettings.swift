import Combine
import Foundation
import Talk2MeCore

/// User preferences, stored in UserDefaults. The API key lives in the Keychain instead.
final class AppSettings: ObservableObject {
    private enum Key {
        static let backend = "cleanupBackend"
        static let model = "claudeModel"
        static let locale = "dictationLocale"
        static let timeout = "cleanupTimeoutSeconds"
        static let suppressFn = "suppressFnKey"
        static let holdKeyCode = "holdKeyCode"
        static let holdKeyModifiers = "holdKeyModifiers"
        static let handsFreeEnabled = "handsFreeEnabled"
        static let handsFreeKeyCode = "handsFreeKeyCode"
        static let handsFreeKeyModifiers = "handsFreeKeyModifiers"
        static let claudePath = "claudeCodePath"
        static let extraInstructions = "extraInstructions"
        static let dictionary = "dictionary"
        static let snippets = "snippets"
        static let onboarded = "hasOpenedSettings"
        static let orchestrateEnabled = "orchestrateEnabled"
        static let orchestrateKeyCode = "orchestrateKeyCode"
        static let orchestrateKeyModifiers = "orchestrateKeyModifiers"
        static let orchestrateRoot = "orchestrateRoot"
        static let promptBankEnabled = "promptBankEnabled"
        static let promptKeyCodes = "promptKeyCodes"
        static let promptKeyModifiers = "promptKeyModifiers"
        static let promptSlots = "promptSlots"
    }

    private let defaults: UserDefaults

    @Published var backend: CleanupBackendKind { didSet { defaults.set(backend.rawValue, forKey: Key.backend) } }
    @Published var model: ClaudeModel { didSet { defaults.set(model.rawValue, forKey: Key.model) } }
    @Published var localeID: String { didSet { defaults.set(localeID, forKey: Key.locale) } }
    @Published var timeoutSeconds: Double { didSet { defaults.set(timeoutSeconds, forKey: Key.timeout) } }
    @Published var suppressFnKey: Bool { didSet { defaults.set(suppressFnKey, forKey: Key.suppressFn) } }
    /// The key held to dictate.
    @Published var holdKey: ShortcutKey {
        didSet {
            defaults.set(Int(holdKey.keyCode), forKey: Key.holdKeyCode)
            defaults.set(Int(bitPattern: UInt(holdKey.modifiers)), forKey: Key.holdKeyModifiers)
        }
    }
    @Published var handsFreeEnabled: Bool { didSet { defaults.set(handsFreeEnabled, forKey: Key.handsFreeEnabled) } }
    /// The key double-tapped to start hands-free mode. Usually the same as the hold key.
    @Published var handsFreeKey: ShortcutKey {
        didSet {
            defaults.set(Int(handsFreeKey.keyCode), forKey: Key.handsFreeKeyCode)
            defaults.set(Int(bitPattern: UInt(handsFreeKey.modifiers)), forKey: Key.handsFreeKeyModifiers)
        }
    }
    @Published var orchestrateEnabled: Bool { didSet { defaults.set(orchestrateEnabled, forKey: Key.orchestrateEnabled) } }
    /// The key held to talk to the orchestrator instead of the focused app.
    @Published var orchestrateKey: ShortcutKey {
        didSet {
            defaults.set(Int(orchestrateKey.keyCode), forKey: Key.orchestrateKeyCode)
            defaults.set(Int(bitPattern: UInt(orchestrateKey.modifiers)), forKey: Key.orchestrateKeyModifiers)
        }
    }
    /// The folder the orchestrator session starts in.
    @Published var orchestrateRoot: String { didSet { defaults.set(orchestrateRoot, forKey: Key.orchestrateRoot) } }

    @Published var promptBankEnabled: Bool { didSet { defaults.set(promptBankEnabled, forKey: Key.promptBankEnabled) } }
    /// Four optional slot keys. Stored as JSON `[Int]` with -1 for unbound.
    @Published var promptKeys: [ShortcutKey?] {
        didSet {
            let codes = promptKeys.map { $0.map { Int($0.keyCode) } ?? -1 }
            defaults.set(try? JSONEncoder().encode(codes), forKey: Key.promptKeyCodes)
            let mods = promptKeys.map { $0.map { Int(bitPattern: UInt($0.modifiers)) } ?? 0 }
            defaults.set(try? JSONEncoder().encode(mods), forKey: Key.promptKeyModifiers)
        }
    }
    /// Four saved prompt texts. Stored as JSON.
    @Published var promptSlots: [PromptSlot] {
        didSet { defaults.set(try? JSONEncoder().encode(promptSlots), forKey: Key.promptSlots) }
    }

    var shortcutBindings: [ShortcutKey: ShortcutRoles] {
        ShortcutBindings.make(
            hold: holdKey,
            handsFree: handsFreeEnabled ? handsFreeKey : nil,
            orchestrate: orchestrateEnabled ? orchestrateKey : nil,
            prompts: promptBankEnabled ? promptKeys : []
        )
    }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: Key.claudePath) } }
    @Published var extraInstructions: String { didSet { defaults.set(extraInstructions, forKey: Key.extraInstructions) } }
    /// Stored as JSON, since UserDefaults can't hold custom types.
    @Published var dictionary: [DictionaryEntry] {
        didSet { defaults.set(try? JSONEncoder().encode(dictionary), forKey: Key.dictionary) }
    }

    @Published var snippets: [Snippet] {
        didSet { defaults.set(try? JSONEncoder().encode(snippets), forKey: Key.snippets) }
    }

    /// Words the recognizer should expect: dictionary words and snippet triggers.
    var recognizerHints: [String] {
        PersonalDictionary.recognizerHints(dictionary) + Snippets.recognizerHints(snippets)
    }

    /// The cleanup prompt with everything the user has set.
    var cleanupInstructions: String {
        CleanupPrompt.system(extraInstructions: extraInstructions, dictionary: dictionary)
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.onboarded) }
        set { defaults.set(newValue, forKey: Key.onboarded) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        backend = defaults.string(forKey: Key.backend).flatMap(CleanupBackendKind.init(rawValue:)) ?? .claudeCode
        model = defaults.string(forKey: Key.model).flatMap(ClaudeModel.init(rawValue:)) ?? .opus
        localeID = defaults.string(forKey: Key.locale) ?? Locale.current.identifier
        timeoutSeconds = defaults.object(forKey: Key.timeout) as? Double ?? 15
        suppressFnKey = defaults.object(forKey: Key.suppressFn) as? Bool ?? true
        func storedKey(_ codeKey: String, modKey: String) -> ShortcutKey? {
            guard let code = defaults.object(forKey: codeKey) as? Int,
                  ShortcutKey.isAllowed(keyCode: Int64(code)) else { return nil }
            // Legacy entries have no modifier field stored; default to 0 (unchanged behavior).
            let mods = UInt64(defaults.object(forKey: modKey) as? Int ?? 0)
            return ShortcutKey(keyCode: Int64(code), modifiers: mods)
        }
        holdKey = storedKey(Key.holdKeyCode, modKey: Key.holdKeyModifiers) ?? .fn
        handsFreeEnabled = defaults.object(forKey: Key.handsFreeEnabled) as? Bool ?? true
        handsFreeKey = storedKey(Key.handsFreeKeyCode, modKey: Key.handsFreeKeyModifiers) ?? .fn
        orchestrateEnabled = defaults.object(forKey: Key.orchestrateEnabled) as? Bool ?? false
        orchestrateKey = storedKey(Key.orchestrateKeyCode, modKey: Key.orchestrateKeyModifiers) ?? .leftOption
        orchestrateRoot = defaults.string(forKey: Key.orchestrateRoot) ?? NSHomeDirectory()
        promptBankEnabled = defaults.object(forKey: Key.promptBankEnabled) as? Bool ?? false
        // Decode stored codes (-1 = unbound), normalize to exactly 4 entries.
        let loadedCodes: [Int] = defaults.data(forKey: Key.promptKeyCodes)
            .flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
        // Modifier fields default to 0 when absent (legacy users).
        let loadedMods: [Int] = defaults.data(forKey: Key.promptKeyModifiers)
            .flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
        let normalizedKeys: [ShortcutKey?] = (0..<4).map { i in
            guard i < loadedCodes.count else { return nil }
            let code = loadedCodes[i]
            guard code >= 0, ShortcutKey.isAllowed(keyCode: Int64(code)) else { return nil }
            let mods = UInt64(i < loadedMods.count ? loadedMods[i] : 0)
            return ShortcutKey(keyCode: Int64(code), modifiers: mods)
        }
        promptKeys = normalizedKeys
        let loadedSlots: [PromptSlot] = defaults.data(forKey: Key.promptSlots)
            .flatMap { try? JSONDecoder().decode([PromptSlot].self, from: $0) } ?? []
        promptSlots = (0..<4).map { i in i < loadedSlots.count ? loadedSlots[i] : PromptSlot() }
        claudePath = defaults.string(forKey: Key.claudePath) ?? ""
        extraInstructions = defaults.string(forKey: Key.extraInstructions) ?? ""
        dictionary = defaults.data(forKey: Key.dictionary)
            .flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) } ?? []
        snippets = defaults.data(forKey: Key.snippets)
            .flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }
}
