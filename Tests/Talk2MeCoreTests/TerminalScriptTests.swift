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
        // set-diff form: snapshot prevIDs, diff nextIDs, capture in newID
        #expect(s.contains("set prevIDs to (get id of windows)"))
        #expect(s.contains(#"do script "ls""#))
        #expect(s.contains("set nextIDs to (get id of windows)"))
        #expect(s.contains("repeat with w in nextIDs"))
        #expect(s.contains("prevIDs does not contain (w as integer)"))
        #expect(s.contains("activate"))
        // last-resort fallback
        #expect(s.contains("id of window 1"))
    }

    @Test func openWindowEscapesCommand() {
        let s = TerminalScript.openWindow(command: #"echo "hi""#)
        #expect(s.contains(#"do script "echo \"hi\"""#))
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
