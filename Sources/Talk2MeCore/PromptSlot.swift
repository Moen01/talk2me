import Foundation

public struct PromptSlot: Codable, Equatable, Sendable {
    public var text: String
    public var savedAt: Date?

    public init(text: String = "", savedAt: Date? = nil) {
        self.text = text
        self.savedAt = savedAt
    }

    public var wordCount: Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: /\s/).count
    }

    public var isEmpty: Bool {
        text.isEmpty
    }
}
