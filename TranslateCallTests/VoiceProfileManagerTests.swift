import Foundation
import Testing
@testable import TranslateCall

@Suite @MainActor
struct VoiceProfileManagerTests {

    private func makeManager(
        suite: String = UUID().uuidString,
        mockStore: MockVoiceProfileStore = MockVoiceProfileStore()
    ) -> (VoiceProfileManager, MockVoiceProfileStore) {
        let defaults = UserDefaults(suiteName: suite)!
        let recorder = VoiceProfileRecorder(isSessionActive: { false })
        let manager = VoiceProfileManager(
            store: mockStore, recorder: recorder, defaults: defaults
        )
        return (manager, mockStore)
    }

    private func makeTestProfile(
        id: UUID = UUID(),
        name: String = "Test"
    ) -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: id,
            name: name,
            createdAt: .now,
            durationSeconds: 1.0,
            sampleRate: 24000,
            sampleCount: 24000,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18,
                hasClipping: false,
                voicedDurationSeconds: 1.0,
                grade: .good
            ),
            formatVersion: 1
        )
        return VoiceProfile(
            header: header,
            samples: Array(repeating: 0.5, count: 24000),
            transcript: "Hello"
        )
    }

    private func makeResult() -> RecordingResult {
        RecordingResult(
            samples: Array(repeating: 0.5, count: 24000),
            durationSeconds: 1.0,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -18,
                hasClipping: false,
                voicedDurationSeconds: 1.0,
                grade: .good
            )
        )
    }

    // MARK: - Tests

    @Test func activeProfilePersistedAndRestored() async throws {
        let suite = UUID().uuidString
        let mockStore = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await mockStore.forceStore(profile)

        let (manager1, _) = makeManager(suite: suite, mockStore: mockStore)
        try await Task.sleep(for: .milliseconds(100))
        manager1.setActiveProfile(profile.header.id)

        // Simulate relaunch with same suite + store
        let defaults2 = UserDefaults(suiteName: suite)!
        let manager2 = VoiceProfileManager(
            store: mockStore,
            recorder: VoiceProfileRecorder(isSessionActive: { false }),
            defaults: defaults2
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager2.activeProfileId == profile.header.id)
    }

    @Test func activeProfileResetWhenFileMissing() async throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let missingId = UUID()
        defaults.set(missingId.uuidString, forKey: "tlk.voiceCloning.activeProfileId")

        let mockStore = MockVoiceProfileStore()
        let manager = VoiceProfileManager(
            store: mockStore,
            recorder: VoiceProfileRecorder(isSessionActive: { false }),
            defaults: defaults
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.activeProfileId == nil)
    }

    @Test func deleteResetsActiveProfile() async throws {
        let mockStore = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await mockStore.forceStore(profile)

        let (manager, _) = makeManager(mockStore: mockStore)
        try await Task.sleep(for: .milliseconds(100))
        manager.setActiveProfile(profile.header.id)
        #expect(manager.activeProfileId == profile.header.id)

        try await manager.delete(id: profile.header.id)
        #expect(manager.activeProfileId == nil)
    }

    @Test func saveRequiresTranscript() async throws {
        let (manager, _) = makeManager()
        do {
            try await manager.saveProfile(
                name: "Test", transcript: "", result: makeResult()
            )
            Issue.record("Expected emptyTranscript error")
        } catch is VoiceProfileValidationError {
            // Expected
        }
    }

    @Test func saveRequiresNonWhitespaceTranscript() async throws {
        let (manager, _) = makeManager()
        do {
            try await manager.saveProfile(
                name: "Test", transcript: "   \n  ", result: makeResult()
            )
            Issue.record("Expected emptyTranscript error")
        } catch is VoiceProfileValidationError {
            // Expected
        }
    }

    @Test func saveSucceedsWithValidTranscript() async throws {
        let mockStore = MockVoiceProfileStore()
        let (manager, _) = makeManager(mockStore: mockStore)
        try await manager.saveProfile(
            name: "My Voice", transcript: "Hello world", result: makeResult()
        )
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.profiles.count == 1)
        #expect(manager.profiles.first?.name == "My Voice")
    }

    @Test func saveFailureReportsError() async throws {
        let mockStore = MockVoiceProfileStore()
        await mockStore.setShouldThrowOnSave(VoiceProfileError.encryptionFailed)
        let (manager, _) = makeManager(mockStore: mockStore)
        do {
            try await manager.saveProfile(
                name: "Test", transcript: "Hi", result: makeResult()
            )
            Issue.record("Expected save to throw")
        } catch is VoiceProfileError {
            // Expected
        }
    }

    @Test func activeProfileReturnsCorrectHeader() async throws {
        let mockStore = MockVoiceProfileStore()
        let profile = makeTestProfile(name: "Active Voice")
        await mockStore.forceStore(profile)
        let (manager, _) = makeManager(mockStore: mockStore)
        try await Task.sleep(for: .milliseconds(100))
        manager.setActiveProfile(profile.header.id)
        #expect(manager.activeProfile?.name == "Active Voice")
    }

    @Test func activeProfileNilWhenNoneSelected() async throws {
        let (manager, _) = makeManager()
        try await Task.sleep(for: .milliseconds(100))
        #expect(manager.activeProfile == nil)
    }

    @Test func discardResetsToIdle() {
        let (manager, _) = makeManager()
        manager.discardAndReRecord()
        #expect(manager.recordingState.isIdle)
    }

    @Test func initialStateIsIdle() {
        let (manager, _) = makeManager()
        #expect(manager.recordingState.isIdle)
    }
}
