@_exported import Testing
import Foundation
@testable import TranslateCall

// MARK: - Mock TranslationService

/// Synchronous mock — returns "TRANSLATED: <input>" immediately, or throws if configured.
final class MockTranslationService: TranslationService {
    var shouldThrow: Error?
    private(set) var translateCallCount = 0
    private(set) var lastTranslatedText: String?

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        translateCallCount += 1
        lastTranslatedText = text
        if let error = shouldThrow { throw error }
        return "TRANSLATED: \(text)"
    }
}

// MARK: - Pipeline tests

@Suite(.serialized) @MainActor
struct TranslationPipelineTests {

    @Test("Download prepares the pair with the view's session (REQ-TR-40)")
    func downloadUsesSession() async {
        let viewModel = AudioViewModel(translationService: MockTranslationService(), conversationSettings: .forTesting())
        let session = FakeTranslationSession()

        await viewModel.downloadLanguages(using: session)

        #expect(session.prepareCount == 1)
        #expect(viewModel.errorAlert == nil)
    }

    @Test("a failed download shows an alert (REQ-TR-41)")
    func downloadErrorSetsAlert() async {
        let viewModel = AudioViewModel(translationService: MockTranslationService(), conversationSettings: .forTesting())
        let session = FakeTranslationSession()
        session.prepareError = TranslationError.networkUnavailable

        await viewModel.downloadLanguages(using: session)

        #expect(viewModel.errorAlert?.title == "Download Failed")
    }

    @Test("a cancelled download is silent")
    func downloadCancelledIsSilent() async {
        let viewModel = AudioViewModel(translationService: MockTranslationService(), conversationSettings: .forTesting())
        let session = FakeTranslationSession()
        session.prepareError = CancellationError()

        await viewModel.downloadLanguages(using: session)

        #expect(viewModel.errorAlert == nil)
    }

    @Test func initialStateIsClean() {
        let viewModel = AudioViewModel(translationService: MockTranslationService(), conversationSettings: .forTesting())
        #expect(viewModel.latestTranslation == nil)
        #expect(viewModel.latestTranscription == nil)
        #expect(viewModel.isCapturing == false)
    }

    @Test func languagePairManagerIsAccessible() {
        let lpm = LanguagePairManager()
        let viewModel = AudioViewModel(languagePairManager: lpm, conversationSettings: .forTesting())
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
