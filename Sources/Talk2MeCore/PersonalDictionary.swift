import Foundation

/// One row of the user's dictionary: what they say, and how it must be written.
public struct DictionaryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// One or more spoken forms, separated by commas ("PRs, PR's").
    public var spoken: String
    public var written: String

    public init(id: UUID = UUID(), spoken: String, written: String) {
        self.id = id
        self.spoken = spoken
        self.written = written
    }

    public var spokenForms: [String] {
        spoken.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var trimmedWritten: String { written.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Rows still being typed (an empty column) are ignored everywhere.
    public var isComplete: Bool { !spokenForms.isEmpty && !trimmedWritten.isEmpty }
}

/// Applies the user's dictionary in the three places a word can go wrong: the recognizer,
/// the raw transcript and Claude's cleanup.
public enum PersonalDictionary {
    /// Words the on-device recognizer should expect to hear.
    public static func recognizerHints(_ entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()
        return entries.filter(\.isComplete).map(\.trimmedWritten).filter { seen.insert($0).inserted }
    }

    /// Replaces each spoken form with its written form. Whole words only, any letter case.
    /// One pass over the text, so a written form is never replaced again by another row.
    public static func apply(_ entries: [DictionaryEntry], to text: String) -> String {
        var replacements: [String: String] = [:]
        for entry in entries where entry.isComplete {
            for form in entry.spokenForms where replacements[form.lowercased()] == nil {
                replacements[form.lowercased()] = entry.trimmedWritten
            }
        }
        guard !replacements.isEmpty else { return text }

        // Longest first, so "PR's" wins over "PR" at the same place.
        let alternatives = replacements.keys
            .sorted { $0.count > $1.count }
            .map { form in
                form.split(whereSeparator: \.isWhitespace)
                    .map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s+")
            }
        // \b treats an apostrophe as a word edge on one side only, so letters and digits are checked instead.
        let pattern = "(?<![\\p{L}\\p{N}])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let found = source.substring(with: match.range)
            let key = found.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += replacements[key] ?? found
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }

    /// The part of the cleanup prompt that stops Claude from "correcting" dictionary words.
    public static func promptSection(_ entries: [DictionaryEntry]) -> String? {
        let complete = entries.filter(\.isComplete)
        guard !complete.isEmpty else { return nil }
        let lines = complete.map { entry in
            let spoken = entry.spokenForms.map { "\"\($0)\"" }.joined(separator: " or ")
            return "- \(spoken) → \"\(entry.trimmedWritten)\""
        }
        return """
        The user's dictionary. When the speaker says a word on the left, write it exactly as on the right, \
        with that spelling and capitalisation. Keep these words as they are when they already appear in the transcript:
        """ + "\n" + lines.joined(separator: "\n")
    }
}
