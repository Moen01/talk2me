import Foundation
import Testing
@testable import Talk2MeCore

struct TerminalScriptTests {
    @Test func escapesQuotesBackslashesAndNewlines() {
        #expect(TerminalScript.escape(#"say "hi" \ bye"#) == #"say \"hi\" \\ bye"#)
        #expect(TerminalScript.escape("a\nb") == #"a\nb"#)
    }

    @Test func sendTargetsTheWindow() {
        let s = TerminalScript.send(#"open "x""#, toWindowID: 7)
        #expect(s.contains(#"do script "open \"x\"" in window id 7"#))
        #expect(s.contains(#"tell application "Terminal""#))
    }

    @Test func openWindowCreatesNewWindow() {
        let s = TerminalScript.openWindow(command: "ls")
        #expect(s.contains("do script"))
    }

    @Test func focusWindowSetsFrontmost() {
        let s = TerminalScript.focusWindow(id: 5)
        #expect(s.contains("set frontmost"))
    }

    @Test func windowExistsChecksExistence() {
        let s = TerminalScript.windowExists(id: 3)
        #expect(s.contains("exists window id"))
    }

    @Test func ttyOfWindowReturnsPath() {
        let s = TerminalScript.ttyOfWindow(id: 2)
        #expect(s.contains("tty of selected tab of window id"))
    }
}
