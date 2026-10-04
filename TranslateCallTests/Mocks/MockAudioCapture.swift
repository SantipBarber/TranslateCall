import AVFoundation
@testable import TranslateCall

/// Test double for `AudioCapture`: a fresh stream per `startCapture()`, like `AudioManager`.
@MainActor
final class MockAudioCapture: AudioCapture {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    private(set) var startCount = 0
    var startCaptureCalled: Bool { startCount > 0 }
    private(set) var stopCount = 0
    var stopCaptureCalled: Bool { stopCount > 0 }
    /// True between a `startCapture()` and the next `stopCapture()`, like `AudioManager`.
    var isCapturing: Bool { continuation != nil }
    var throwOnStartCapture: Error?

    func startCapture() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if let error = throwOnStartCapture { throw error }
        startCount += 1
        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(SessionAudioStream.capacity)
        )
        self.continuation = continuation
        return stream
    }

    func stopCapture() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    /// Feeds a buffer into the current session's stream (simulated mic audio).
    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }
}
