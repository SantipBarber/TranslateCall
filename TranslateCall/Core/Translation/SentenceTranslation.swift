import Foundation

/// One finished utterance split into clauses, with one running translation task per part
/// (QS-5, design §3). Tasks are created in `init` in part order, so the first part starts
/// translating before the second exists; cancelling the sentence cancels every part.
@MainActor
final class SentenceTranslation {
    typealias Translate = @MainActor (String) async throws -> String

    let source: String
    let parts: [String]                  // 1 or 2
    let tasks: [Task<String, Error>]     // one per part, started in order

    var isSplit: Bool { parts.count > 1 }

    /// Splits `text` when `split` is on; otherwise the whole text is the single part.
    init(_ text: String, split: Bool, translate: @escaping Translate) {
        source = text
        parts = split ? ClauseSplitter.split(text) : [text]
        tasks = parts.map { part in Task { try await translate(part) } }
    }

    /// One part around an already started task (callers holding a Task).
    init(source: String, task: Task<String, Error>) {
        self.source = source
        parts = [source]
        tasks = [task]
    }

    func cancel() { tasks.forEach { $0.cancel() } }
}
