import FluidAudioEspeak
import Foundation

// MARK: - KokoroTtsManaging

/// Minimal protocol over KokoroTtsManager for dependency injection and testing.
///
/// Isolates the FluidAudioEspeak dependency from KokoroUtteranceSynthesizer,
/// exactly as AsrTranscriber isolates FluidAudio from ParakeetSpeechService.
nonisolated protocol KokoroTtsManaging: Sendable {
    /// Synthesises `text` and returns raw PCM samples at 24 kHz mono Float32.
    func synthesizeSamples(text: String, voice: String?) async throws -> [Float]
}

// MARK: - KokoroTtsManager conformance

// KokoroTtsManager is a `final class` with no Sendable conformance.
// Marked @unchecked Sendable: all mutable state is accessed exclusively from
// KokoroModelManager's actor context — safe by design.
extension KokoroTtsManager: @unchecked @retroactive Sendable {}

extension KokoroTtsManager: KokoroTtsManaging {
    func synthesizeSamples(text: String, voice: String?) async throws -> [Float] {
        let result = try await synthesizeDetailed(text: text, voice: voice)
        // Flatten per-chunk Float32 samples — 24 kHz mono, no WAV header parsing needed.
        return result.chunks.flatMap { $0.samples }
    }
}
