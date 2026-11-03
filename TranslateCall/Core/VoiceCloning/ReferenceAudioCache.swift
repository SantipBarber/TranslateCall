import Foundation
import MLX

// MARK: - ReferenceAudioCache

/// Hands the same voice to mlx-audio as the same array object. mlx-audio keeps the analysis of the last
/// reference (speaker embedding and speech codes) keyed by the array's identity, so a new array per sentence
/// made it analyse the user's recording again for every sentence.
nonisolated final class ReferenceAudioCache: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (samples: [Float], array: MaterializedArray)?

    /// The array for `samples`: the previous one when the samples are the same.
    func array(for samples: [Float]) -> MaterializedArray {
        lock.withLock {
            if let last, last.samples == samples { return last.array }
            let array = MLXArray(samples).materialized()
            last = (samples, array)
            return array
        }
    }
}
