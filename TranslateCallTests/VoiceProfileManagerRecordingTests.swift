import Foundation
import Testing
@testable import TranslateCall

/// A recorder with no microphone: `start` can be held at the permission prompt.
private final class FakeVoiceRecorder: VoiceRecording, @unchecked Sendable {
    let levelStream = AsyncStream<Float> { _ in }
    let startGate: AsyncGate?
    init(startGate: AsyncGate? = nil) { self.startGate = startGate }

    func startRecording() async throws { await startGate?.wait() }

    func stopRecording(mode: RecordingMode) async throws -> RecordingResult {
        RecordingResult(
            samples: [0.1, 0.2], durationSeconds: 8,
            quality: VoiceQualityMetrics(peakRmsDbfs: -18, hasClipping: false, voicedDurationSeconds: 8, grade: .good)
        )
    }
}

@Suite @MainActor
struct VoiceProfileManagerRecordingTests {
    private func makeManager(
        recorder: FakeVoiceRecorder = FakeVoiceRecorder(),
        store: MockVoiceProfileStore = MockVoiceProfileStore(),
        clock: TestClock = TestClock()
    ) -> VoiceProfileManager {
        VoiceProfileManager(store: store, recorder: recorder, defaults: UserDefaults(suiteName: UUID().uuidString)!,
                            clock: clock)
    }

    /// Ticks the manager's 100 ms timer until it leaves `.recording`.
    private func runTimerToEnd(_ manager: VoiceProfileManager, _ clock: TestClock) async {
        for _ in 0 ..< 400 where manager.recordingState.isRecording {
            _ = await waitUntil { clock.sleeperCount == 1 || !manager.recordingState.isRecording }
            clock.advance(by: .milliseconds(100))
        }
        _ = await waitUntil { manager.recordingState.reviewingResult != nil }
    }

    @Test("a guided recording that runs to the limit auto-stops and is flagged reachedLimit")
    func autoStopSetsFlag() async {
        let clock = TestClock()
        let manager = makeManager(clock: clock)
        await manager.startRecording(mode: .guided(language: "english"))
        await runTimerToEnd(manager, clock)
        #expect(manager.recordingState.reviewingResult?.reachedLimit == true)
    }

    @Test("a manual stop does not set reachedLimit")
    func manualStopLeavesFlagOff() async {
        let manager = makeManager()
        await manager.startRecording(mode: .guided(language: "english"))
        await manager.stopRecording()
        #expect(manager.recordingState.reviewingResult?.reachedLimit == false)
    }

    @Test("the timer starts only after the recorder started: not while the permission prompt is open")
    func timerWaitsForPermission() async {
        let clock = TestClock()
        let gate = AsyncGate()
        let manager = makeManager(recorder: FakeVoiceRecorder(startGate: gate), clock: clock)
        let starting = Task { await manager.startRecording(mode: .free) }
        #expect(await waitUntil { gate.waiterCount == 1 })
        #expect(clock.sleeperCount == 0)
        gate.open()
        await starting.value
        #expect(await waitUntil { clock.sleeperCount == 1 })
        await manager.stopRecording()
    }

    @Test("a completed save is signalled once; a failed save is not")
    func saveSignal() async throws {
        let store = MockVoiceProfileStore()
        let manager = makeManager(store: store)
        await manager.startRecording(mode: .free)
        await manager.stopRecording()
        let result = try #require(manager.recordingState.reviewingResult)
        #expect(manager.completedSaves == 0)

        await store.setShouldThrowOnSave(VoiceProfileError.encryptionFailed)
        _ = try? await manager.saveProfile(name: "A", transcript: "Hi", result: result)
        #expect(manager.completedSaves == 0, "a failed save must not close the sheet")

        await store.setShouldThrowOnSave(nil)
        try await manager.saveProfile(name: "A", transcript: "Hi", result: result)
        #expect(manager.completedSaves == 1)
        #expect(manager.recordingState.isIdle)
    }

    @Test("the review messages: limit warning only for a guided reading; too-short copy per mode")
    func reviewCopy() {
        let guided = RecordingMode.guided(language: "english")
        #expect(VoiceReviewCopy.showsLimitWarning(mode: guided, reachedLimit: true))
        #expect(!VoiceReviewCopy.showsLimitWarning(mode: guided, reachedLimit: false))
        #expect(!VoiceReviewCopy.showsLimitWarning(mode: .free, reachedLimit: true))
        #expect(VoiceReviewCopy.limitReached(seconds: 15).contains("15-second"))

        let target = Int(QwenCloneConfiguration.guidedTargetSeconds)
        let shortGuided = VoiceReviewCopy.tooShort(mode: guided, voicedSeconds: 3.26)
        #expect(shortGuided.contains("3.3s") && shortGuided.contains("calm pace") && shortGuided.contains("\(target) seconds"))
        let shortFree = VoiceReviewCopy.tooShort(mode: .free, voicedSeconds: 3.26)
        #expect(shortFree.contains("3.3s") && shortFree.contains("more speech"))
    }
}
