import AVFoundation

// AVSpeechSynthesizer.write(_:toBufferCallback:) must be called on the main thread —
// Apple's documented requirement. That's why this is @MainActor.
@MainActor
final class Synthesis {
    nonisolated(unsafe) private let synthesizer: AVSpeechSynthesizer
    nonisolated private let voice: AVSpeechSynthesisVoice

    // Nonisolated so top-level main.swift can construct without hopping to the main actor.
    // AVSpeechSynthesizer() itself can be initialized off-main; the *use* of write() is
    // what requires main thread, hence @MainActor on the class for methods below.
    nonisolated init(voice: AVSpeechSynthesisVoice) {
        self.voice = voice
        self.synthesizer = AVSpeechSynthesizer()
    }

    // Yields PCM chunks (Int16, mono) as the synthesizer produces them.
    // Each chunk carries its own sample rate; in practice it's constant per utterance
    // (voice-dependent — Enhanced English voices are 22050 Hz).
    //
    // HA serializes TTS requests, so we don't guard against concurrent calls here.
    // Two simultaneous synthesizes would call write() twice, which AVSpeechSynthesizer
    // doesn't support; trust the caller.
    func synthesizeStreaming(text: String) -> AsyncStream<(rate: Int, data: Data)> {
        AsyncStream { continuation in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // Apple signals end-of-stream with a zero-length buffer.
                if pcm.frameLength == 0 {
                    continuation.finish()
                    return
                }
                if let chunk = floatBufferToInt16(pcm) {
                    continuation.yield((Int(pcm.format.sampleRate), chunk))
                }
            }
        }
    }

    func cancel() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// AVSpeechSynthesizer outputs float32 PCM. Wyoming consumers expect Int16 PCM.
// Clamp to [-1, 1] and scale to Int16 range. Loop is fine — chunks are ~1024 samples.
private func floatBufferToInt16(_ buffer: AVAudioPCMBuffer) -> Data? {
    guard let floats = buffer.floatChannelData?[0] else { return nil }
    let count = Int(buffer.frameLength)
    var int16s = [Int16](repeating: 0, count: count)
    for i in 0..<count {
        let clamped = max(-1.0, min(1.0, floats[i]))
        int16s[i] = Int16(clamped * Float(Int16.max))
    }
    return int16s.withUnsafeBufferPointer { Data(buffer: $0) }
}
