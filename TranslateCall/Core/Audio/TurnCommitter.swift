import Foundation
import OSLog

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "TurnCommitter")

/// Holds one direction's sentences between recognition and delivery (FR-QS.5, design §10.4).
///
/// A `.tentative` result is translated at once and held; it is delivered (shown and spoken) only
/// when its segment is committed, and dropped when it is retracted. A `.final` result is committed
/// on arrival and takes today's path: `deliver` gets no translation and starts it after its own
/// mute-turn and pause checks, so a dropped final is never translated (REQ-UI-50).
/// Results and boundaries come on separate streams, so either may arrive first: every piece of
/// state is keyed by segment id. Delivery is one serial loop in id order; the head waits
/// until it is committed and its text is known, and an empty text is skipped without blocking.
///
/// Head-of-line safeguard (no timeout): results come in segment order (STT is serial) and at most
/// one tentative is open, so a head still waiting when a later id shows up never gets what it waits
/// for. It is dropped with a warning instead of muting the direction. Untagged entries (id 0) are exempt.
@MainActor
final class TurnCommitter {
    typealias Translate = @MainActor (String) async throws -> String
    /// `translation` is the held one for a tentative (already started on every part), nil for a
    /// final (`deliver` starts it).
    typealias Deliver = @MainActor (_ text: String, _ translation: SentenceTranslation?) async -> Void

    private struct Entry {
        let id: UInt64
        /// nil until the segment's result arrives (a commit came first).
        var text: String?
        /// Started on a non-empty tentative result; nil for a final and for empty text.
        var translation: SentenceTranslation?
        var committed: Bool
    }

    private let translate: Translate
    private let splitsClauses: Bool
    private let deliver: Deliver
    /// Held entries, in id order.
    private var entries: [Entry] = []
    /// Retracted before their result arrived: the late result is dropped, then the id forgotten.
    private var retractedIDs: Set<UInt64> = []
    private var deliveryTask: Task<Void, Never>?
    /// The translation being delivered now: cancelled by `cancelAll()` whatever `deliver` does.
    private var inFlight: SentenceTranslation?
    /// Set by `cancelAll()`: the direction is torn down, later input is ignored and the delivery
    /// loop stops at its next step.
    private var isCancelled = false

    /// Highest tagged id seen in a result, and in a result or boundary (head-of-line safeguard).
    private var maxResultID: UInt64 = 0
    private var maxSeenID: UInt64 = 0

    /// Entries held (not yet delivered or dropped). For tests.
    var heldCount: Int { entries.count }

    /// `splitsClauses` splits each tentative into clauses and translates them in parallel
    /// (QS-5, design §3); off keeps today's whole-sentence translation.
    init(translate: @escaping Translate, splitsClauses: Bool = false, deliver: @escaping Deliver) {
        self.translate = translate
        self.splitsClauses = splitsClauses
        self.deliver = deliver
    }

    func receive(_ result: TranscriptionResult) {
        guard !isCancelled else { return }
        let id = result.segmentID
        see(id, isResult: true)
        if retractedIDs.remove(id) != nil { return pump() }
        let eager = result.kind == .tentative && !result.text.isEmpty
        let translation = eager ? SentenceTranslation(result.text, split: splitsClauses, translate: translate) : nil
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
        case .commit(let id), .retract(let id): see(id, isResult: false)
        }
        switch boundary {
        case .commit(let id):
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].committed = true
            } else {
                let entry = Entry(id: id, text: nil, translation: nil, committed: true)
                entries.insert(entry, at: entries.firstIndex { $0.id > id } ?? entries.endIndex)
            }
        case .retract(let id):
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries.remove(at: index).translation?.cancel()
            } else if id > maxResultID {
                retractedIDs.insert(id)   // otherwise its result (if any) already came: nothing to drop
            }
        }
        pump()
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

    private func see(_ id: UInt64, isResult: Bool) {
        maxSeenID = max(maxSeenID, id)
        guard isResult, id > maxResultID else { return }
        maxResultID = id
        retractedIDs = retractedIDs.filter { $0 >= id }   // their results can no longer come
    }

    /// Drops heads that will never be ready: a committed head whose result was lost (a later result
    /// came), or an uncommitted tentative whose boundary was lost (a later segment or boundary came).
    private func dropLostHeads() {
        while let head = entries.first, head.id > 0 {
            let reason: String
            if head.text == nil && maxResultID > head.id {
                reason = "its result was lost"
            } else if !head.committed && maxSeenID > head.id {
                reason = "its commit or retract was lost"
            } else {
                return
            }
            entries.removeFirst().translation?.cancel()
            logger.warning("Dropped segment \(head.id, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// Starts the delivery loop unless one is running (it picks up whatever is ready).
    private func pump() {
        dropLostHeads()
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
        while !isCancelled {
            dropLostHeads()
            guard isHeadReady else { break }
            let head = entries.removeFirst()
            guard let text = head.text, !text.isEmpty else { continue }
            inFlight = head.translation
            await deliver(text, head.translation)
            inFlight = nil
        }
        if !isCancelled { deliveryTask = nil }
    }
}
