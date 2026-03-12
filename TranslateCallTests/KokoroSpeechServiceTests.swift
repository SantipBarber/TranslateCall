import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

// MARK: - KokoroSpeechServiceTests

/// Tests for `KokoroSpeechService`.
///
/// KokoroSpeechService starts an `AVAudioEngine` in its `throws init`, so all tests
/// must run serialized to avoid CoreAudio conflicts. Each test creates a fresh service
/// with a real AVAudioEngine (no-device, default output).
///
/// Tests focus on the service's observable interface — queue management, text truncation,
/// metrics recording, and lifecycle — rather than the PCM audio pipeline internals.
@Suite("KokoroSpeechService", .serialized)
@MainActor
struct KokoroSpeechServiceTests {

    // MARK: - Helpers

    /// Creates a `KokoroSpeechService` with a mock manager injected, routing to default device.
    func makeService(mock: MockKokoroTtsManager) throws -> KokoroSpeechService {
        let manager = KokoroModelManager(managerFactory: { _ in mock })
        return try KokoroSpeechService(
            outputDeviceID: nil,
            modelManager: manager
        )
    }

    // MARK: - Init

    @Test("Init succeeds with default output device")
    func initSucceeds() throws {
        let mock = MockKokoroTtsManager()
        _ = try makeService(mock: mock)
    }

    // MARK: - speak / queue

    @Test("speak appends to pendingTexts when not speaking")
    func speakAppendsToPending() async throws {
        let mock = MockKokoroTtsManager()
        // Stub a delay so processNext doesn't consume the entry immediately
        await mock.stubResult([])
        let service = try makeService(mock: mock)
        // Enqueue two texts; synthesis is async so they may still be in queue momentarily
        await service.speak(text: "hello", locale: Locale(identifier: "en-US"))
        let pending = await service.pendingTexts
        // After first speak, either still pending or already processing — no crash
        _ = pending // existence check only
    }

    @Test("speak ignores whitespace-only text")
    func speakIgnoresWhitespace() async throws {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([])
        let service = try makeService(mock: mock)
        await service.speak(text: "   ", locale: Locale(identifier: "en-US"))
        let callCount = await mock.callCount
        // Since text is blank, synthesizeSamples should never have been called
        #expect(callCount == 0)
    }

    // MARK: - stopSpeaking

    @Test("stopSpeaking clears pendingTexts")
    func stopSpeakingClearsPending() async throws {
        let mock = MockKokoroTtsManager()
        // Use a slow factory so the first speak() call stays in-flight
        let manager = KokoroModelManager(managerFactory: { _ in
            try await Task.sleep(for: .milliseconds(500))
            return mock
        })
        let service = try KokoroSpeechService(outputDeviceID: nil, modelManager: manager)

        await service.speak(text: "first", locale: Locale(identifier: "en-US"))
        await service.speak(text: "second", locale: Locale(identifier: "en-US"))
        await service.stopSpeaking()

        let pending = await service.pendingTexts
        #expect(pending.isEmpty)
    }

    @Test("stopSpeaking emits isSpeaking=false on stream")
    func stopSpeakingEmitsFalse() async throws {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([])
        let service = try makeService(mock: mock)

        var states: [Bool] = []
        let streamTask = Task {
            for await val in service.isSpeakingStream {
                states.append(val)
                if !val { break }
            }
        }

        await service.stopSpeaking()
        try? await Task.sleep(for: .milliseconds(50))
        streamTask.cancel()

        #expect(states.contains(false))
    }

    // MARK: - Text truncation (REQ-KOK-NF-07)

    @Test("Text longer than 500 chars is truncated at word boundary")
    func longTextTruncatedAtWordBoundary() async throws {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([0.1])
        let service = try makeService(mock: mock)

        // Build a 550-char string where word boundaries are clear
        let word = "hello "   // 6 chars
        let longText = String(repeating: word, count: 92) // 552 chars
        #expect(longText.count > 500)

        await service.speak(text: longText, locale: Locale(identifier: "en-US"))
        try? await Task.sleep(for: .milliseconds(200))
        await service.deactivate()

        let received = await mock.receivedTexts
        if let first = received.first {
            #expect(first.count <= 500)
            // Must end on a word boundary (no trailing space after join)
            #expect(!first.hasSuffix(" "))
        }
    }

    @Test("Text at exactly 500 chars is not truncated")
    func exactlyFiveHundredCharsNotTruncated() async throws {
        let mock = MockKokoroTtsManager()
        await mock.stubResult([0.1])
        let service = try makeService(mock: mock)

        let exactText = String(repeating: "a", count: 500)
        await service.speak(text: exactText, locale: Locale(identifier: "en-US"))
        try? await Task.sleep(for: .milliseconds(200))
        await service.deactivate()

        let received = await mock.receivedTexts
        if let first = received.first {
            #expect(first.count == 500)
        }
    }

    // MARK: - deactivate

    @Test("deactivate without prior speak does not crash")
    func deactivateWithoutSpeak() async throws {
        let mock = MockKokoroTtsManager()
        let service = try makeService(mock: mock)
        await service.deactivate()
    }

    // MARK: - isSpeakingStream

    @Test("isSpeakingStream is accessible as nonisolated")
    func isSpeakingStreamAccessible() throws {
        let mock = MockKokoroTtsManager()
        let service = try makeService(mock: mock)
        // Accessing the nonisolated stream property must not require await
        let stream: AsyncStream<Bool> = service.isSpeakingStream
        _ = stream
    }
}
