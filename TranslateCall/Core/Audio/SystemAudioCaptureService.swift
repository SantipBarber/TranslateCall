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
}

// MARK: - Implementation

/// Actor wrapping `ScreenCaptureKit SCStream` for system audio capture.
///
/// Each `activate(target:)` returns a fresh 16 kHz mono stream, matching the format of
/// `AudioManager.startCapture()` so the same VAD/STT pipeline can consume both mic and system audio.
///
/// Uses `SCStreamOutputBridge` (NSObject subclass) to receive SCStream callbacks —
/// same pattern as `SpeechSynthesizerDelegateBridge` for AVSpeechSynthesizer.
actor SystemAudioCaptureService: SystemAudioCapture {

    // MARK: - Private

    private var session: SessionAudioStream?
    private var captureStream: SCStream?
    private var outputBridge: SCStreamOutputBridge?
    private var converter: AVAudioConverter?

    /// True while an SCStream capture session is running.
    var isActive: Bool { captureStream != nil }

    // MARK: - Init

    init() {}

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
        guard captureStream == nil else { throw SystemAudioCaptureError.alreadyActive }

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

        // Set up AVAudioConverter: 48kHz mono → 16kHz mono
        guard
            let inputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
            let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
            let conv = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw SystemAudioCaptureError.streamFailed(
                underlying: NSError(domain: "TranslateCall", code: -1,
                                    userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter"])
            )
        }
        converter = conv

        let session = SessionAudioStream(label: "system")
        // Create delegate bridge (NSObject, avoids actor isolation conflict with SCStreamOutput)
        let bridge = SCStreamOutputBridge(service: self)
        outputBridge = bridge
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        do {
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: nil)
            try await stream.startCapture()
        } catch {
            session.finish()
            converter = nil
            outputBridge = nil
            throw SystemAudioCaptureError.streamFailed(underlying: error)
        }
        self.session = session
        captureStream = stream
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
        outputBridge = nil
        converter = nil
        logger.info("System audio capture deactivated")
    }

    // MARK: - Buffer processing (called from bridge, already on background thread via Task)

    func handleCapturedBuffer(_ input: AVAudioPCMBuffer) {
        guard let downsampled = downsample(input) else { return }
        session?.yield(downsampled)
    }

    // MARK: - Downsampling (internal, testable via actor isolation)

    func downsample(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let outputFrames = AVAudioFrameCount(
            Double(input.frameLength) * 16000.0 / 48000.0
        ) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrames
        ) else { return nil }

        final class SyncBox<T>: @unchecked Sendable {
            // SAFETY: the converter input block runs synchronously on this call's thread only.
            nonisolated(unsafe) var value: T
            nonisolated init(_ value: T) { self.value = value }
        }
        let inputBox = SyncBox<AVAudioPCMBuffer?>(input)
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, outStatus in
            if let buf = inputBox.value {
                outStatus.pointee = .haveData
                inputBox.value = nil
                return buf
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error else {
            logger.warning("AVAudioConverter error: \(convError?.localizedDescription ?? "unknown")")
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer (nonisolated, used by bridge)

    nonisolated static func extractPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        var result: AVAudioPCMBuffer?
        try? sampleBuffer.withAudioBufferList { audioBufferList, _ in
            guard
                let description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                let format = AVAudioFormat(
                    standardFormatWithSampleRate: description.mSampleRate,
                    channels: description.mChannelsPerFrame
                ),
                let pcm = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer
                )
            else { return }
            result = pcm
        }
        return result
    }
}

// MARK: - SCStreamOutputBridge

/// NSObject subclass that receives SCStream callbacks and forwards to the actor.
/// Required because actors cannot directly conform to ObjC protocols under
/// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor without isolation conflicts.
private final class SCStreamOutputBridge: NSObject, SCStreamOutput, @unchecked Sendable {
    // SAFETY: weak ref set once in nonisolated init, only read afterwards in the nonisolated callback.
    nonisolated(unsafe) private weak var service: SystemAudioCaptureService?

    nonisolated init(service: SystemAudioCaptureService) {
        self.service = service
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, let service else { return }
        guard let pcm = SystemAudioCaptureService.extractPCMBuffer(from: sampleBuffer) else { return }
        Task { await service.handleCapturedBuffer(pcm) }
    }
}
