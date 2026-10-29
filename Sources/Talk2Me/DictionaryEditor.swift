import SwiftUI
import Talk2MeCore

/// The Dictionary settings page: a two-column table of what the user says and what gets written.
struct DictionaryEditor: View {
    @Binding var entries: [DictionaryEntry]
    @FocusState private var focused: DictionaryEntry.ID?

    var body: some View {
        Section {
            if entries.isEmpty {
                Text("No words yet.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Speech word").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Dictionary").frame(maxWidth: .infinity, alignment: .leading)
                    // Lines the headers up with the text fields, past the delete button.
                    Color.clear.frame(width: 20)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach($entries) { $entry in
                    HStack {
                        TextField("Speech word", text: $entry.spoken, prompt: Text("PR, PRs"))
                            .focused($focused, equals: entry.id)
                        TextField("Dictionary", text: $entry.written, prompt: Text("Pull Request"))
                        Button {
                            entries.removeAll { $0.id == entry.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 20)
                        .help("Delete this word")
                    }
                    .labelsHidden()
                }
            }
            Button("Add Word", systemImage: "plus") {
                let entry = DictionaryEntry(spoken: "", written: "")
                entries.append(entry)
                focused = entry.id
            }
        } footer: {
            Text("When you say a speech word, Talk2Me writes the dictionary word instead. Separate more than one speech word with commas. The speech recognizer and Claude also learn these words, so they get them right more often.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
