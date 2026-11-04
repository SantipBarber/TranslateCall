import Foundation
import MLX
import Testing
@testable import TranslateCall

/// mlx-audio caches a reference's analysis (speaker embedding + speech codes) by the identity of the array it
/// is given, so the same voice must reach it as the same array object.
@Suite("Reference audio cache")
struct ReferenceAudioCacheTests {
    @Test func theSameVoiceGivesTheSameArray() {
        let cache = ReferenceAudioCache()
        let voice: [Float] = [0.1, -0.2, 0.3]
        let first = cache.array(for: voice)
        let second = cache.array(for: Array(voice))
        #expect(ObjectIdentifier(first) == ObjectIdentifier(second))
        #expect(first.asArray(Float.self) == voice)
    }

    @Test func anotherVoiceGivesANewArray() {
        let cache = ReferenceAudioCache()
        let first = cache.array(for: [0.1, 0.2])
        let other = cache.array(for: [0.1, 0.3])
        #expect(ObjectIdentifier(first) != ObjectIdentifier(other))
        #expect(other.asArray(Float.self) == [0.1, 0.3])
    }
}
