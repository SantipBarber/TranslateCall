import AVFoundation
import Synchronization

// MARK: - PauseGate

/// Pause for both directions (M9 UI core D-5, REQ-UI-50/51, design §4.2).
///
/// Sits before each VAD (`mic → PauseGate → MicEchoGate → VAD`, `call audio → PauseGate → VAD`).
/// While paused every buffer becomes zeros of the same format and length, like `MicEchoGate`:
/// the VAD keeps its timeline and ends an utterance in progress by its silence rule. Nothing is
/// dropped. One gate per session, shared by both directions; it never touches the echo gate.
nonisolated final class PauseGate: Sendable {
    private let paused = Mutex(false)

    var isPaused: Bool { paused.withLock { $0 } }

    /// Takes effect from the next buffer.
    func setPaused(_ value: Bool) {
        paused.withLock { $0 = value }
    }

    /// The gated copy of `input`, finishing when `input` finishes.
    func gate(_ input: AsyncStream<AVAudioPCMBuffer>, label: String) -> AsyncStream<AVAudioPCMBuffer> {
        GatedAudioStream.make(input, label: label) { [self] in process($0) }.stream
    }

    /// The same instance when running, zeros while paused: a zeroed copy, or the buffer itself zeroed
    /// in place if the copy cannot be allocated (real audio never passes a pause).
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard isPaused else { return buffer }
        return GatedAudioStream.silenced(buffer)
    }
}
