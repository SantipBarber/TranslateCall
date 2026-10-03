import AVFoundation
import ScreenCaptureKit
@testable import TranslateCall

/// Test double for `SystemAudioCapture`: a fresh stream per `activate(target:)`.
actor MockSystemAudioCapture: SystemAudioCapture {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    var requestPermissionCalled = false
    private(set) var activatedTargets: [CaptureTarget] = []
    var activateCalled: Bool { !activatedTargets.isEmpty }
    private(set) var deactivateCount = 0
    var deactivateCalled: Bool { deactivateCount > 0 }

    var throwOnRequestPermission: Error?
    var throwOnActivate: Error?
    var appsToReturn: [SCRunningApplication] = []

    nonisolated let events: AsyncStream<SystemCaptureEvent>
    private let eventsContinuation: AsyncStream<SystemCaptureEvent>.Continuation

    init() {
        (events, eventsContinuation) = AsyncStream.makeStream(of: SystemCaptureEvent.self, bufferingPolicy: .bufferingNewest(8))
    }

    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication] {
        requestPermissionCalled = true
        if let error = throwOnRequestPermission { throw error }
        return appsToReturn
    }

    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer> {
        if let error = throwOnActivate { throw error }
        activatedTargets.append(target)
        let (stream, continuation) = AsyncStream.makeStream(
            of: AVAudioPCMBuffer.self, bufferingPolicy: .bufferingNewest(SessionAudioStream.capacity)
        )
        self.continuation = continuation
        return stream
    }

    func deactivate() async {
        deactivateCount += 1
        continuation?.finish()
        continuation = nil
    }

    /// Feeds a buffer into the current session's stream (simulated remote audio).
    func injectBuffer(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }

    /// Simulates an out-of-band event (e.g. the SCStream died). Finishes the stream for `.stopped`.
    func emit(_ event: SystemCaptureEvent) {
        if case .stopped = event { continuation?.finish(); continuation = nil }
        eventsContinuation.yield(event)
    }
}
