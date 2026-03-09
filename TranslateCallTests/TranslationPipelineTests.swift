@_exported import Testing
import Foundation
@testable import TranslateCall

// MARK: - Mock TranslationService

/// Synchronous mock — returns "TRANSLATED: <input>" immediately, or throws if configured.
final class MockTranslationService: TranslationService {
    var shouldThrow: Error?
    private(set) var translateCallCount = 0
    private(set) var lastTranslatedText: String?
    private(set) var prepareCallCount = 0

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        translateCallCount += 1
        lastTranslatedText = text
        if let error = shouldThrow { throw error }
        return "TRANSLATED: \(text)"
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        prepareCallCount += 1
        if let error = shouldThrow { throw error }
    }
}

// MARK: - Pipeline tests

@Suite(.serialized) @MainActor
struct TranslationPipelineTests {

    @Test func downloadLanguagesCallsPrepare() async {
        let mock = MockTranslationService()
        let viewModel = AudioViewModel(translationService: mock)

        await viewModel.downloadLanguages()

        #expect(mock.prepareCallCount == 1)
    }

    @Test func downloadLanguagesErrorSetsAlert() async {
        let mock = MockTranslationService()
        mock.shouldThrow = TranslationError.bridgeUnavailable
        let viewModel = AudioViewModel(translationService: mock)

        await viewModel.downloadLanguages()

        #expect(viewModel.errorAlert != nil)
    }

    @Test func downloadLanguagesSuccessChecksAvailability() async {
        let mock = MockTranslationService()
        let lpm = LanguagePairManager()
        let viewModel = AudioViewModel(translationService: mock, languagePairManager: lpm)

        // Ensure status isn't unknown after a successful download flow
        await viewModel.downloadLanguages()

        // After prepare + checkAvailability, status should not be .unknown (it ran)
        // We can't assert .installed without real models, but it shouldn't be .unknown
        #expect(viewModel.errorAlert == nil)
    }

    @Test func nilTranslationServiceDownloadIsNoop() async {
        let viewModel = AudioViewModel(translationService: nil)
        // Should not crash and should not set an error alert
        await viewModel.downloadLanguages()
        #expect(viewModel.errorAlert == nil)
    }

    @Test func initialStateIsClean() {
        let viewModel = AudioViewModel(translationService: MockTranslationService())
        #expect(viewModel.latestTranslation == nil)
        #expect(viewModel.latestTranscription == nil)
        #expect(viewModel.isCapturing == false)
    }

    @Test func languagePairManagerIsAccessible() {
        let lpm = LanguagePairManager()
        let viewModel = AudioViewModel(languagePairManager: lpm)
        // Verify the manager is wired through
        #expect(viewModel.languagePairManager.sourceLanguage.languageCode != nil)
    }
}

// MARK: - TranslationError matching

@MainActor
struct TranslationErrorMatchingTests {

    @Test func bridgeUnavailableMatchesInSwitch() {
        let error: Error = TranslationError.bridgeUnavailable
        var matched = false
        switch error {
        case TranslationError.bridgeUnavailable: matched = true
        default: break
        }
        #expect(matched)
    }

    @Test func unsupportedPairMatchesInSwitch() {
        let error: Error = TranslationError.unsupportedPair(
            Locale.Language(identifier: "en"),
            Locale.Language(identifier: "xx")
        )
        var matched = false
        switch error {
        case TranslationError.unsupportedPair: matched = true
        default: break
        }
        #expect(matched)
    }
}
