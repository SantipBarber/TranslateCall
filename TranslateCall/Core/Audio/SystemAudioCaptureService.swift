import AVFoundation
import os
@preconcurrency import ScreenCaptureKit

// SCRunningApplication is a reference-counted ObjC class safe to share across isolation
// boundaries for read-only use (we only pass it to configure an SCContentFilter).
extension SCRunningApplication: @unchecked @retroactive Sendable {}

private nonisolated let logger = Logger(subsystem: "TranslateCall", category: "SystemAudioCapture")

// MARK: - Error

nonisolated enum SystemAudioCaptureError: LocalizedError {
    case permissionDenied
    case noDisplayAvailable
    case targetNotFound(bundleID: String)
    case alreadyActive
    case streamFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required to capture remote audio. "
                + "Enable it in System Settings > Privacy > Screen Recording."
        case .noDisplayAvailable:
            return "No display available for audio capture."
        case .targetNotFound(let bundleID):
            return "The call app (\(bundleID)) is not running."
        case .alreadyActive:
            return "System audio capture is already active."
        case .streamFailed(let error):
            return "Audio capture stream failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Protocol (for dependency injection / testing)

/// Protocol abstraction over `SystemAudioCaptureService` — allows mock injection
/// in `AudioCoordinator` unit tests without a real SCStream.
protocol SystemAudioCapture: Actor {
    /// Request Screen Recording permission and return the capturable apps, sorted by name.
    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication]
    /// Starts capturing `target` and returns that session's 16 kHz mono stream; `deactivate()` finishes it.
    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer>
    /// Stops capturing and finishes the session stream.
    func deactivate() async
    /// Out-of-band capture events (e.g. the SCStream stopped on its own).
    /// Lives as long as the service. Subscribe once and never cancel the iterating task —
    /// cancelling terminates the stream.
    nonisolated var events: AsyncStream<SystemCaptureEvent> { get }
}

// MARK: - Implementation

