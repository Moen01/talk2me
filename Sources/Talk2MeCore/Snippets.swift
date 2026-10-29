import Foundation

/// A voice command: when the whole dictation is the trigger phrase, Talk2Me does the action
/// instead of pasting the words.
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case openLink, runShortcut, insertText

        public var id: Self { self }
    }

    public var id: UUID
    public var trigger: String
    public var kind: Kind
    /// The link, the name of the shortcut in the Shortcuts app, or the text to paste.
    public var value: String

    public init(id: UUID = UUID(), trigger: String, kind: Kind, value: String) {
        self.id = id
        self.trigger = trigger
        self.kind = kind
        self.value = value
    }

    public var isComplete: Bool {
        !Snippets.normalize(trigger).isEmpty && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The link to open. A bare address such as "jira.catacloud.no" gets https:// in front.
    public var url: URL? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.contains("://") || text.hasPrefix("mailto:") { return URL(string: text) }
        return URL(string: "https://" + text)
    }
}

public enum Snippets {
    /// The snippet whose trigger is the whole transcript. A trigger inside a longer sentence never
    /// fires, so ordinary dictation can't run a command by accident.
    public static func match(_ snippets: [Snippet], transcript: String) -> Snippet? {
        let spoken = normalize(transcript)
        guard !spoken.isEmpty else { return nil }
        return snippets.first { $0.isComplete && normalize($0.trigger) == spoken }
    }

    /// Words the recognizer should expect, so a trigger is heard as typed.
    public static func recognizerHints(_ snippets: [Snippet]) -> [String] {
        snippets.filter(\.isComplete).map { $0.trigger.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Lower case, punctuation dropped, single spaces: the recognizer adds a full stop and
    /// capitals that the user did not type in the trigger.
    static func normalize(_ text: String) -> String {
        let kept = text.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " "
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
