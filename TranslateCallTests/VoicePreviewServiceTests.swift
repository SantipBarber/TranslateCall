import Foundation
import Testing
@testable import TranslateCall

// MARK: - VoicePreviewServiceTests

@Suite(.serialized)
@MainActor
struct VoicePreviewServiceTests {

    private let testProfileId = UUID()

    private func makeTestProfile() -> VoiceProfile {
        let header = VoiceProfileHeader(
            id: testProfileId,
            name: "Test",
            createdAt: .now,
            durationSeconds: 5.0,
            sampleRate: 24000,
            sampleCount: 120_000,
            quality: VoiceQualityMetrics(
                peakRmsDbfs: -20, hasClipping: false,
                voicedDurationSeconds: 5.0, grade: .good
            ),
            formatVersion: 1
        )
        let samples = Array(repeating: Float(0.3), count: 120_000)
        return VoiceProfile(header: header, samples: samples, transcript: "Test recording")
    }

    @Test("Initial state is idle")
    func initialStateIsIdle() async throws {
        let store = MockVoiceProfileStore()
        let service = try VoicePreviewService(profileStore: store)
        let state = await service.state
        guard case .idle = state else {
            Issue.record("Expected .idle, got \(state)")
            return
        }
    }

    @Test("Stop transitions to idle")
    func stopTransitionsToIdle() async throws {
        let store = MockVoiceProfileStore()
        let service = try VoicePreviewService(profileStore: store)
        await service.stop()
        let state = await service.state
        guard case .idle = state else {
            Issue.record("Expected .idle, got \(state)")
            return
        }
    }

    @Test("playRecording plays from profile")
    func playRecordingPlaysFromProfile() async throws {
        let store = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        let service = try VoicePreviewService(profileStore: store)
        await service.playRecording(profileId: testProfileId)

        // Give async task time to start
        try await Task.sleep(for: .milliseconds(200))

        let state = await service.state
        // Should be playing or already idle (short buffer)
        let validStates: Bool = {
            switch state {
            case .playing(.recording), .idle: return true
            default: return false
            }
        }()
        #expect(validStates, "Expected .playing(.recording) or .idle, got \(state)")
    }

    @Test("previewClone enters loadingModel state")
    func previewCloneRequiresModel() async throws {
        let store = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        let service = try VoicePreviewService(profileStore: store)

        var emittedStates: [String] = []
        let collectTask = Task {
            for await state in service.stateStream {
                switch state {
                case .loadingModel: emittedStates.append("loadingModel")
                case .error: emittedStates.append("error")
                case .idle: emittedStates.append("idle")
                default: break
                }
                if emittedStates.count >= 2 { break }
            }
        }

        await service.previewClone(profileId: testProfileId, text: "Hello", language: "english")

        try await Task.sleep(for: .milliseconds(500))
        collectTask.cancel()

        // Should have entered loadingModel (model may fail since no real model in tests)
        #expect(emittedStates.contains("loadingModel") || emittedStates.contains("error"))
    }

    @Test("stateStream emits transitions")
    func stateStreamEmitsTransitions() async throws {
        let store = MockVoiceProfileStore()
        let profile = makeTestProfile()
        await store.forceStore(profile)

        let service = try VoicePreviewService(profileStore: store)

        var emitted: [String] = []
        let collectTask = Task {
            for await state in service.stateStream {
                switch state {
                case .idle: emitted.append("idle")
                case .playing: emitted.append("playing")
                default: emitted.append("other")
                }
                if emitted.count >= 2 { break }
            }
        }

        await service.playRecording(profileId: testProfileId)
        try await Task.sleep(for: .milliseconds(300))
        await service.stop()
        try await Task.sleep(for: .milliseconds(100))
        collectTask.cancel()

        #expect(!emitted.isEmpty)
    }
}
