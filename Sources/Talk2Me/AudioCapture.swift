import AVFAudio

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice

    var errorDescription: String? { "No microphone input is available." }
}

/// Streams microphone buffers while a dictation is recording. Nothing is written to disk.
final class AudioCapture {
    private var engine: AVAudioEngine?

    /// `onBuffer` runs on an audio thread.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }
}
