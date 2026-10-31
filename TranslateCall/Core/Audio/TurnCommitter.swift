import Foundation

/// Holds one direction's sentences between recognition and delivery (FR-QS.5, design §10.4).
///
/// A `.tentative` result is translated at once and held; it is delivered (shown and spoken) only
/// when its segment is committed, and dropped when it is retracted. A `.final` result is committed
/// on arrival and takes today's path: `deliver` gets no translation and starts it after its own
/// mute-turn and pause checks, so a dropped final is never translated (REQ-UI-50).
/// Results and boundaries come on separate streams, so either may arrive first: every piece of
/// state is keyed by segment id. Delivery is one serial loop in id order; the head waits
/// until it is committed and its text is known, and an empty text is skipped without blocking.
@MainActor
final class TurnCommitter {
    typealias Translate = @MainActor (String) async throws -> String
    /// `translation` is the held one for a tentative, nil for a final (`deliver` translates it).
    typealias Deliver = @MainActor (_ text: String, _ translation: Task<String, Error>?) async -> Void

    private struct Entry {
        let id: UInt64
        /// nil until the segment's result arrives (a commit came first).
        var text: String?
        /// Started on a non-empty tentative result; nil for a final and for empty text.
        var translation: Task<String, Error>?
        var committed: Bool
    }

    private let translate: Translate
    private let deliver: Deliver
    /// Held entries, in id order.
    private var entries: [Entry] = []
    /// Retracted before their result arrived: the late result is dropped, then the id forgotten.
    private var retractedIDs: Set<UInt64> = []
    private var deliveryTask: Task<Void, Never>?
    /// The translation being delivered now: cancelled by `cancelAll()` whatever `deliver` does.
    private var inFlight: Task<String, Error>?
    /// Set by `cancelAll()`: the direction is torn down, later input is ignored and the delivery
    /// loop stops at its next step.
    private var isCancelled = false

    /// Entries held (not yet delivered or dropped). For tests.
    var heldCount: Int { entries.count }

    init(translate: @escaping Translate, deliver: @escaping Deliver) {
        self.translate = translate
        self.deliver = deliver
    }

    func receive(_ result: TranscriptionResult) {
        guard !isCancelled else { return }
        let id = result.segmentID
        if retractedIDs.remove(id) != nil { return }
        let eager = result.kind == .tentative && !result.text.isEmpty
        let translation = eager ? startTranslation(of: result.text) : nil
        // A placeholder left by an early commit: fill it in.
        if let index = entries.firstIndex(where: { $0.id == id && $0.text == nil }) {
            entries[index].text = result.text
            entries[index].translation = translation
        } else {
            // After any entry with the same id: untagged sources (id 0) keep their arrival order.
            let entry = Entry(id: id, text: result.text, translation: translation, committed: result.kind == .final)
            entries.insert(entry, at: entries.firstIndex { $0.id > id } ?? entries.endIndex)
        }
        pump()
    }

    func receive(_ boundary: SegmentBoundary) {
        guard !isCancelled else { return }
        switch boundary {
        case .commit(let id):
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].committed = true
            } else {
                let entry = Entry(id: id, text: nil, translation: nil, committed: true)
                entries.insert(entry, at: entries.firstIndex { $0.id > id } ?? entries.endIndex)
            }
            pump()
        case .retract(let id):
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries.remove(at: index).translation?.cancel()
                pump()
            } else {
                retractedIDs.insert(id)
            }
        }
    }

    /// Cancels every held translation and the delivery in progress, and forgets everything:
    /// nothing is delivered afterwards, and later input is ignored (the direction is torn down).
    func cancelAll() {
        isCancelled = true
        entries.forEach { $0.translation?.cancel() }
        entries.removeAll()
        retractedIDs.removeAll()
        inFlight?.cancel()
        inFlight = nil
        deliveryTask?.cancel()
        deliveryTask = nil
    }

    // MARK: - Private

    private func startTranslation(of text: String) -> Task<String, Error> {
        let translate = translate
        return Task { try await translate(text) }
    }

    /// Starts the delivery loop unless one is running (it picks up whatever is ready).
    private func pump() {
        guard deliveryTask == nil, isHeadReady else { return }
        deliveryTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private var isHeadReady: Bool {
        guard let head = entries.first else { return false }
        return head.committed && head.text != nil
    }

    private func drain() async {
        while !isCancelled, isHeadReady {
            let head = entries.removeFirst()
            guard let text = head.text, !text.isEmpty else { continue }
            inFlight = head.translation
            await deliver(text, head.translation)
            inFlight = nil
        }
        if !isCancelled { deliveryTask = nil }
    }
}
