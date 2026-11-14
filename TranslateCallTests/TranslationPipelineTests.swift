@_exported import Testing
import Foundation
@testable import TranslateCall

// MARK: - Mock TranslationService

/// Returns "TRANSLATED: <input>" at once. `errors` are thrown one per call, in order, before
/// `shouldThrow` (thrown on every call) is considered.
final class MockTranslationService: TranslationService {
    var shouldThrow: Error?
    var errors: [Error] = []
    var supportsResult = true
    private(set) var translateCallCount = 0
    private(set) var lastTranslatedText: String?
    private(set) var warmUpCalls: [(source: Locale.Language, target: Locale.Language)] = []
    /// When set, the next `translate` waits here until `releaseHeld()` (a slow translation).
    /// Several can be held at once; `releaseHeld()` frees the oldest.
    var holdNext = false
    /// Texts whose calls are held like `holdNext` (kept in the set; every matching call holds, and
    /// `holdNext` is left for the next other call) until `releaseHeld()` frees the oldest,
    /// `releaseHeld(text)` that text's call, or the caller is cancelled (which frees that call only).
    var holdTexts: Set<String> = []
    /// Error thrown for its key text (checked before `errors` and `shouldThrow`).
    var failTexts: [String: Error] = [:]
    private var held: [(id: UUID, text: String, continuation: CheckedContinuation<Void, Never>)] = []
    /// Calls cancelled before their continuation was stored: resumed as soon as it is.
    private var cancelledIDs: Set<UUID> = []
    var isHolding: Bool { !held.isEmpty }
    var heldCount: Int { held.count }
    func releaseHeld() { if !held.isEmpty { held.removeFirst().continuation.resume() } }
    func releaseHeld(_ text: String) {
        guard let index = held.firstIndex(where: { $0.text == text }) else { return }
        held.remove(at: index).continuation.resume()
    }

    private func release(id: UUID) {
        guard let index = held.firstIndex(where: { $0.id == id }) else {
            cancelledIDs.insert(id)
            return
        }
        held.remove(at: index).continuation.resume()
    }

    private func hold(_ id: UUID, _ text: String, _ continuation: CheckedContinuation<Void, Never>) {
        if cancelledIDs.remove(id) != nil {
            continuation.resume()
        } else {
            held.append((id, text, continuation))
        }
    }

    func translate(text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        translateCallCount += 1
        lastTranslatedText = text
        let id = UUID()
        if holdTexts.contains(text) {
            // A cancelled caller must not wait for `releaseHeld()`; it frees its own call only.
            await withTaskCancellationHandler {
                await withCheckedContinuation { hold(id, text, $0) }
            } onCancel: {
                Task { @MainActor [weak self] in self?.release(id: id) }
            }
            try Task.checkCancellation()   // a cancelled translation does not return a result
        } else if holdNext {
            holdNext = false
            await withCheckedContinuation { hold(id, text, $0) }
            try Task.checkCancellation()
        }
        if let error = failTexts[text] { throw error }
        if !errors.isEmpty { throw errors.removeFirst() }
        if let error = shouldThrow { throw error }
        return "TRANSLATED: \(text)"
    }

    func warmUp(from source: Locale.Language, to target: Locale.Language) async {
        warmUpCalls.append((source, target))
    }

    func supports(source: Locale.Language, target: Locale.Language) async -> Bool { supportsResult }
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
        #expect(viewModel.coordinator.outgoingTranslation == nil)
        #expect(viewModel.coordinator.outgoingTranscription == nil)
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

    @Test func timedOutMatchesInSwitch() {
        let error: Error = TranslationError.timedOut
        var matched = false
        switch error {
        case TranslationError.timedOut: matched = true
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
