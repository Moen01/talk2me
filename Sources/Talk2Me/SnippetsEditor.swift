import SwiftUI
import Talk2MeCore

/// The Snippets settings page: phrases that open a link, run a shortcut or paste text.
struct SnippetsEditor: View {
    @Binding var snippets: [Snippet]
    @FocusState private var focused: Snippet.ID?

    var body: some View {
        Section {
            if snippets.isEmpty {
                Text("No snippets yet.").foregroundStyle(.secondary)
            }
            ForEach($snippets) { $snippet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("When I say", text: $snippet.trigger, prompt: Text("open jira"))
                            .focused($focused, equals: snippet.id)
                        Picker("Action", selection: $snippet.kind) {
                            ForEach(Snippet.Kind.allCases) { Text($0.title).tag($0) }
                        }
                        .fixedSize()
                        Button {
                            snippets.removeAll { $0.id == snippet.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this snippet")
                    }
                    if snippet.kind == .insertText {
                        TextField(snippet.kind.title, text: $snippet.value, prompt: Text(snippet.kind.placeholder), axis: .vertical)
                            .lineLimit(2...6)
                    } else {
                        TextField(snippet.kind.title, text: $snippet.value, prompt: Text(snippet.kind.placeholder))
                    }
                }
                .labelsHidden()
                .padding(.vertical, 2)
            }
            Button("Add Snippet", systemImage: "plus") {
                let snippet = Snippet(trigger: "", kind: .openLink, value: "")
                snippets.append(snippet)
                focused = snippet.id
            }
        } footer: {
            Text("Say only the phrase, then release the key: Talk2Me does the action instead of pasting. The phrase inside a longer sentence does nothing. \"Run shortcut\" runs a shortcut from the Shortcuts app by its name, which can also run a script.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private extension Snippet.Kind {
    var title: String {
        switch self {
        case .openLink: "Open link"
        case .runShortcut: "Run shortcut"
        case .insertText: "Paste text"
        }
    }

    var placeholder: String {
        switch self {
        case .openLink: "jira.catacloud.no"
        case .runShortcut: "Shortcut name"
        case .insertText: "Text to paste"
        }
    }
}
