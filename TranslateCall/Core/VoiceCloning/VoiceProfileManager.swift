import Combine
import Foundation
import OSLog

private nonisolated let logger = Logger(
    subsystem: "com.spbarber.TranslateCall",
    category: "VoiceProfileManager"
)

// MARK: - Recording State

enum RecordingState: Sendable {
    case idle
    case recording(elapsedSeconds: Float)
    case processing
    case reviewing(RecordingResult)
    case saving
    case error(String)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isReviewing: Bool {
        if case .reviewing = self { return true }
        return false
    }

    var reviewingResult: RecordingResult? {
        if case .reviewing(let result) = self { return result }
        return nil
    }
}

// MARK: - Voice Profile Manager

@MainActor
final class VoiceProfileManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var profiles: [VoiceProfileHeader] = []
    @Published private(set) var recordingState: RecordingState = .idle
    @Published var activeProfileId: UUID?
    @Published private(set) var recordingMode: RecordingMode = .free
    /// Counts saves that completed: the sheet closes on a change; a failed save never changes it.
    @Published private(set) var completedSaves = 0

    var activeProfile: VoiceProfileHeader? {
        profiles.first { $0.id == activeProfileId }
    }

    // MARK: - Dependencies (injectable)

    /// Exposed for `TTSEngineSelector` voice clone factory injection.
    let profileStore: any VoiceProfileStoring
    let recorder: any VoiceRecording
    private let clock: any Clock<Duration>
    private let defaults: UserDefaults
    private let isSessionActive: () -> Bool

    private static let activeProfileKey = "tlk.voiceCloning.activeProfileId"

    // MARK: - Elapsed timer

    private var elapsedTask: Task<Void, Never>?
    /// Elapsed time in 100 ms ticks: an integer count, so the auto-stop never drifts like a float sum.
    private var elapsedTicks = 0

    // MARK: - Init

    init(
        store: any VoiceProfileStoring = VoiceProfileStore(),
        recorder: any VoiceRecording = VoiceProfileRecorder(),
        defaults: UserDefaults = .standard,
        clock: any Clock<Duration> = ContinuousClock(),
        isSessionActive: @escaping () -> Bool = { false }
    ) {
        self.clock = clock
        self.profileStore = store
        self.recorder = recorder
        self.defaults = defaults
        self.isSessionActive = isSessionActive

        // Restore active profile UUID
        if let raw = defaults.string(forKey: Self.activeProfileKey),
           let id = UUID(uuidString: raw) {
            activeProfileId = id
        }

        Task { await loadProfiles() }
    }

    // MARK: - Profile Loading

    func loadProfiles() async {
        do {
            profiles = try await profileStore.enumerateHeaders()
                .sorted { $0.createdAt > $1.createdAt }
            // Validate active profile still exists
            if let id = activeProfileId, !profiles.contains(where: { $0.id == id }) {
                logger.info("Active profile \(id) no longer exists — resetting")
                setActiveProfile(nil)
            }
        } catch {
            logger.error("Failed to load profiles: \(error)")
        }
    }

    // MARK: - Recording Flow

    func startRecording(mode: RecordingMode = .free) async {
        guard !isSessionActive() else {
            recordingState = .error(VoiceProfileRecorderError.sessionConflict.localizedDescription)
            return
        }
        recordingMode = mode
        recordingState = .recording(elapsedSeconds: 0)
        elapsedTicks = 0
        do {
            try await recorder.startRecording()
        } catch {
            recordingState = .error(error.localizedDescription)
            return
        }
        // Only now: the permission prompt may have taken any time, and none of it is recording.
        guard recordingState.isRecording else {
            // Cancelled or stopped while the prompt was open: the recorder started anyway, so release it.
            _ = try? await recorder.stopRecording(mode: mode)
            return
        }
        startElapsedTimer()
    }

    func stopRecording() async {
        await finishRecording(reachedLimit: false)
    }

    private func finishRecording(reachedLimit: Bool) async {
        stopElapsedTimer()
        recordingState = .processing
        do {
            var result = try await recorder.stopRecording(mode: recordingMode)
            result.reachedLimit = reachedLimit
            recordingState = .reviewing(result)
        } catch {
            recordingState = .error(error.localizedDescription)
        }
    }

    // MARK: - Save Flow

    func saveProfile(
        name: String,
        transcript: String,
        result: RecordingResult,
        makeActive: Bool = false
    ) async throws {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VoiceProfileValidationError.emptyTranscript
        }

        recordingState = .saving
        let id = UUID()
        let header = VoiceProfileHeader(
            id: id,
            name: name.isEmpty ? "My Voice" : name,
            createdAt: .now,
            durationSeconds: result.durationSeconds,
            sampleRate: 24000,
            sampleCount: result.samples.count,
            quality: result.quality,
            formatVersion: 1
        )
        let profile = VoiceProfile(
            header: header,
            samples: result.samples,
            transcript: trimmed
        )
        do {
            try await profileStore.save(profile: profile)
            await loadProfiles()
            if makeActive { setActiveProfile(id) }
            recordingState = .idle
            completedSaves += 1
            logger.info("Saved voice profile '\(name)' (\(id))")
        } catch {
            recordingState = .error(error.localizedDescription)
            throw error
        }
    }

    func discardAndReRecord() {
        recordingState = .idle
    }

    // MARK: - Management

    func delete(id: UUID) async throws {
        try await profileStore.delete(id: id)
        if activeProfileId == id {
            setActiveProfile(nil)
        }
        await loadProfiles()
    }

    func rename(id: UUID, newName: String) async throws {
        try await profileStore.updateName(newName, for: id)
        await loadProfiles()
    }

    // MARK: - Active Profile Selection

    func setActiveProfile(_ id: UUID?) {
        activeProfileId = id
        if let id {
            defaults.set(id.uuidString, forKey: Self.activeProfileKey)
        } else {
            defaults.removeObject(forKey: Self.activeProfileKey)
        }
    }

    // MARK: - Load full profile (for F7.2 inference)

    func loadFullProfile(id: UUID) async throws -> VoiceProfile {
        try await profileStore.load(id: id)
    }

    // MARK: - Private: Elapsed Timer

    private func startElapsedTimer() {
        let clock = clock
        // Two starts resuming from one permission prompt must not leave two timers running.
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.elapsedTicks += 1
                self.recordingState = .recording(elapsedSeconds: Float(self.elapsedTicks) / 10)
                // Auto-stop at the mode's limit (P5)
                if self.elapsedTicks >= Int((self.recordingMode.maxSeconds * 10).rounded()) {
                    await self.finishRecording(reachedLimit: true)
                    return
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }
}
