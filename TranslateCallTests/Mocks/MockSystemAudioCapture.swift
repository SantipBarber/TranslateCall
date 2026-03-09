import AVFoundation
import ScreenCaptureKit
@testable import TranslateCall

/// Test double for `SystemAudioCapture`.
actor MockSystemAudioCapture: SystemAudioCapture {
    nonisolated let audioStream16kHz: AsyncStream<AVAudioPCMBuffer>
    nonisolated(unsafe) private(set) var isActive: Bool = false

    private var streamContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    // Call tracking
    var requestPermissionCalled = false
    var activateCalled = false
    var deactivateCalled = false
    var activateApp: SCRunningApplication?

    // Configurable errors
    var throwOnRequestPermission: Error?
    var throwOnActivate: Error?

    // Configurable app list
    var appsToReturn: [SCRunningApplication] = []

    init() {
        var cont: AsyncStream<AVAudioPCMBuffer>.Continuation?
        audioStream16kHz = AsyncStream { cont = $0 }
        streamContinuation = cont
    }

    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication] {
        requestPermissionCalled = true
        if let error = throwOnRequestPermission { throw error }
        return appsToReturn
    }

    func activate(app: SCRunningApplication?) async throws {
        if let error = throwOnActivate { throw error }
        activateCalled = true
        activateApp = app
        isActive = true
    }

    func deactivate() async {
        deactivateCalled = true
        isActive = false
        streamContinuation?.finish()
    }

    /// Inject a PCM buffer into the stream (simulates captured remote audio).
    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        streamContinuation?.yield(buffer)
    }
}
