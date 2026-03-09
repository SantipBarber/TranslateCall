import Combine
import SwiftUI
@preconcurrency import Translation

// MARK: - PendingOperation

enum PendingOperation {
    case translate(text: String, continuation: CheckedContinuation<String, Error>)
    case prepare(continuation: CheckedContinuation<Void, Error>)
}

// MARK: - TranslationBridgeModel

/// Mediates between actor-based services and the SwiftUI `.translationTask()` modifier.
/// `TranslationSession` is only accessible inside `.translationTask()` — this model
/// queues pending operations and delivers results back via `CheckedContinuation`.
@MainActor
final class TranslationBridgeModel: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private var pendingOperation: PendingOperation?
    private var currentSource: Locale.Language?
    private var currentTarget: Locale.Language?

    // MARK: - Enqueue (called from AppleTranslationService via Task @MainActor)

    func enqueue(_ operation: PendingOperation, from source: Locale.Language, to target: Locale.Language) {
        // Fail any existing pending operation before replacing it
        if let existing = pendingOperation {
            failOperation(existing, with: TranslationError.bridgeUnavailable)
            pendingOperation = nil
        }
        pendingOperation = operation

        let sameSource = currentSource.map { $0 == source } ?? false
        let sameTarget = currentTarget.map { $0 == target } ?? false

        if sameSource && sameTarget {
            // Same language pair — invalidate to re-trigger the task
            configuration?.invalidate()
        } else {
            currentSource = source
            currentTarget = target
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    // MARK: - Session callback (called from TranslationBridge view's .translationTask closure)

    func sessionFired(_ session: TranslationSession) async {
        guard let operation = pendingOperation else { return }
        pendingOperation = nil

        switch operation {
        case .translate(let text, let continuation):
            do {
                let response = try await session.translate(text)
                continuation.resume(returning: response.targetText)
            } catch {
                continuation.resume(throwing: TranslationError.sessionError(error))
            }

        case .prepare(let continuation):
            do {
                try await session.prepareTranslation()
                continuation.resume()
            } catch {
                continuation.resume(throwing: TranslationError.sessionError(error))
            }
        }
    }

    // MARK: - Private

    private func failOperation(_ operation: PendingOperation, with error: Error) {
        switch operation {
        case .translate(_, let cont): cont.resume(throwing: error)
        case .prepare(let cont):      cont.resume(throwing: error)
        }
    }
}

// MARK: - TranslationBridge View

/// Invisible view anchoring `.translationTask()` in the SwiftUI window hierarchy.
/// Required by Apple Translation framework — `TranslationSession` is only available
/// via this modifier; there is no public initializer.
struct TranslationBridge: View {
    @EnvironmentObject private var model: TranslationBridgeModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.configuration) { session in
                await model.sessionFired(session)
            }
    }
}
