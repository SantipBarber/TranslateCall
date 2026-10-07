import Combine
import OSLog
import SwiftUI
@preconcurrency import Translation

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TranslationBridge")

// MARK: - TranslationSessioning

/// What the bridge and the download flow need from a `TranslationSession` (F8.5.4 design §1).
/// Unit tests fake it, so they never touch the Translation framework (NFR-TR-03).
protocol TranslationSessioning {
    func translatedText(for text: String) async throws -> String
    /// Downloads the pair's models if needed; may show the system sheet in the hosting window.
    func prepare() async throws
}

extension TranslationSession: TranslationSessioning {
    func translatedText(for text: String) async throws -> String {
        try await translate(text).targetText
    }

    func prepare() async throws {
        try await prepareTranslation()
    }
}

// MARK: - TranslationBridgeModel

/// One translation direction's link to Apple Translation (F8.5.4 design §2).
///
/// `TranslationSession` only exists inside `.translationTask`, so `TranslationBridge` hands each
/// session to `run(session:)`, which keeps it and serves queued requests in order until the
/// configuration changes. The configuration changes only when the pair changes or on `warmUp` —
/// never per sentence (T4).
@MainActor
final class TranslationBridgeModel: ObservableObject {
    struct Pair: Equatable, Sendable {
        let source: Locale.Language
        let target: Locale.Language
    }

    @Published private(set) var configuration: TranslationSession.Configuration?

    private final class Request {
        let id: UInt64
        let text: String
        let pair: Pair
        /// Nil once resumed: every request is resumed exactly once (NFR-TR-02).
        var continuation: CheckedContinuation<String, Error>?

        init(id: UInt64, text: String, pair: Pair, continuation: CheckedContinuation<String, Error>) {
            self.id = id
            self.text = text
            self.pair = pair
            self.continuation = continuation
        }
    }

    /// FIFO; the head is the request being served (REQ-TR-03).
    private var queue: [Request] = []
    private var nextID: UInt64 = 0
    /// Pair of `configuration`.
    private var livePair: Pair?
    /// Bumped whenever `configuration` changes; a run loop of an older session stops.
    private var sessionGeneration: UInt64 = 0
    /// Run loops parked on an empty queue.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Requests waiting or in flight (tests).
    var queuedCount: Int { queue.count }

    // MARK: - API

    /// Translates `text` once a session for its pair is running. Cancelling the calling task removes
    /// the request and throws `CancellationError` (REQ-TR-13).
    func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        try Task.checkCancellation()
        nextID &+= 1
        let id = nextID
        let pair = Pair(source: source, target: target)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.append(Request(id: id, text: text, pair: pair, continuation: continuation))
                if queue.count == 1 { ensureSession(for: pair) }
                wakeRunLoops()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelRequest(id) }
        }
    }

    /// Opens a session for `pair` and translates `warmUpProbe` on it, so the model is loaded before the
    /// first sentence (REQ-TR-05: opening a session alone does not load it). No-op while requests are queued.
    func warmUp(from source: Locale.Language, to target: Locale.Language) {
        guard queue.isEmpty else { return }
        ensureSession(for: Pair(source: source, target: target))
        Task { _ = try? await translate(Self.warmUpProbe, from: source, to: target) }
    }

    /// Translated (and discarded) by `warmUp`.
    static let warmUpProbe = "OK"

    /// Called by `TranslationBridge` with each session SwiftUI creates. Returns when the session is
    /// replaced (pair change) or its task is cancelled.
    func run(session: some TranslationSessioning) async {
        let generation = sessionGeneration
        while generation == sessionGeneration, !Task.isCancelled {
            guard let head = queue.first else {
                await parkUntilWork()
                continue
            }
            guard head.pair == livePair else {
                ensureSession(for: head.pair)   // REQ-TR-04: the next session serves it
                return
            }
            do {
                let text = try await session.translatedText(for: head.text)
                finish(head.id, with: .success(text))   // also accepted from a replaced session
            } catch {
                // Replaced or cancelled mid-flight: the request stays queued for the next session (REQ-TR-03).
                guard generation == sessionGeneration, !Task.isCancelled else { return }
                logger.error("Translation failed — \(error.localizedDescription, privacy: .public)")
                finish(head.id, with: .failure(TranslationError.sessionError(error)))
            }
        }
    }

    // MARK: - Session lifecycle

    private func ensureSession(for pair: Pair) {
        guard pair != livePair || configuration == nil else { return }
        livePair = pair
        configuration = TranslationSession.Configuration(source: pair.source, target: pair.target)
        sessionGeneration &+= 1
        wakeRunLoops()
    }

    private func parkUntilWork() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wakeRunLoops() }
        }
    }

    private func wakeRunLoops() {
        let parked = waiters
        waiters.removeAll()
        parked.forEach { $0.resume() }
    }

    // MARK: - Completion

    private func finish(_ id: UInt64, with result: Result<String, Error>) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let request = queue.remove(at: index)
        request.continuation?.resume(with: result)
        request.continuation = nil
    }

    private func cancelRequest(_ id: UInt64) {
        finish(id, with: .failure(CancellationError()))
    }
}

// MARK: - TranslationBridge View

/// Invisible view anchoring `.translationTask()`; `TranslationSession` has no public initializer on
/// macOS 15. Each new configuration makes SwiftUI cancel the running task and call `run` again.
struct TranslationBridge: View {
    @ObservedObject private var model: TranslationBridgeModel

    init(model: TranslationBridgeModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(model.configuration) { session in
                await model.run(session: session)
            }
    }
}
