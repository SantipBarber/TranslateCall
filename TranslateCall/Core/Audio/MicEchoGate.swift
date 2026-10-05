import AVFoundation
import OSLog
import Synchronization

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "MicEchoGate")

// MARK: - MicEchoGate

/// Keeps the remote side's translation out of the outgoing pipeline when it plays on speakers
/// (F8.5.3 REQ-H-02…07, design §3.2).
///
/// Sits between the session audio stream and the outgoing VAD. In `.speakers` mode a buffer that
/// arrives while incoming TTS is speaking, or within `tail` after it stopped, is replaced by zeros of
/// the same format and length: the VAD keeps a continuous timeline and ends an utterance in progress
/// by its normal silence rule. Nothing is dropped, reordered or resized (REQ-H-04). There is no timer:
/// the tail is checked against the clock when each buffer arrives (every 10–100 ms).
nonisolated final class MicEchoGate: Sendable {
    private struct State {
        var mode: ListeningMode
        var incomingSpeaking = false
        /// Clock offset at which the gate reopens after incoming TTS stopped.
        var reopenAt: Duration?
        var isMuting = false
    }

    private let state: Mutex<State>
    private let tail: Duration
    private let now: @Sendable () -> Duration
    private let onPausedChange: @Sendable (Bool) -> Void

    /// - Parameter onPausedChange: called on every muting ↔ open transition, from the caller's thread.
    ///   The Bool is advisory: transitions can be reported out of order across threads (a late `true`
    ///   from `process` may arrive after a `false` from `setMode`/`reset`). Consumers must hop to their
    ///   own actor and re-read `isMicPaused`, which is authoritative, instead of trusting the argument.
    init(mode: ListeningMode,
         tail: Duration = .milliseconds(300),
         clock: any Clock<Duration> = ContinuousClock(),
         onPausedChange: @escaping @Sendable (Bool) -> Void = { _ in }) {
        state = Mutex(State(mode: mode))
        self.tail = tail
        now = Self.offsetReader(clock)
        self.onPausedChange = onPausedChange
    }

    /// True while buffers are being replaced by silence. Authoritative (read under the lock).
    var isMicPaused: Bool { state.withLock { $0.isMuting } }

    /// Takes effect from the next buffer; switching to `.headphones` reopens at once (REQ-H-05).
    func setMode(_ mode: ListeningMode) {
        let reopened: Bool = state.withLock { current in
            current.mode = mode
            guard mode == .headphones, current.isMuting else { return false }
            current.isMuting = false
            return true
        }
        if reopened { onPausedChange(false) }
    }

    /// Incoming TTS started or stopped speaking. Only a true → false change starts the tail.
    func setIncomingSpeaking(_ speaking: Bool) {
        let now = now()
        state.withLock { current in
            if !speaking, current.incomingSpeaking { current.reopenAt = now + tail }
            current.incomingSpeaking = speaking
        }
    }

    /// Incoming went away (torn down, session stop): reopen at once, without the tail (REQ-H-06).
    func reset() {
        let wasMuting: Bool = state.withLock { current in
            current.incomingSpeaking = false
            current.reopenAt = nil
            defer { current.isMuting = false }
            return current.isMuting
        }
        if wasMuting { onPausedChange(false) }
    }

    /// The gated copy of `input`: finishes when `input` finishes.
    func gate(_ input: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<AVAudioPCMBuffer> {
        gatedSession(input).stream
    }

    /// Same as `gate(_:)`, keeping the `SessionAudioStream` so overflow drops are counted and logged
    /// like the other capture streams (F8.5.1 REQ-C-05).
    func gatedSession(_ input: AsyncStream<AVAudioPCMBuffer>,
                      capacity: Int = SessionAudioStream.capacity) -> SessionAudioStream {
        let output = SessionAudioStream(label: "outgoing-gated", capacity: capacity)
        // Ends when `input` finishes (the producer owns the session); yields to a gone consumer are no-ops.
        Task { [self] in
            for await buffer in input {
                output.yield(process(buffer))
            }
            output.finish()
        }
        return output
    }

    /// One buffer through the gate: the same instance when open, a zeroed copy when muting (REQ-H-03).
    func process(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let now = now()
        let (muting, changed): (Bool, Bool) = state.withLock { current in
            if let reopenAt = current.reopenAt, now >= reopenAt { current.reopenAt = nil }
            let muting = current.mode == .speakers && (current.incomingSpeaking || current.reopenAt != nil)
            let changed = muting != current.isMuting
            current.isMuting = muting
            return (muting, changed)
        }
        if changed { onPausedChange(muting) }
        guard muting else { return buffer }
        if let silent = Self.silence(like: buffer) { return silent }
        // Allocation failed: silence the buffer itself rather than let echo through (never drop it).
        logger.error("Could not allocate a silent buffer; zeroing the captured one in place")
        Self.zero(buffer)
        return buffer
    }

    // MARK: - Helpers

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

    /// Elapsed time on `clock` since the gate was created (opens the existential's `Instant`).
    private static func offsetReader<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }
}
