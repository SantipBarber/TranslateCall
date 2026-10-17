import AVFoundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "GatedAudioStream")

// MARK: - GatedAudioStream

/// The stream loop and the silencing shared by `MicEchoGate` and `PauseGate` (M9 UI core P23).
/// A gate passes each buffer on or replaces it by zeros of the same format and length: the VAD
/// keeps a continuous timeline, and nothing is dropped, reordered or resized (REQ-H-04, REQ-UI-50).
nonisolated enum GatedAudioStream {

    /// `input` through `process`, buffer by buffer; finishes when `input` finishes. Overflow drops
    /// are counted and logged like the other capture streams (F8.5.1 REQ-C-05).
    static func make(_ input: AsyncStream<AVAudioPCMBuffer>, label: String,
                     capacity: Int = SessionAudioStream.capacity,
                     process: @escaping @Sendable (AVAudioPCMBuffer) -> AVAudioPCMBuffer) -> SessionAudioStream {
        let output = SessionAudioStream(label: label, capacity: capacity)
        // Ends when `input` finishes (the producer owns the session); yields to a gone consumer are no-ops.
        Task {
            for await buffer in input {
                output.yield(process(buffer))
            }
            output.finish()
        }
        return output
    }

    /// A zeroed copy of `buffer`. If the copy cannot be allocated, `buffer` itself is zeroed in place:
    /// real audio never passes a closed gate, and no buffer is dropped.
    static func silenced(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        if let silent = silence(like: buffer) { return silent }
        logger.error("Could not allocate a silent buffer; zeroing the captured one in place")
        zero(buffer)
        return buffer
    }

    /// A buffer of `buffer`'s format and length, every byte zero.
    static func silence(like buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silent = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                            frameCapacity: max(buffer.frameLength, 1)) else { return nil }
        silent.frameLength = buffer.frameLength
        zero(silent)
        return silent
    }

    private static func zero(_ buffer: AVAudioPCMBuffer) {
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            memset(data, 0, Int(audio.mDataByteSize))
        }
    }
}
