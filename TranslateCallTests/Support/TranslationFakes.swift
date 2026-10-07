import Foundation
@testable import TranslateCall

/// Scripted `TranslationSessioning` (F8.5.4 NFR-TR-03): no Translation framework in unit tests.
/// Each `translatedText` call takes the next step of `script`; with no step left it answers "EN:<text>".
@MainActor
final class FakeTranslationSession: TranslationSessioning {
    enum Step {
        case answer(String)
        case fail(Error)
        /// Waits for `release(with:)`; a cancelled caller gets `CancellationError` (like a real session).
        case hang
        /// Waits for `release(with:)` even when cancelled (a session that answers late).
        case hangIgnoringCancel
    }

    var script: [Step] = []
    var prepareError: Error?
    private(set) var translated: [String] = []
    private(set) var prepareCount = 0
    private var hung: [UInt64: CheckedContinuation<String, Error>] = [:]
    private var nextHungID: UInt64 = 0

    var hungCount: Int { hung.count }

    func translatedText(for text: String) async throws -> String {
        translated.append(text)
        let step = script.isEmpty ? .answer("EN:\(text)") : script.removeFirst()
        switch step {
        case .answer(let answer):
            return answer
        case .fail(let error):
            throw error
        case .hang:
            nextHungID += 1
            let id = nextHungID
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { hung[id] = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.hung.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        case .hangIgnoringCancel:
            nextHungID += 1
            let id = nextHungID
            return try await withCheckedThrowingContinuation { hung[id] = $0 }
        }
    }

    /// Answers every call still waiting.
    func release(with answer: String) {
        let waiting = hung
        hung.removeAll()
        waiting.values.forEach { $0.resume(returning: answer) }
    }

    func prepare() async throws {
        prepareCount += 1
        if let prepareError { throw prepareError }
    }
}
