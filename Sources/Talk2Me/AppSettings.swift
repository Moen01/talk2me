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
        static let claudePath = "claudeCodePath"
        static let extraInstructions = "extraInstructions"
        static let onboarded = "hasOpenedSettings"
    }

    private let defaults: UserDefaults

    @Published var backend: CleanupBackendKind { didSet { defaults.set(backend.rawValue, forKey: Key.backend) } }
    @Published var model: ClaudeModel { didSet { defaults.set(model.rawValue, forKey: Key.model) } }
    @Published var localeID: String { didSet { defaults.set(localeID, forKey: Key.locale) } }
    @Published var timeoutSeconds: Double { didSet { defaults.set(timeoutSeconds, forKey: Key.timeout) } }
    @Published var suppressFnKey: Bool { didSet { defaults.set(suppressFnKey, forKey: Key.suppressFn) } }
    @Published var claudePath: String { didSet { defaults.set(claudePath, forKey: Key.claudePath) } }
    @Published var extraInstructions: String { didSet { defaults.set(extraInstructions, forKey: Key.extraInstructions) } }

    var hasOpenedSettings: Bool {
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
        claudePath = defaults.string(forKey: Key.claudePath) ?? ""
        extraInstructions = defaults.string(forKey: Key.extraInstructions) ?? ""
    }
}
