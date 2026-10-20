import Accelerate
import AVFAudio

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice

    var errorDescription: String? { "No microphone input is available." }
}

/// Streams microphone buffers while a dictation is recording. Nothing is written to disk.
final class AudioCapture {
    private var engine: AVAudioEngine?
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var configurationObserver: NSObjectProtocol?

    /// `onBuffer` runs on an audio thread.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        try Self.tapAndStart(engine, onBuffer)
        self.engine = engine
        self.onBuffer = onBuffer
        // A Bluetooth headset switches to its call profile when the microphone opens, which
        // changes the input format and can stop the engine. Start again with the new format;
        // DictationSession converts whatever format arrives.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        onBuffer = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private func restartAfterConfigurationChange() {
        guard let engine, let onBuffer else { return }
        engine.stop()
        try? Self.tapAndStart(engine, onBuffer)
    }

    private static func tapAndStart(_ engine: AVAudioEngine, _ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Loudness of a buffer from 0 (silence) to 1 (loud speech), for the level meter.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        // Speech sits roughly between -50 dB (quiet) and -10 dB (loud); map that range to 0...1.
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 50) / 40, 0), 1)
    }
}
