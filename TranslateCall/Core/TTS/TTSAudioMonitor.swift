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
    /// Logs the first skipped buffer of a recording only (guarded by `lock`).
    private var loggedFormatSkip = false
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    /// When true, the file will be created lazily on the first buffer in `process(_:)`.
    private var recordingPending: Bool = false

    // MARK: - State

    /// Master toggle. When false, `process(_:)` is a no-op.
    var isEnabled: Bool = false
    /// Serializes connect/start/schedule/play on the player (see `schedule(_:restartingPlayer:)`).
    private let playerLock = NSLock()
    /// Format the player is connected with; nil until the first buffer. Guarded by `playerLock`.
    private var playerFormat: AVAudioFormat?

    /// True while recording to file (or pending first buffer).
    var isRecording: Bool { lock.withLock { recordingFile != nil || recordingPending } }

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
        guard schedule(buffer, restartingPlayer: false) else { return }
        record(buffer)
    }

    /// Connects the player for `buffer.format`, (re)starts the engine and schedules the buffer, all
    /// under `playerLock`: `process` runs on the playback service's executor and `playLastRecording`
    /// on the main actor, so without the lock one path could schedule a buffer on a player the other
    /// just reconnected at another format (that raises an exception and crashes the app).
    /// Only the player→mixer connection changes; no HAL/AU format is ever written.
    private func schedule(_ buffer: AVAudioPCMBuffer, restartingPlayer: Bool) -> Bool {
        playerLock.withLock {
            if restartingPlayer { playerNode.stop() }
            // The player must be connected with the buffer's format, and that format changes when the
            // playback service falls back to another engine mid-session (F8.5.2).
            connectPlayer(for: buffer.format)
            // Restart engine if it was invalidated (e.g. after stop/start cycle).
            if !engine.isRunning {
                do {
                    try engine.start()
                    logger.info("Monitor engine restarted")
                } catch {
                    logger.warning("Monitor engine restart failed: \(error.localizedDescription)")
                    return false
                }
            }
            playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
            if !playerNode.isPlaying { playerNode.play() }
            return true
        }
    }

    /// Writes `buffer` to the recording file, creating it lazily on the first buffer.
    private func record(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        switch Self.recordingAction(pending: recordingPending && recordingURL != nil,
                                    fileFormat: recordingFile?.processingFormat,
                                    incoming: buffer.format) {
        case .none:
            return
        case .create:
            guard let url = recordingURL else { return }
            recordingPending = false
            do {
                // The processing format is the buffer's own, so `write(from:)` accepts it as is.
                recordingFile = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
                                                commonFormat: buffer.format.commonFormat,
                                                interleaved: buffer.format.isInterleaved)
                logger.info("Recording file created with format: \(buffer.format.description)")
            } catch {
                logger.warning("Failed to create recording file: \(error.localizedDescription)")
                return
            }
        case .write:
            break
        case .skip:
            if !loggedFormatSkip {
                loggedFormatSkip = true
                let format = buffer.format.description
                logger.info("Recording skips audio in another format (fallback engine): \(format)")
            }
            return
        }
        do {
            try recordingFile?.write(from: buffer)
        } catch {
            logger.warning("Failed to write buffer to recording: \(error.localizedDescription)")
        }
    }

    /// What `process` does with a buffer for the recording.
    enum RecordingAction: Equatable {
        case none, create, write, skip
    }

    /// The recording file keeps the format of its first buffer. A buffer in another format (the
    /// playback service fell back mid-session, e.g. 24 kHz Edge → 22.05 kHz AVSpeech) is skipped
    /// rather than written at the wrong rate or split into segments: skipping is the simpler choice
    /// and keeps "Play last recording" meaningful — one file, played back at its true speed, with the
    /// audio of the engine the recording started on.
    static func recordingAction(pending: Bool, fileFormat: AVAudioFormat?,
                                incoming: AVAudioFormat) -> RecordingAction {
        guard let fileFormat else { return pending ? .create : .none }
        return fileFormat == incoming ? .write : .skip
    }

    /// True when the player has to be (re)connected before scheduling a buffer of `incoming` format.
    static func needsReconnect(current: AVAudioFormat?, incoming: AVAudioFormat) -> Bool {
        current != incoming
    }

    /// Caller holds `playerLock`.
    private func connectPlayer(for format: AVAudioFormat) {
        guard Self.needsReconnect(current: playerFormat, incoming: format) else { return }
        playerNode.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: mixer, format: format)
        playerFormat = format
        logger.info("Monitor player format configured: \(format.description)")
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

        lock.lock()
        recordingFile = nil
        recordingURL = url
        recordingPending = true
        loggedFormatSkip = false
        lock.unlock()

        logger.info("Recording started (pending first buffer): \(url.lastPathComponent)")
        return url
    }

    /// Stops recording and returns the URL of the completed file.
    @discardableResult
    func stopRecording() -> URL? {
        lock.lock()
        let file = recordingFile
        let url = recordingURL
        let wasPending = recordingPending
        recordingFile = nil
        recordingURL = nil
        recordingPending = false
        lock.unlock()

        if file != nil, let url {
            lastRecordingURL = url
            logger.info("Recording stopped: \(url.lastPathComponent)")
        } else if wasPending, let url {
            // Recording was pending but no TTS buffers arrived — clean up empty file.
            try? FileManager.default.removeItem(at: url)
            logger.info("Recording stopped (no audio captured): \(url.lastPathComponent)")
            return nil
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
            guard frameCount > 0 else {
                logger.info("Recording is empty (no audio was captured)")
                return
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat, frameCapacity: frameCount
            ) else { return }
            try audioFile.read(into: buffer)

            guard schedule(buffer, restartingPlayer: true) else { return }
            logger.info("Playing recording: \(url.lastPathComponent)")
        } catch {
            logger.error("Failed to play recording: \(error.localizedDescription)")
        }
    }
}
