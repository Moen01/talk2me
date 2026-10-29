import Testing
@testable import Talk2MeCore

struct PersonalDictionaryTests {
    private let entries = [
        DictionaryEntry(spoken: "PR", written: "Pull Request"),
        DictionaryEntry(spoken: "PRs, PR's", written: "pull requests"),
        DictionaryEntry(spoken: "arythma", written: "Artitma"),
        DictionaryEntry(spoken: "talk to me", written: "Talk2Me"),
    ]

    @Test func replacesWholeWordsInAnyCase() {
        #expect(PersonalDictionary.apply(entries, to: "open a pr for arythma") == "open a Pull Request for Artitma")
        #expect(PersonalDictionary.apply(entries, to: "Arythma, PR.") == "Artitma, Pull Request.")
    }

    @Test func leavesLongerWordsAlone() {
        #expect(PersonalDictionary.apply(entries, to: "press print") == "press print")
    }

    @Test func everySpokenFormOfARowIsReplaced() {
        #expect(PersonalDictionary.apply(entries, to: "two PRs and the PR's title") == "two pull requests and the pull requests title")
    }

    @Test func matchesSpokenPhrasesAcrossSpacing() {
        #expect(PersonalDictionary.apply(entries, to: "I use Talk  to me daily") == "I use Talk2Me daily")
    }

    @Test func doesNotReplaceInsideAWrittenForm() {
        let chained = [
            DictionaryEntry(spoken: "cc", written: "Catacloud API"),
            DictionaryEntry(spoken: "api", written: "A.P.I."),
        ]
        #expect(PersonalDictionary.apply(chained, to: "cc and api") == "Catacloud API and A.P.I.")
    }

    @Test func ignoresRowsStillBeingTyped() {
        let partial = [DictionaryEntry(spoken: "pr", written: " "), DictionaryEntry(spoken: " , ", written: "X")]
        #expect(PersonalDictionary.apply(partial, to: "a pr") == "a pr")
        #expect(PersonalDictionary.promptSection(partial) == nil)
        #expect(PersonalDictionary.recognizerHints(partial).isEmpty)
    }

    @Test func hintsAreTheWrittenWordsOnce() {
        let hints = PersonalDictionary.recognizerHints(entries + [DictionaryEntry(spoken: "artima", written: "Artitma")])
        #expect(hints == ["Pull Request", "pull requests", "Artitma", "Talk2Me"])
    }

    @Test func promptListsEveryRow() throws {
        let prompt = CleanupPrompt.system(extraInstructions: "Be brief", dictionary: entries)
        #expect(prompt.contains("- \"PRs\" or \"PR's\" → \"pull requests\""))
        #expect(prompt.contains("- \"arythma\" → \"Artitma\""))
        #expect(prompt.hasSuffix("Be brief"))
        #expect(CleanupPrompt.system(extraInstructions: nil, dictionary: []) == CleanupPrompt.base)
    }
}
