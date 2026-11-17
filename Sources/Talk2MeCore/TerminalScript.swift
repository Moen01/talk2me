/// Builds AppleScript source text for controlling Terminal.app.
///
/// These functions are pure string builders that return AppleScript commands
/// as Swift strings. The escaping handles the Terminal AppleScript string literal
/// rules: backslash and quote are escaped, newlines become `\n`, carriage returns
/// are dropped.
public enum TerminalScript {
    /// Escapes text for embedding in an AppleScript string literal.
    ///
    /// Inside AppleScript string literals, backslash and double-quote are escaped with backslash,
    /// newlines become the two-character sequence `\n`, and carriage returns are dropped.
    public static func escape(_ text: String) -> String {
        var result = ""
        for char in text {
            switch char {
            case "\\":
                result.append("\\\\")
            case "\"":
                result.append("\\\"")
            case "\n":
                result.append("\\n")
            case "\r":
                // Carriage returns are dropped
                break
            default:
                result.append(char)
            }
        }
        return result
    }

    /// Builds an AppleScript that opens a new Terminal window with a command.
    ///
    /// The script activates Terminal and returns the new window's ID so osascript can print it.
    ///
    /// We use a set-diff approach: snapshot `id of windows` before the `do script`, then find the
    /// one new id that appeared afterward. This is race-free even when other windows exist. We
    /// avoid both the macOS 26 `-1728` bug (`id of window of newTab`) and the `window 1` race
    /// (another window could become frontmost between our `do script` and our id read).
    ///
    /// Note: `before`/`after` are AppleScript reserved words (prepositions), so we use
    /// `prevIDs`/`nextIDs`. We also cannot use a bare `return` inside a tell-block; instead we
    /// capture the result in `newID` and make it the final expression of the script.
    /// As a last-resort fallback `id of window 1` is returned when the diff yields nothing.
    public static func openWindow(command: String) -> String {
        let escaped = escape(command)
        return """
        tell application "Terminal"
            set prevIDs to (get id of windows)
            do script "\(escaped)"
            activate
            set nextIDs to (get id of windows)
            set newID to -1
            repeat with w in nextIDs
                if prevIDs does not contain (w as integer) then
                    set newID to (w as integer)
                    exit repeat
                end if
            end repeat
            if newID is -1 then
                get id of window 1
            else
                newID
            end if
        end tell
        """
    }

    /// Builds an AppleScript that sends text to an existing Terminal window without opening a new one.
    public static func send(_ text: String, toWindowID: Int) -> String {
        let escaped = escape(text)
        return """
        tell application "Terminal"
            do script "\(escaped)" in window id \(toWindowID)
        end tell
        """
    }

    /// Builds an AppleScript that brings a Terminal window to the front.
    public static func focusWindow(id: Int) -> String {
        return """
        tell application "Terminal"
            set frontmost of window id \(id) to true
            activate
        end tell
        """
    }

    /// Builds an AppleScript that checks if a Terminal window exists.
    ///
    /// The script evaluates to `true` or `false`.
    public static func windowExists(id: Int) -> String {
        return """
        tell application "Terminal"
            exists window id \(id)
        end tell
        """
    }

    /// Builds an AppleScript that returns the tty path of a Terminal window's selected tab.
    public static func ttyOfWindow(id: Int) -> String {
        return """
        tell application "Terminal"
            tty of selected tab of window id \(id)
        end tell
        """
    }
}
