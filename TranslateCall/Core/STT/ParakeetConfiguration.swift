import FluidAudio
import Foundation

// MARK: - ParakeetConfiguration

/// Configuration for the FluidAudio Parakeet STT engine.
struct ParakeetConfiguration: Sendable {
    /// CoreML model version. `.v3` is the recommended TDT 0.6B model.
    var modelVersion: AsrModelVersion = .v3
    /// Prefer Apple Neural Engine for inference. Yields fastest on-device latency on M1+.
    var preferANE: Bool = true

    nonisolated static let `default` = ParakeetConfiguration()
}
