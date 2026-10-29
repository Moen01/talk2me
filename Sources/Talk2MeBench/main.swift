import AVFAudio
import Foundation
import Talk2MeCore

// talk2me-bench: time the cleanup backends and check on-device transcription from the terminal.
//
//   talk2me-bench cleanup [--backend claude-code|api] [--model opus|sonnet|haiku] [--runs N] [text]
//   talk2me-bench transcribe <audio-file> [--locale nb_NO]
//   talk2me-bench live <audio-file>|none [--paced] [--locale nb_NO] [--hints "Artitma,Talk2Me"]
//
// The API backend reads ANTHROPIC_API_KEY from the environment.

// Writing to a claude process that already exited must fail with an error, not end the run.
signal(SIGPIPE, SIG_IGN)

let usage = """
usage:
  talk2me-bench cleanup [--backend claude-code|api] [--model opus|sonnet|haiku] [--runs N] [text]
  talk2me-bench transcribe <audio-file> [--locale nb_NO]
  talk2me-bench live <audio-file>|none [--paced] [--locale nb_NO] [--hints "Artitma,Talk2Me"]
"""

let sampleTranscript = "um so I was thinking that we should uh move the meeting to thursday instead of you know wednesday because the the client can't make it new paragraph also can you send me the slides"

var arguments = Array(CommandLine.arguments.dropFirst())

@MainActor
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let command = arguments.first else { fail(usage) }
arguments.removeFirst()

switch command {
case "cleanup":
    let backendName = option("--backend") ?? "claude-code"
    let modelName = option("--model") ?? "opus"
    let runs = Int(option("--runs") ?? "1") ?? 1
    let text = arguments.isEmpty ? sampleTranscript : arguments.joined(separator: " ")

    guard let model = ClaudeModel.allCases.first(where: { $0.rawValue.contains(modelName) }) else {
        fail("unknown model \(modelName)")
    }
    let backend: any CleanupBackend
    switch backendName {
    case "claude-code":
        guard let path = ClaudeCodeBackend.locate() else { fail(CleanupError.claudeNotFound.localizedDescription) }
        backend = ClaudeCodeBackend(executable: path)
    case "api":
        backend = AnthropicMessagesBackend { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] }
    default:
        fail("unknown backend \(backendName)")
    }

    print("backend=\(backendName) model=\(model.rawValue) runs=\(runs)")
    print("input: \(text)")
    for run in 1...max(runs, 1) {
        let outcome = await CleanupRouter.run(
            transcript: text, backend: backend, model: model,
            instructions: CleanupPrompt.system(extraInstructions: nil), timeout: .seconds(60)
        )
        let seconds = Double(outcome.duration.components.seconds) + Double(outcome.duration.components.attoseconds) / 1e18
        print(String(format: "run %d: %.2f s cleaned=%@", run, seconds, outcome.cleaned ? "yes" : "no"))
        if let failure = outcome.failure { print("  failure: \(failure)") }
        print("  output: \(outcome.text)")
    }

case "transcribe":
    let localeID = option("--locale") ?? Locale.current.identifier
    guard let path = arguments.first else { fail(usage) }
    do {
        let start = ContinuousClock.now
        let text = try await OnDeviceDictation.transcribeFile(URL(fileURLWithPath: path), locale: Locale(identifier: localeID))
        print("locale=\(localeID) elapsed=\(ContinuousClock.now - start)")
        print(text)
    } catch {
        fail("transcription failed: \(error.localizedDescription)")
    }

case "live":
    // Feeds a file through DictationSession in microphone-sized buffers, like the app does while recording.
    let localeID = option("--locale") ?? Locale.current.identifier
    // Real time, like a microphone: the analyzer starts while audio is still arriving.
    let paced = arguments.contains("--paced")
    arguments.removeAll { $0 == "--paced" }
    guard let path = arguments.first else { fail(usage) }
    do {
        let clock = ContinuousClock()
        let start = clock.now
        func step(_ name: String) { print("\(name) at \(clock.now - start)") }
        let (locale, format) = try await OnDeviceDictation.prepare(locale: Locale(identifier: localeID))
        step("prepared \(locale.identifier) \(format)")
        let hints = option("--hints")?.split(separator: ",").map(String.init) ?? []
        let session = DictationSession(locale: locale, format: format, hints: hints)
        let started = Task { try await session.start() }
        // "none" sends no audio at all, like a microphone that never delivered a buffer.
        if path != "none" {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096),
                  (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
                session.append(buffer)
                if paced { try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate)) }
            }
        }
        step("appended audio")
        try await started.value
        step("analyzer started")
        let text = try await session.finish()
        step("finished")
        print(text)
    } catch {
        fail("live transcription failed: \(error.localizedDescription)")
    }

default:
    fail(usage)
}
