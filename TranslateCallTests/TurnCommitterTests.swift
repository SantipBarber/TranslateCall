import Foundation
import Testing
@testable import TranslateCall

/// Records what a `TurnCommitter` translates, cancels and delivers. Each translation waits on its
/// own gate (`open(_:)`), so a test decides when, and in which order, translations finish.
@MainActor
private final class CommitterProbe {
    private(set) var translated: [String] = []
    private(set) var delivered: [(text: String, translation: String)] = []
    let cancelled = LockedArray<String>()
    private var gates: [String: AsyncGate] = [:]
    /// Translations that return at once.
    var autoOpen = false

    func gate(_ text: String) -> AsyncGate {
        if let gate = gates[text] { return gate }
        let gate = AsyncGate()
        if autoOpen { gate.open() }
        gates[text] = gate
        return gate
    }

    func open(_ text: String) { gate(text).open() }

    func translate(_ text: String) async throws -> String {
        translated.append(text)
        let gate = gate(text)
        let cancelled = cancelled
        await withTaskCancellationHandler { await gate.wait() } onCancel: { cancelled.append(text) }
        try Task.checkCancellation()
        return "EN(\(text))"
    }

    /// Like the coordinator's deliver: awaits the held translation, or translates a final itself.
    func makeCommitter() -> TurnCommitter {
        TurnCommitter(
            translate: { [self] in try await translate($0) },
            deliver: { [self] text, translation in
                let task = translation ?? Task { try await translate(text) }
                let value = try? await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard let value else { return }
                delivered.append((text, value))
            }
        )
    }
}

private func result(_ text: String, id: UInt64, _ kind: SegmentKind = .tentative) -> TranscriptionResult {
    TranscriptionResult(
        text: text, confidence: 1, locale: Locale(identifier: "es-ES"), capturedAt: .now, audioDuration: 1,
        segmentID: id, kind: kind
    )
}

@Suite("TurnCommitter (FR-QS.5, design §10.4)", .serialized) @MainActor
struct TurnCommitterTests {

    @Test("a tentative is translated at once and delivered only at its commit")
    func commitAfterTranslation() async {
        let probe = CommitterProbe()
        let committer = probe.makeCommitter()
        committer.receive(result("hola", id: 1))
        #expect(await waitUntil { probe.translated == ["hola"] })
        probe.open("hola")
        await mainQueueHop()
        #expect(probe.delivered.isEmpty)
        #expect(committer.heldCount == 1)

        committer.receive(.commit(1))
        #expect(await waitUntil { probe.delivered.count == 1 })
        #expect(probe.delivered.first?.text == "hola")
        #expect(probe.delivered.first?.translation == "EN(hola)")
        #expect(probe.translated == ["hola"], "translated once")
        #expect(committer.heldCount == 0)
    }

    @Test("a commit that arrives before its result waits for the text")
    func commitBeforeResult() async {
        let probe = CommitterProbe()
        probe.autoOpen = true
        let committer = probe.makeCommitter()
        committer.receive(.commit(1))
        await mainQueueHop()
        #expect(probe.delivered.isEmpty)

        committer.receive(result("hola", id: 1))
        #expect(await waitUntil { probe.delivered.count == 1 })
        await mainQueueHop()
        #expect(probe.delivered.map(\.text) == ["hola"])
        #expect(committer.heldCount == 0)
    }

    @Test("a retract cancels the held translation; nothing is delivered")
    func retractCancels() async {
        let probe = CommitterProbe()
        let committer = probe.makeCommitter()
        committer.receive(result("hola", id: 1))
        #expect(await waitUntil { probe.translated == ["hola"] })

        committer.receive(.retract(1))
        #expect(await waitUntil { probe.cancelled.values == ["hola"] })
        #expect(committer.heldCount == 0)
        await mainQueueHop()
        #expect(probe.delivered.isEmpty)
    }

    @Test("a retract that arrives before its result drops the late result")
    func retractBeforeResult() async {
        let probe = CommitterProbe()
        probe.autoOpen = true
        let committer = probe.makeCommitter()
        committer.receive(.retract(1))
        committer.receive(result("creo", id: 1))
        committer.receive(result("creo que sí", id: 2, .final))
        #expect(await waitUntil { probe.delivered.count == 1 })
        #expect(probe.delivered.map(\.text) == ["creo que sí"])
        #expect(probe.translated == ["creo que sí"], "the retracted text is never translated")
        #expect(committer.heldCount == 0)
    }

