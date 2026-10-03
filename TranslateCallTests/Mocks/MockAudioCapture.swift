import AVFoundation
@testable import TranslateCall

/// Test double for `AudioCapture`: a fresh stream per `startCapture()`, like `AudioManager`.
@MainActor
final class MockAudioCapture: AudioCapture {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    private(set) var startCount = 0
    var startCaptureCalled: Bool { startCount > 0 }
    var stopCaptureCalled = false
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
        stopCaptureCalled = true
        continuation?.finish()
        continuation = nil
    }

    /// Feeds a buffer into the current session's stream (simulated mic audio).
    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }
}
