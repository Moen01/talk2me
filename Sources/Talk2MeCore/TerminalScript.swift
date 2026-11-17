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
    /// `do script` with no `in` target always opens a NEW window, and that window is frontmost
    /// (`window 1`) the instant the command returns — so we read its id there. The more direct
    /// `id of window of newTab` reference is broken on macOS 26 (it raises -1728, "Can't get window
    /// of tab 1"), so we cannot use the tab the command returns.
    public static func openWindow(command: String) -> String {
        let escaped = escape(command)
        return """
        tell application "Terminal"
            do script "\(escaped)"
            activate
            (get id of window 1)
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
