import Combine
import Foundation
import OSLog

private nonisolated(unsafe) let logger = Logger(
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

    var activeProfile: VoiceProfileHeader? {
        profiles.first { $0.id == activeProfileId }
    }

    // MARK: - Dependencies (injectable)

    private let store: any VoiceProfileStoring
    let recorder: VoiceProfileRecorder
    private let defaults: UserDefaults
    private let isSessionActive: () -> Bool

    private static let activeProfileKey = "tlk.voiceCloning.activeProfileId"

    // MARK: - Elapsed timer

    private var elapsedTask: Task<Void, Never>?
    private var elapsedSeconds: Float = 0

    // MARK: - Init

    init(
        store: any VoiceProfileStoring = VoiceProfileStore(),
        recorder: VoiceProfileRecorder = VoiceProfileRecorder(),
        defaults: UserDefaults = .standard,
        isSessionActive: @escaping () -> Bool = { false }
    ) {
        self.store = store
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
            profiles = try await store.enumerateHeaders()
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

    func startRecording() async {
        guard !isSessionActive() else {
            recordingState = .error(VoiceProfileRecorderError.sessionConflict.localizedDescription)
            return
        }
        recordingState = .recording(elapsedSeconds: 0)
        elapsedSeconds = 0
        startElapsedTimer()
        do {
            try await recorder.startRecording()
        } catch {
            stopElapsedTimer()
            recordingState = .error(error.localizedDescription)
        }
    }

    func stopRecording() async {
        stopElapsedTimer()
        recordingState = .processing
        do {
            let result = try await recorder.stopRecording()
            recordingState = .reviewing(result)
        } catch {
            recordingState = .error(error.localizedDescription)
        }
    }

    // MARK: - Save Flow

    func saveProfile(
        name: String,
        transcript: String,
        result: RecordingResult
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
            try await store.save(profile: profile)
            await loadProfiles()
            recordingState = .idle
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
        try await store.delete(id: id)
        if activeProfileId == id {
            setActiveProfile(nil)
        }
        await loadProfiles()
    }

    func rename(id: UUID, newName: String) async throws {
        try await store.updateName(newName, for: id)
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
        try await store.load(id: id)
    }

    // MARK: - Private: Elapsed Timer

    private func startElapsedTimer() {
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.elapsedSeconds += 0.1
                self.recordingState = .recording(elapsedSeconds: self.elapsedSeconds)
                // Auto-stop at 30 s
                if self.elapsedSeconds >= 30 {
                    await self.stopRecording()
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
