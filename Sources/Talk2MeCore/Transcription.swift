@preconcurrency import AVFAudio
import Foundation
import Speech
import Synchronization

public enum TranscriptionError: Error, LocalizedError {
    case unsupportedLocale(String)
    case noAudioFormat

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): "On-device dictation does not support \(id)."
        case .noAudioFormat: "No audio format is available for on-device dictation."
        }
    }
}

/// On-device speech-to-text with Apple's SpeechAnalyzer and DictationTranscriber (macOS 26+).
/// Audio never leaves the Mac.
public enum OnDeviceDictation {
    static func makeTranscriber(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    /// Resolves the locale and makes sure its speech assets are installed.
    /// Returns the supported locale and the audio format the analyzer wants.
    public static func prepare(locale: Locale) async throws -> (Locale, AVAudioFormat) {
        guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        let transcriber = makeTranscriber(locale: supported)
        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        return (supported, format)
    }

    public static func supportedLocales() async -> [Locale] {
        await DictationTranscriber.supportedLocales
    }

    /// Transcribes a whole audio file. Used by the bench tool and tests of the pipeline.
    public static func transcribeFile(_ url: URL, locale: Locale) async throws -> String {
        let (supported, _) = try await prepare(locale: locale)
        let transcriber = makeTranscriber(locale: supported)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { try await collect(transcriber.results) }
        let file = try AVAudioFile(forReading: url)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    static func collect<S: AsyncSequence>(_ results: S) async throws -> String where S.Element == DictationTranscriber.Result {
        var text = ""
        for try await result in results {
            text += String(result.text.characters)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One live dictation: feed microphone buffers in, get the transcript out at the end.
///
/// Buffers are queued from the moment the session is created, so words spoken while the
/// analyzer is still starting are not lost.
public final class DictationSession: @unchecked Sendable {
    private let transcriber: DictationTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var collector: Task<String, Error>?
    // Only touched from the audio thread that calls `append`.
    private var converter: AVAudioConverter?
    private let audioArrived = Mutex(false)
    private let hints: [String]

    /// False when the microphone delivered nothing, e.g. without Microphone access.
    public var receivedAudio: Bool { audioArrived.withLock { $0 } }

    /// `hints` are words the recognizer should expect, such as the user's dictionary words.
    public init(locale: Locale, format: AVAudioFormat, hints: [String] = []) {
        self.hints = hints
        self.transcriber = OnDeviceDictation.makeTranscriber(locale: locale)
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
        self.format = format
        (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    }

    public func start() async throws {
        let transcriber = self.transcriber
        collector = Task { try await OnDeviceDictation.collect(transcriber.results) }
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            // Only a hint: dictation still works without it.
            try? await analyzer.setContext(context)
        }
        try await analyzer.start(inputSequence: input)
    }

    /// Called on the audio thread for every microphone buffer.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        audioArrived.withLock { $0 = true }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    /// Ends the audio and waits for the final transcript.
    public func finish() async throws -> String {
        continuation.finish()
        // The analyzer never finishes an input that had no audio at all, and there is nothing to transcribe.
        guard receivedAudio else {
            await analyzer.cancelAndFinishNow()
            collector?.cancel()
            return ""
        }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector?.value ?? ""
    }

    public func cancel() async {
        continuation.finish()
        await analyzer.cancelAndFinishNow()
        collector?.cancel()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        // The converter calls this block synchronously, on this thread, before `convert` returns.
        nonisolated(unsafe) var supplied = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
}
