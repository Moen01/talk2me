import AppKit
import Carbon.HIToolbox

/// Types text into the focused app by pasting it, then puts the user's clipboard back.
@MainActor
final class TextInserter {
    enum Outcome {
        case pasted
        case copiedOnly(String)
    }

    /// Clipboard managers that follow nspasteboard.org skip items marked transient.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Time for the target app to read the clipboard before it is restored.
    var restoreDelay: Duration = .milliseconds(500)

    func insert(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general
        if IsSecureEventInputEnabled() {
            copy(text, to: pasteboard)
            return .copiedOnly("A password field has secure input on, so the text was copied instead of pasted.")
        }
        guard AXIsProcessTrusted() else {
            copy(text, to: pasteboard)
            return .copiedOnly("Accessibility access is off, so the text was copied instead of pasted.")
        }

        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        postCommandV()
        try? await Task.sleep(for: restoreDelay)

        // Restore only if nobody copied something new in the meantime.
        if pasteboard.changeCount == ourChange {
            restore(saved, to: pasteboard)
        }
        return .pasted
    }

    private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { representations[type] = data }
            }
            return representations
        }
    }

    private func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = saved.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = KeyboardLayout.keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
