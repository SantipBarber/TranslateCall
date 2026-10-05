import AVFoundation
import FluidAudio
import Foundation

// MARK: - SpeechSegment

/// A complete detected utterance, ready for STT.
///
/// `audio` is 16 kHz mono Float32 — the same format as the stream returned by `AudioCapture.startCapture()`.
/// It can be appended directly to `SFSpeechAudioBufferRecognitionRequest`.
struct SpeechSegment: Sendable {
    let audio: AVAudioPCMBuffer
    let capturedAt: Date
}

// MARK: - VADEngine

enum VADEngine: Sendable {
    case silero
    case energy
}

// MARK: - VADConfiguration

/// Engine-agnostic VAD configuration.
///
/// FluidAudio adapter properties live in `SileroVADService.swift` to keep this
/// file free of third-party imports.
nonisolated struct VADConfiguration: Sendable, Equatable {
    /// Speech probability threshold (Silero). Above → speech active.
    var sileroThreshold: Float = 0.85
    /// RMS level threshold in dBFS (Energy fallback). Above → speech active.
    var energyThresholdDBFS: Float = -40.0
    /// Minimum voiced duration before a segment is considered speech.
    var minSpeechDuration: TimeInterval = 0.15
    /// Pause that closes an utterance ("Pause to translate", F8.5.3 D-6: 0.4–1.2 s, default 0.6 s).
    var minSilenceDuration: TimeInterval = 0.6
    /// Maximum utterance duration; longer segments are force-emitted.
    var maxSpeechDuration: TimeInterval = 14.0
    /// Pre-speech context padding prepended to each utterance via the history buffer.
    var speechPadding: TimeInterval = 0.1

    nonisolated static let `default` = VADConfiguration()

    // MARK: - FluidAudio adapters (internal — insulates callers from library types)

    internal var fluidVadConfig: VadConfig {
        VadConfig(defaultThreshold: sileroThreshold)
    }

    internal var fluidSegmentationConfig: VadSegmentationConfig {
        VadSegmentationConfig(
            minSpeechDuration: minSpeechDuration,
            minSilenceDuration: sileroMinSilenceDuration,   // one chunk less: see the property (F8.5.3 P2)
            maxSpeechDuration: maxSpeechDuration,
            speechPadding: speechPadding
        )
    }
}

// MARK: - VADService

/// Actor-based VAD service protocol.
///
/// Both `SileroVADService` and `EnergyVADService` conform to this protocol.
/// Streams are `nonisolated let` — initialized in `init()` before any async work,
/// so they are safe to access without `await` from any context.
protocol VADService: Actor {
    /// Completed utterances. Consumed by STT (F2.2).
    nonisolated var speechSegments: AsyncStream<SpeechSegment> { get }

    /// VAD state events: `true` = speech started, `false` = speech ended.
    /// Consumed by `AudioViewModel` to drive `isSpeechActive`.
    nonisolated var vadStateEvents: AsyncStream<Bool> { get }

    /// The engine backing this instance.
    nonisolated var engine: VADEngine { get }

    /// Begin consuming the 16 kHz stream. Spawns internal processing task.
    func activate(stream: AsyncStream<AVAudioPCMBuffer>) async throws

    /// Stop processing. Flushes any in-progress utterance before returning.
    func deactivate() async
}

// MARK: - VADService helpers

extension VADService {
    /// Wrap a `[Float]` sample array (16 kHz mono) into an `AVAudioPCMBuffer`.
    /// Returns `nil` if format creation or buffer allocation fails.
    nonisolated func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        // 16_000 inlined — top-level lets inherit @MainActor under SWIFT_DEFAULT_ACTOR_ISOLATION
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ) else { return nil }

        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channelData = buffer.floatChannelData else { return nil }

        buffer.frameLength = frameCount
        samples.withUnsafeBufferPointer { src in
            guard let baseAddress = src.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }
        return buffer
    }
}
