import AVFoundation
import OSLog

private nonisolated let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TTSAudioMonitor")

/// Plays a copy of outgoing TTS audio through system speakers and optionally records to WAV.
///
/// Used for development/testing when outgoing TTS routes exclusively to BlackHole.
/// Thread-safe: `process(_:)` is nonisolated and can be called from any actor.
/// Properties accessed from @MainActor context (AudioCoordinator) use the lock for recording state.
nonisolated final class TTSAudioMonitor: @unchecked Sendable {

    // MARK: - Audio engine (routes to system default speakers)

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()

    // MARK: - Recording

    private let lock = NSLock()
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?

    // MARK: - State

    /// Master toggle. When false, `process(_:)` is a no-op.
    var isEnabled: Bool = false

    /// True while recording to file.
    var isRecording: Bool { lock.withLock { recordingFile != nil } }

    /// URL of the last completed recording (nil until first recording finishes).
    private(set) var lastRecordingURL: URL?

    // MARK: - Init

    init() throws {
        engine.attach(playerNode)
        engine.attach(mixer)
        engine.connect(playerNode, to: mixer, format: nil)
        engine.connect(mixer, to: engine.outputNode,
                       format: engine.outputNode.outputFormat(forBus: 0))
        try engine.start()
        logger.info("TTSAudioMonitor initialized — routing to system speakers")
    }

    deinit {
        engine.stop()
    }

    // MARK: - Buffer processing

    /// Plays the buffer through speakers and writes to the recording file if active.
    /// Safe to call from any actor / thread.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled, buffer.frameLength > 0 else { return }

        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !playerNode.isPlaying { playerNode.play() }

        lock.lock()
        if let file = recordingFile {
            do {
                try file.write(from: buffer)
            } catch {
                logger.warning("Failed to write buffer to recording: \(error.localizedDescription)")
            }
        }
        lock.unlock()
    }

    // MARK: - Recording API

    /// Starts recording all monitored audio to a timestamped WAV file.
    /// Returns the URL where the file is being written.
    @discardableResult
    func startRecording() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslateCall_Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("tts_\(timestamp).wav")

        let format = engine.outputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        lock.lock()
        recordingFile = file
        recordingURL = url
        lock.unlock()

        logger.info("Recording started: \(url.lastPathComponent)")
        return url
    }

    /// Stops recording and returns the URL of the completed file.
    @discardableResult
    func stopRecording() -> URL? {
        lock.lock()
        let file = recordingFile
        let url = recordingURL
        recordingFile = nil
        recordingURL = nil
        lock.unlock()

        if file != nil, let url {
            lastRecordingURL = url
            logger.info("Recording stopped: \(url.lastPathComponent)")
        }
        return url
    }

    // MARK: - Playback of recordings

    /// Plays the last recording through system speakers.
    func playLastRecording() {
        guard let url = lastRecordingURL else {
            logger.info("No recording to play")
            return
        }
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let frameCount = AVAudioFrameCount(audioFile.length)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat, frameCapacity: frameCount
            ) else { return }
            try audioFile.read(into: buffer)

            playerNode.stop()
            playerNode.scheduleBuffer(buffer, at: nil, options: [])
            playerNode.play()
            logger.info("Playing recording: \(url.lastPathComponent)")
        } catch {
            logger.error("Failed to play recording: \(error.localizedDescription)")
        }
    }
}
