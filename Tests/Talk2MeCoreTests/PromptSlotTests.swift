import Foundation
import Testing
@testable import Talk2MeCore

struct PromptSlotTests {
    @Test func wordCountSplitsOnWhitespaceAndNewlines() {
        let slot = PromptSlot(text: "hello world\nagain")
        #expect(slot.wordCount == 3)
    }

    @Test func emptyTextHasZeroWordCount() {
        let slot = PromptSlot(text: "")
        #expect(slot.wordCount == 0)
    }

    @Test func consecutiveWhitespaceDoesNotInflateWordCount() {
        let slot = PromptSlot(text: "a  b\n\nc")
        #expect(slot.wordCount == 3)
    }

    @Test func isEmptyOnlyForEmptyText() {
        let emptySlot = PromptSlot(text: "")
        #expect(emptySlot.isEmpty == true)

        let nonEmptySlot = PromptSlot(text: " ")
        #expect(nonEmptySlot.isEmpty == false)
    }

    @Test func codableRoundTrip() throws {
        let original = PromptSlot(text: "test text", savedAt: Date(timeIntervalSince1970: 1000))
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(PromptSlot.self, from: data)

        #expect(decoded.text == original.text)
        #expect(decoded.savedAt == original.savedAt)
    }
}
