import Foundation
import Testing
@testable import Talk2MeCore

struct SnippetsTests {
    private let jira = Snippet(trigger: "Open Jira", kind: .openLink, value: "jira.catacloud.no")
    private let standup = Snippet(trigger: "start standup", kind: .runShortcut, value: "Standup")

    @Test func matchesTheWholeTranscriptIgnoringCaseAndPunctuation() {
        #expect(Snippets.match([jira, standup], transcript: "Open Jira.") == jira)
        #expect(Snippets.match([jira, standup], transcript: "  start,  standup! ") == standup)
    }

    @Test func neverFiresInsideALongerSentence() {
        #expect(Snippets.match([jira], transcript: "Can you open Jira for me") == nil)
    }

    @Test func skipsSnippetsStillBeingTyped() {
        let empty = Snippet(trigger: "open jira", kind: .openLink, value: " ")
        #expect(Snippets.match([empty, jira], transcript: "open jira") == jira)
        #expect(Snippets.match([Snippet(trigger: "...", kind: .insertText, value: "x")], transcript: "") == nil)
    }

    @Test func bareAddressesGetHTTPS() {
        #expect(jira.url == URL(string: "https://jira.catacloud.no"))
        #expect(Snippet(trigger: "x", kind: .openLink, value: "http://localhost:3000").url == URL(string: "http://localhost:3000"))
        #expect(Snippet(trigger: "x", kind: .openLink, value: "mailto:a@b.no").url == URL(string: "mailto:a@b.no"))
        #expect(Snippet(trigger: "x", kind: .openLink, value: "not a link").url == nil)
    }

    @Test func hintsAreTheTriggers() {
        #expect(Snippets.recognizerHints([jira, Snippet(trigger: "x", kind: .insertText, value: "")]) == ["Open Jira"])
    }
}
