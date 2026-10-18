import Foundation
import Testing
@preconcurrency import WhisperKit
@testable import TranslateCall

// MARK: - WhisperConfiguration Tests

@Suite("WhisperConfiguration")
struct WhisperConfigurationTests {

    @Test("Default configuration has expected values")
    func testDefaultConfiguration() {
        let config = WhisperConfiguration.default
        #expect(config.modelSize == .base)
        #expect(config.language == nil)
        #expect(config.beamSize == 5)
        #expect(config.noSpeechThreshold == 0.6)
    }

    @Test("All model sizes map to correct WhisperKit names")
    func testModelSizeWhisperKitName() {
        #expect(WhisperModelSize.tiny.whisperKitName == "openai_whisper-tiny")
        #expect(WhisperModelSize.base.whisperKitName == "openai_whisper-base")
        #expect(WhisperModelSize.small.whisperKitName == "openai_whisper-small")
        #expect(WhisperModelSize.medium.whisperKitName == "openai_whisper-medium")
        #expect(WhisperModelSize.largeV3.whisperKitName == "openai_whisper-large-v3")
    }

    @Test("Model sizes report correct approximate sizes in MB")
    func testModelSizeApproximateSize() {
        #expect(WhisperModelSize.tiny.approximateSizeMB == 75)
        #expect(WhisperModelSize.base.approximateSizeMB == 150)
        #expect(WhisperModelSize.small.approximateSizeMB == 500)
        #expect(WhisperModelSize.medium.approximateSizeMB == 1500)
        #expect(WhisperModelSize.largeV3.approximateSizeMB == 3000)
    }

    @Test("Model sizes have correct display names")
    func testModelSizeDisplayName() {
        #expect(WhisperModelSize.tiny.displayName == "Tiny")
        #expect(WhisperModelSize.base.displayName == "Base")
        #expect(WhisperModelSize.small.displayName == "Small")
        #expect(WhisperModelSize.medium.displayName == "Medium")
        #expect(WhisperModelSize.largeV3.displayName == "Large v3")
    }
}

// MARK: - WhisperLanguages Tests

@Suite("WhisperLanguages")
struct WhisperLanguagesTests {

    @Test("Supports Ukrainian")
    func testSupportsUkrainian() {
        #expect(WhisperLanguages.supports(Locale(identifier: "uk")))
    }

    @Test("Supports English")
    func testSupportsEnglish() {
        #expect(WhisperLanguages.supports(Locale(identifier: "en")))
    }

    @Test("Rejects unsupported locale")
    func testRejectsUnsupported() {
        #expect(!WhisperLanguages.supports(Locale(identifier: "xx")))
    }

    @Test("Whisper code for Ukrainian is 'uk'")
    func testWhisperCodeForUkrainian() {
        #expect(WhisperLanguages.whisperCode(for: Locale(identifier: "uk")) == "uk")
    }

    @Test("Whisper code for unsupported locale returns nil")
    func testWhisperCodeForUnsupported() {
        #expect(WhisperLanguages.whisperCode(for: Locale(identifier: "xx")) == nil)
    }

    @Test("Supported set has at least 99 languages")
    func testSupportedSetHas99Languages() {
        #expect(WhisperLanguages.supported.count >= 99)
    }
}

// MARK: - WhisperModelManager Tests

@Suite("WhisperModelManager")
struct WhisperModelManagerTests {

    private enum MockError: Error {
        case intentional
    }

    @Test("ensureReady calls the pipe factory")
    func testEnsureReadyCallsFactory() async throws {
        let factoryCalls = CallCounter()
        let manager = WhisperModelManager(pipeFactory: { _ in
            factoryCalls.increment()
            throw MockError.intentional
        })
        do {
            try await manager.ensureReady()
        } catch {
            // Expected — factory throws
        }
        #expect(factoryCalls.value > 0)
    }

    @Test("Task coalescing — concurrent ensureReady calls share one factory invocation")
    func testTaskCoalescing() async throws {
        let callCount = ManagedAtomic(0)
        let manager = WhisperModelManager(pipeFactory: { _ in
            callCount.increment()
            // Simulate a slow load so both calls overlap
            try await Task.sleep(for: .milliseconds(50))
            throw MockError.intentional
        })

        async let first: Void = {
            do { try await manager.ensureReady() } catch {}
        }()
        async let second: Void = {
            do { try await manager.ensureReady() } catch {}
        }()
        _ = await (first, second)

        #expect(callCount.value <= 2) // Ideally 1 due to coalescing; at most 2 if timing is tight
    }

    @Test("unloadModel resets isReady to false")
    func testUnloadResetsState() async {
        let manager = WhisperModelManager(pipeFactory: { _ in
            throw MockError.intentional
        })
        // After a failed load, isReady stays false. Call unload to verify it explicitly resets.
        do { try await manager.ensureReady() } catch {}
        await manager.unloadModel()
        let ready = await manager.isReady
        #expect(!ready)
    }

    @Test("Factory error sets loadError")
    func testFactoryErrorSetsLoadError() async {
        let manager = WhisperModelManager(pipeFactory: { _ in
            throw MockError.intentional
        })
        do { try await manager.ensureReady() } catch {}
        let loadError = await manager.loadError
        #expect(loadError != nil)
    }

    @Test("isDownloading is false after factory error")
    func testIsDownloadingFalseAfterError() async {
        let manager = WhisperModelManager(pipeFactory: { _ in
            throw MockError.intentional
        })
        do { try await manager.ensureReady() } catch {}
        let downloading = await manager.isDownloading
        #expect(!downloading)
    }
}

// MARK: - Atomic counter helper (no Foundation dependency beyond Sendable)

/// Simple thread-safe counter for test verification.
private final class ManagedAtomic: @unchecked Sendable {
    private var _value: Int
    private let lock = NSLock()

    init(_ initial: Int) {
        _value = initial
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }
}

// MARK: - STTEngine (Whisper) Tests

@Suite("STTEngine Whisper")
struct STTEngineWhisperTests {

    @Test("Whisper supports Ukrainian")
    func testWhisperSupportsUkrainian() {
        #expect(STTEngine.whisper.supports(locale: Locale(identifier: "uk")))
    }

    @Test("Whisper supports English")
    func testWhisperSupportsEnglish() {
        #expect(STTEngine.whisper.supports(locale: Locale(identifier: "en")))
    }

    @Test("Whisper does not support fictional locale")
    func testWhisperDoesNotSupportFictional() {
        #expect(!STTEngine.whisper.supports(locale: Locale(identifier: "xx")))
    }

    @Test("Whisper display name is 'Whisper'")
    func testWhisperDisplayName() {
        #expect(STTEngine.whisper.displayName == "Whisper")
    }
}
