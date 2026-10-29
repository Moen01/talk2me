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
        static let handsFreeEnabled = "handsFreeEnabled"
        static let handsFreeKeyCode = "handsFreeKeyCode"
        static let claudePath = "claudeCodePath"
        static let extraInstructions = "extraInstructions"
        static let dictionary = "dictionary"
        static let snippets = "snippets"
        static let onboarded = "hasOpenedSettings"
    }

    private let defaults: UserDefaults

    @Published var backend: CleanupBackendKind { didSet { defaults.set(backend.rawValue, forKey: Key.backend) } }
    @Published var model: ClaudeModel { didSet { defaults.set(model.rawValue, forKey: Key.model) } }
    @Published var localeID: String { didSet { defaults.set(localeID, forKey: Key.locale) } }
    @Published var timeoutSeconds: Double { didSet { defaults.set(timeoutSeconds, forKey: Key.timeout) } }
    @Published var suppressFnKey: Bool { didSet { defaults.set(suppressFnKey, forKey: Key.suppressFn) } }
    /// The key held to dictate.
    @Published var holdKey: ShortcutKey { didSet { defaults.set(Int(holdKey.keyCode), forKey: Key.holdKeyCode) } }
    @Published var handsFreeEnabled: Bool { didSet { defaults.set(handsFreeEnabled, forKey: Key.handsFreeEnabled) } }
    /// The key double-tapped to start hands-free mode. Usually the same as the hold key.
    @Published var handsFreeKey: ShortcutKey { didSet { defaults.set(Int(handsFreeKey.keyCode), forKey: Key.handsFreeKeyCode) } }

    var shortcutBindings: [ShortcutKey: ShortcutRoles] {
        ShortcutBindings.make(hold: holdKey, handsFree: handsFreeEnabled ? handsFreeKey : nil)
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
        func storedKey(_ name: String) -> ShortcutKey? {
            guard let code = defaults.object(forKey: name) as? Int, ShortcutKey.isAllowed(keyCode: Int64(code)) else { return nil }
            return ShortcutKey(keyCode: Int64(code))
        }
        holdKey = storedKey(Key.holdKeyCode) ?? .fn
        handsFreeEnabled = defaults.object(forKey: Key.handsFreeEnabled) as? Bool ?? true
        handsFreeKey = storedKey(Key.handsFreeKeyCode) ?? .fn
        claudePath = defaults.string(forKey: Key.claudePath) ?? ""
        extraInstructions = defaults.string(forKey: Key.extraInstructions) ?? ""
        dictionary = defaults.data(forKey: Key.dictionary)
            .flatMap { try? JSONDecoder().decode([DictionaryEntry].self, from: $0) } ?? []
        snippets = defaults.data(forKey: Key.snippets)
            .flatMap { try? JSONDecoder().decode([Snippet].self, from: $0) } ?? []
    }
}