/// Actor wrapping `ScreenCaptureKit SCStream` for system audio capture.
///
/// Each `activate(target:)` returns a fresh 16 kHz mono stream, matching the format of
/// `AudioManager.startCapture()` so the same VAD/STT pipeline can consume both mic and system audio.
///
/// Uses `SCStreamBridge` (NSObject subclass) to receive SCStream sample buffers and stop
/// callbacks — same pattern as `SpeechSynthesizerDelegateBridge` for AVSpeechSynthesizer.
/// Samples are copied and downsampled synchronously by a per-activation `SystemTap`.
actor SystemAudioCaptureService: SystemAudioCapture {

    // MARK: - State

    nonisolated let events: AsyncStream<SystemCaptureEvent>
    private let eventsContinuation: AsyncStream<SystemCaptureEvent>.Continuation
    private let sampleQueue = DispatchQueue(label: "TranslateCall.SystemAudioCapture.samples")
    private var generation: UInt64 = 0
    private var session: SessionAudioStream?
    private var captureStream: SCStream?
    private var bridge: SCStreamBridge?
    /// True between the start of `activate` and its return/throw; closes the reentrancy window
    /// across its awaits (two overlapping calls must not both start an SCStream).
    private var isActivating = false

    /// True while an SCStream capture session is running.
    var isActive: Bool { captureStream != nil }

    // MARK: - Init

    init() {
        (events, eventsContinuation) = AsyncStream.makeStream(
            of: SystemCaptureEvent.self, bufferingPolicy: .bufferingNewest(8)
        )
    }

    // MARK: - Permission + app enumeration

    func requestPermissionAndLoadApps() async throws -> [SCRunningApplication] {
        do {
            let content = try await SCShareableContent.current
            return content.applications
                .sorted { $0.applicationName.localizedCompare($1.applicationName) == .orderedAscending }
        } catch {
            logger.error("SCShareableContent failed: \(error.localizedDescription)")
            throw SystemAudioCaptureError.permissionDenied
        }
    }

    // MARK: - Activation

    func activate(target: CaptureTarget) async throws -> AsyncStream<AVAudioPCMBuffer> {
        guard captureStream == nil, !isActivating else { throw SystemAudioCaptureError.alreadyActive }
        isActivating = true
        defer { isActivating = false }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.current
        } catch {
            throw SystemAudioCaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw SystemAudioCaptureError.noDisplayAvailable }
        let bundleID = switch target {
        case .app(let id): id
        }
        guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw SystemAudioCaptureError.targetNotFound(bundleID: bundleID)
        }

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])

        // Audio-only stream configuration (minimal video footprint)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        generation &+= 1
        let session = SessionAudioStream(label: "system")
        let tap = try SystemTap(session: session)
        let bridge = SCStreamBridge(service: self, generation: generation, tap: tap)
        let stream = SCStream(filter: filter, configuration: config, delegate: bridge)
        // Publish state before the startCapture suspension: buffers delivered meanwhile go to
        // `tap` (already wired), and a stop callback during the await finds a matching generation.
        self.session = session
        self.bridge = bridge
        captureStream = stream
        do {
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            session.finish()
            if captureStream === stream {
                self.session = nil
                self.bridge = nil
                captureStream = nil
            }
            throw SystemAudioCaptureError.streamFailed(underlying: error)
        }
        guard captureStream === stream else {
            // deactivate() or a stop callback tore this activation down during startCapture;
            // the session is already finished — make sure the SCStream does not keep running unowned.
            try? await stream.stopCapture()
            return session.stream
        }
        logger.info("System audio capture activated (app: \(bundleID, privacy: .public))")
        return session.stream
    }

    // MARK: - Deactivation

    func deactivate() async {
        guard let captureStream else { return }
        do {
            try await captureStream.stopCapture()
        } catch {
            logger.warning("SCStream stopCapture error (ignored): \(error.localizedDescription)")
        }
        session?.finish()
        session = nil
        self.captureStream = nil
        bridge = nil
        logger.info("System audio capture deactivated")
    }

    // MARK: - Stream stop (SCStreamDelegate, via SCStreamBridge)

    /// Maps an SCStream stop error to a user-facing reason.
    nonisolated static func stopReason(for error: Error) -> IncomingStopReason {
        if let streamError = error as? SCStreamError, streamError.code == .userDeclined {
            return .permissionDenied
        }
        return .streamError(error.localizedDescription)
    }

    /// Called from the SCStream delegate. Ignores callbacks from a previous activation or while inactive.
    @discardableResult
    func handleStreamStopped(_ reason: IncomingStopReason, generation callbackGeneration: UInt64) -> Bool {
        guard callbackGeneration == generation, captureStream != nil else { return false }
        logger.error("System audio capture stopped: \(reason.message, privacy: .public)")
        session?.finish()
        session = nil
        captureStream = nil
        bridge = nil
        eventsContinuation.yield(.stopped(reason))
        return true
    }
}

// MARK: - SCStreamBridge

/// Receives SCStream sample buffers (on `sampleQueue`) and stop errors, forwarding to the tap / actor.
/// Required because actors cannot directly conform to ObjC protocols under
/// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor without isolation conflicts.
private final class SCStreamBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // SAFETY: assigned once in init and never mutated; `weak` requires `var`.
    nonisolated(unsafe) private weak var service: SystemAudioCaptureService?
    private let generation: UInt64
    private let tap: SystemTap

    nonisolated init(service: SystemAudioCaptureService, generation: UInt64, tap: SystemTap) {
        self.service = service
        self.generation = generation
        self.tap = tap
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        tap.process(sampleBuffer)   // synchronous on sampleQueue: the CMSampleBuffer never escapes
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard let service else { return }
        let reason = SystemAudioCaptureService.stopReason(for: error)
        let generation = generation
        Task { await service.handleStreamStopped(reason, generation: generation) }
    }
}
