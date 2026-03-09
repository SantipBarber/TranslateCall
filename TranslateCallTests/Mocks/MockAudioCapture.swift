import AVFoundation
@testable import TranslateCall

/// Test double for `AudioCapture`. Runs on `@MainActor` to match the protocol's isolation.
@MainActor
final class MockAudioCapture: AudioCapture {

    let audioStream16kHz: AsyncStream<AVAudioPCMBuffer>
    private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    // Call tracking
    var startCaptureCalled = false
    var stopCaptureCalled = false

    // Configurable error
    var throwOnStartCapture: Error?

    init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation?
        audioStream16kHz = AsyncStream { cont = $0 }
        streamContinuation = cont
    }

    func startCapture() async throws {
        if let error = throwOnStartCapture { throw error }
        startCaptureCalled = true
    }

    func stopCapture() {
        stopCaptureCalled = true
        streamContinuation?.finish()
    }

    /// Inject a PCM buffer into the stream (simulates incoming mic audio).
    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        streamContinuation?.yield(buffer)
    }
}