    @Test("two hesitations and the end of the sentence: one delivery, the whole sentence")
    func twoHesitationsOneSentence() async {
        let probe = CommitterProbe()
        probe.autoOpen = true
        let committer = probe.makeCommitter()
        committer.receive(result("creo que", id: 1))
        committer.receive(.retract(1))
        committer.receive(result("creo que eh", id: 2))
        committer.receive(.retract(2))
        committer.receive(result("creo que eh si revisamos", id: 3))
        committer.receive(.commit(3))
        #expect(await waitUntil { probe.delivered.count == 1 })
        await mainQueueHop()
        #expect(probe.delivered.map(\.text) == ["creo que eh si revisamos"])
        #expect(committer.heldCount == 0)
    }

    @Test("sentences are delivered in id order, whatever order their translations finish in")
    func inOrder() async {
        let probe = CommitterProbe()
        let committer = probe.makeCommitter()
        committer.receive(result("uno", id: 1))
        committer.receive(result("dos", id: 2))
        #expect(await waitUntil { probe.translated.count == 2 })
        probe.open("dos")
        committer.receive(.commit(2))
        await mainQueueHop()
        #expect(probe.delivered.isEmpty, "2 waits for 1")

        committer.receive(.commit(1))
        probe.open("uno")
        #expect(await waitUntil { probe.delivered.count == 2 })
        #expect(probe.delivered.map(\.text) == ["uno", "dos"])
    }

    @Test("a committed empty tentative does not block the next sentence")
    func emptyCommitDoesNotBlock() async {
        let probe = CommitterProbe()
        probe.autoOpen = true
        let committer = probe.makeCommitter()
        committer.receive(result("", id: 1))
        committer.receive(.commit(1))
        committer.receive(result("vale", id: 2, .final))
        #expect(await waitUntil { probe.delivered.count == 1 })
        await mainQueueHop()
        #expect(probe.delivered.map(\.text) == ["vale"])
        #expect(probe.translated == ["vale"], "empty text is never translated")
        #expect(committer.heldCount == 0)
    }

    @Test("a final result is delivered with no boundary")
    func finalsUnchanged() async {
        let probe = CommitterProbe()
        probe.autoOpen = true
        let committer = probe.makeCommitter()
        committer.receive(result("hola", id: 1, .final))
        #expect(await waitUntil { probe.delivered.count == 1 })
        #expect(probe.delivered.first?.translation == "EN(hola)")
    }

    @Test("untagged finals (id 0) keep their arrival order")
    func untaggedFinalsInArrivalOrder() async {
        let probe = CommitterProbe()
        probe.autoOpen = true
        let committer = probe.makeCommitter()
        committer.receive(result("uno", id: 0, .final))
        committer.receive(result("dos", id: 0, .final))
        committer.receive(result("tres", id: 0, .final))
        #expect(await waitUntil { probe.delivered.count == 3 })
        #expect(probe.delivered.map(\.text) == ["uno", "dos", "tres"])
    }

    @Test("cancelAll drops what is held: a later commit delivers nothing")
    func stopDropsHeld() async {
        let probe = CommitterProbe()
        let committer = probe.makeCommitter()
        committer.receive(result("hola", id: 1))
        #expect(await waitUntil { probe.translated == ["hola"] })

        committer.cancelAll()
        #expect(await waitUntil { probe.cancelled.values == ["hola"] })
        committer.receive(.commit(1))
        probe.open("hola")
        await mainQueueHop()
        #expect(probe.delivered.isEmpty)
    }

    @Test("cancelAll cancels a delivery in progress")
    func stopCancelsDelivery() async {
        let probe = CommitterProbe()
        let committer = probe.makeCommitter()
        committer.receive(result("hola", id: 1, .final))
        #expect(await waitUntil { probe.translated == ["hola"] })

        committer.cancelAll()
        #expect(await waitUntil { probe.cancelled.values == ["hola"] })
        probe.open("hola")
        await mainQueueHop()
        #expect(probe.delivered.isEmpty)
        #expect(committer.heldCount == 0)
    }
}
