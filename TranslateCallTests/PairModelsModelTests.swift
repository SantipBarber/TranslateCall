import Combine
import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// Downloads that finish when the test says so; the disk check follows.
private final class ControlledDownloads: Sendable {
    let onDisk = Mutex<Set<DownloadableModel>>([])
    private let pending = Mutex<[DownloadableModel: CheckedContinuation<Void, any Error>]>([:])
    var isWaiting: Bool { pending.withLock { !$0.isEmpty } }

    var probe: ModelCacheProbe {
        ModelCacheProbe(parakeet: { self.onDisk.withLock { $0.contains(.parakeet) } },
                        whisper: { self.onDisk.withLock { $0.contains(.whisper) } },
                        kokoro: { self.onDisk.withLock { $0.contains(.kokoro) } },
                        voiceClone: { self.onDisk.withLock { $0.contains(.voiceClone) } })
    }

    var managers: DownloadManagers {
        DownloadManagers(download: { model in
                             try await withCheckedThrowingContinuation { cont in self.pending.withLock { $0[model] = cont } }
                         },
                         cancel: { _ in })
    }

    func fail(_ model: DownloadableModel) {
        pending.withLock { $0.removeValue(forKey: model) }?.resume(throwing: CancellationError())
    }

    func finish(_ model: DownloadableModel) {
        onDisk.withLock { _ = $0.insert(model) }
        pending.withLock { $0.removeValue(forKey: model) }?.resume()
    }
}

@MainActor
private struct SheetHarness {
    let defaults: UserDefaults
    let choices: PairModelChoices
    let cloud: CloudPolicy
    let fake = ControlledDownloads()
    let downloads: ModelDownloads
    /// The coordinator's "a session runs", flipped by the tests (S-7).
    let session: CurrentValueSubject<Bool, Never>

    init(onDisk: Set<DownloadableModel> = [.whisper, .parakeet, .kokoro], cloudAllowed: Bool = false,
         session: Bool = false) {
        let name = "PairModelsModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(cloudAllowed, forKey: CloudPolicy.allowedKey)
        choices = PairModelChoices(defaults: defaults)
        fake.onDisk.withLock { $0 = onDisk }
        var consent = false
        cloud = CloudPolicy(defaults: defaults, edgeConsentGiven: { consent },
                            grantEdgeConsent: { consent = true })
        self.session = CurrentValueSubject(session)
        downloads = ModelDownloads(probe: fake.probe, managers: fake.managers,
                                   sessionActive: self.session.eraseToAnyPublisher())
    }

    func model(_ source: String, _ target: String, catalog: ModelCatalog = .builtIn,
               voiceCloneOn: Bool = false) -> PairModelsModel {
        let names = ["es": "Español", "de": "Deutsch", "en": "English"]
        return PairModelsModel(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target),
                               displayName: { names[$0.minimalIdentifier] ?? $0.minimalIdentifier },
                               choices: choices, cloud: cloud, downloads: downloads, catalog: catalog,
                               voiceCloneOn: voiceCloneOn)
    }
}

private func row(_ rows: [EngineRowState], _ engine: PairEngine) throws -> EngineRowState {
    try #require(rows.first { $0.engine == engine })
}

@Suite("PairModelsModel — the Advanced… sheet (M9 UI settings REQ-ST-10…18)") @MainActor
struct PairModelsModelTests {

    @Test("ES ↔ DE: Whisper recommended and selected; Parakeet not for this pair; no Edge with cloud off")
    func spanishGerman() throws {
        let sheet = SheetHarness().model("es", "de")
        #expect(sheet.title == "Models for Español ↔ Deutsch")
        let whisper = try row(sheet.speechRows, .stt(.whisper))
        #expect(whisper.recommendation == .both && whisper.isSelected && whisper.download == .ready)
        #expect(try row(sheet.speechRows, .stt(.parakeet)).availability == .notForPair)
        #expect(try row(sheet.speechRows, .stt(.appleSpeech)).download == nil)
        #expect(try row(sheet.voiceRows, .tts(.avSpeech)).recommendation == .both)
        #expect(try row(sheet.voiceRows, .tts(.kokoro)).availability == .notForPair)
        #expect(!sheet.voiceRows.contains { $0.engine == .tts(.edgeTTS) })
        #expect(!sheet.speechRows.contains { $0.tested || $0.latency != nil }, "no benchmark data yet (S-2)")
    }

    @Test("EN ↔ ES: Parakeet recommended for English only, Whisper for Español; Kokoro partial")
    func englishSpanish() throws {
        let sheet = SheetHarness().model("en", "es")
        #expect(try row(sheet.speechRows, .stt(.parakeet)).recommendation == .only(language: "English"))
        #expect(try row(sheet.speechRows, .stt(.parakeet)).availability == .partial(language: "English"))
        #expect(try row(sheet.speechRows, .stt(.whisper)).recommendation == .only(language: "Español"))
        #expect(try row(sheet.voiceRows, .tts(.kokoro)).availability == .partial(language: "English"))
    }

    @Test("Done stores the staged choice; Cancel (no commit) stores nothing; Reset clears it")
    func stageCommitReset() {
        let harness = SheetHarness()
        let sheet = harness.model("es", "de")
        sheet.pick(.stt(.appleSpeech))
        #expect(sheet.staged.stt == .appleSpeech)
        #expect(harness.choices.all.isEmpty, "staged only")
        sheet.commit()
        #expect(harness.choices.choice(for: PairKey("de", "es")).stt == .appleSpeech)

        let again = harness.model("de", "es")
        #expect(again.staged.stt == .appleSpeech)
        again.reset()
        again.commit()
        #expect(harness.choices.all.isEmpty)
    }

    @Test("picking the row recommended for both languages stores nothing (stays Recommended)")
    func pickingRecommendedStoresNothing() {
        let harness = SheetHarness()
        let sheet = harness.model("es", "de")
        sheet.pick(.stt(.appleSpeech))
        sheet.pick(.stt(.whisper))
        #expect(sheet.staged.isEmpty)
    }

    @Test("a model not on disk downloads in its row and is selected when it finishes (REQ-ST-14)")
    func pickDownloadsThenSelects() async throws {
        let harness = SheetHarness(onDisk: [])
        let sheet = harness.model("en", "es")
        #expect(try row(sheet.speechRows, .stt(.parakeet)).download == .notOnDisk)
        sheet.pick(.stt(.parakeet))
        #expect(try row(sheet.speechRows, .stt(.parakeet)).download == .downloading(progress: nil))
        #expect(sheet.staged.stt == nil)
        #expect(await waitUntil { harness.fake.isWaiting })
        harness.fake.finish(.parakeet)
        #expect(await waitUntil { sheet.staged.stt == .parakeet })
    }

    @Test("during a call a model not on disk cannot be picked (S-7)")
    func noDownloadDuringCall() throws {
        let harness = SheetHarness(onDisk: [], session: true)
        let sheet = harness.model("en", "es")
        #expect(sheet.downloadsBlocked)
        sheet.pick(.stt(.parakeet))
        #expect(try row(sheet.speechRows, .stt(.parakeet)).download == .notOnDisk)
        sheet.pick(.stt(.appleSpeech))
        #expect(sheet.staged.stt == .appleSpeech, "models already on this Mac can still be picked")
    }

    @Test("a call starting or ending while the sheet is open flips its blocked state live (S-7)")
    func blockedFollowsTheSession() {
        let harness = SheetHarness(onDisk: [])
        let sheet = harness.model("en", "es")
        var changes = 0
        let token = sheet.objectWillChange.sink { _ in changes += 1 }
        #expect(!sheet.downloadsBlocked)
        harness.session.send(true)
        #expect(harness.downloads.isBlocked && sheet.downloadsBlocked)
        #expect(changes > 0, "the sheet re-renders when the call starts")
        sheet.pick(.stt(.parakeet))
        #expect(harness.downloads.state(.parakeet) == .notOnDisk)
        let beforeEnd = changes
        harness.session.send(false)
        #expect(!harness.downloads.isBlocked && !sheet.downloadsBlocked)
        #expect(changes > beforeEnd, "the sheet re-renders when the call ends")
        token.cancel()
    }

    @Test("Edge: shown with cloud on; marked unavailable it can't be picked (S-3)")
    func edgeUnavailable() throws {
        let sheet = SheetHarness(cloudAllowed: true).model("es", "de")
        let edge = try row(sheet.voiceRows, .tts(.edgeTTS))
        #expect(edge.isCloud && edge.availability == .unavailable)
        sheet.pick(.tts(.edgeTTS))
        #expect(sheet.pendingConsent == nil && sheet.staged.voice == nil)
    }

    @Test("Edge available: the first pick asks for consent; Allow stages it, Not now keeps the previous choice")
    func edgeConsent() {
        let available = ModelCatalog(version: 2, stt: ModelCatalog.builtIn.stt,
                                     ttsOutgoing: ModelCatalog.builtIn.ttsOutgoing,
                                     ttsIncoming: ModelCatalog.builtIn.ttsIncoming)
        let harness = SheetHarness(cloudAllowed: true)
        let sheet = harness.model("es", "de", catalog: available)
        sheet.pick(.tts(.edgeTTS))
        #expect(sheet.pendingConsent == .edgeTTS)
        sheet.declineConsent()
        #expect(sheet.pendingConsent == nil && sheet.staged.voice == nil)
        sheet.pick(.tts(.edgeTTS))
        sheet.confirmConsent()
        #expect(harness.cloud.hasConsent(.edgeTTS))
        #expect(sheet.staged.voice == .edgeTTS)
    }

    @Test("the voice-clone line shows only with \"Use my voice\" on and their language supported (REQ-ST-18)")
    func voiceCloneLine() {
        let harness = SheetHarness()
        #expect(harness.model("es", "de").voiceCloneLine == nil)
        #expect(harness.model("es", "de", voiceCloneOn: true).voiceCloneLine
                == "Your voice is used for Deutsch while “Use my voice” is on.")
        #expect(harness.model("es", "th", voiceCloneOn: true).voiceCloneLine == nil)
    }

    @Test("benchmark data shows as tested and latency when the catalog has it (S-2)")
    func metricsShown() throws {
        let catalog = ModelCatalog(version: 2, stt: ModelCatalog.builtIn.stt,
                                   ttsOutgoing: ModelCatalog.builtIn.ttsOutgoing,
                                   ttsIncoming: ModelCatalog.builtIn.ttsIncoming,
                                   pairs: ["de|es": ["whisper": EngineMetrics(tested: true, latencyMs: 400)]])
        let whisper = try row(SheetHarness().model("es", "de", catalog: catalog).speechRows, .stt(.whisper))
        #expect(whisper.tested && whisper.latency == "~0.4 s")
    }

    @Test("a speech download finishing after a voice pick still selects its row (REQ-ST-14)")
    func pendingPickPerStage() async throws {
        let harness = SheetHarness(onDisk: [.whisper, .kokoro])
        let sheet = harness.model("en", "es")
        harness.fake.onDisk.withLock { _ = $0.remove(.kokoro) }
        harness.downloads.refresh()
        sheet.pick(.stt(.parakeet))
        #expect(await waitUntil { harness.fake.isWaiting })
        sheet.pick(.tts(.avSpeech))
        harness.fake.finish(.parakeet)
        #expect(await waitUntil { sheet.staged.stt == .parakeet })
        #expect(try row(sheet.speechRows, .stt(.parakeet)).isSelected)
    }

    @Test("a failed download clears the pending pick; Try again then success stages it")
    func failedClearsPending() async throws {
        let harness = SheetHarness(onDisk: [])
        let sheet = harness.model("en", "es")
        sheet.pick(.stt(.parakeet))
        #expect(await waitUntil { harness.fake.isWaiting })
        harness.fake.fail(.parakeet)
        #expect(await waitUntil {
            if case .failed = harness.downloads.state(.parakeet) { true } else { false }
        })
        // finished from elsewhere: not staged unprompted
        harness.downloads.didFinish.send(.parakeet)
        #expect(sheet.staged.stt == nil)
        sheet.pick(.stt(.parakeet))
        #expect(await waitUntil { harness.fake.isWaiting })
        harness.fake.finish(.parakeet)
        #expect(await waitUntil { sheet.staged.stt == .parakeet })
    }

    @Test("a stored Edge choice with cloud off leaves the recommended voice selected (REQ-ST-32)")
    func storedEdgeCloudOff() throws {
        let harness = SheetHarness(cloudAllowed: false)
        harness.choices.set(PairModelChoice(voice: .edgeTTS), for: PairKey("de", "es"))
        let sheet = harness.model("es", "de")
        #expect(try row(sheet.voiceRows, .tts(.avSpeech)).isSelected)
    }

    @Test("the Tested chip names the pair in the title's order, not the stored sorted one")
    func testedLabelOrder() {
        let harness = SheetHarness()
        #expect(harness.model("es", "de").testedLabel == "ES · DE")
        #expect(harness.model("de", "es").testedLabel == "DE · ES")
    }

    @Test("needsConsent is true for Edge until consent is given, and never for other engines")
    func needsConsentFlag() throws {
        let available = ModelCatalog(version: 2, stt: ModelCatalog.builtIn.stt,
                                     ttsOutgoing: ModelCatalog.builtIn.ttsOutgoing,
                                     ttsIncoming: ModelCatalog.builtIn.ttsIncoming)
        let harness = SheetHarness(cloudAllowed: true)
        let sheet = harness.model("es", "de", catalog: available)
        #expect(try row(sheet.voiceRows, .tts(.edgeTTS)).needsConsent)
        #expect(try !row(sheet.voiceRows, .tts(.avSpeech)).needsConsent)
        harness.cloud.grantConsent(.edgeTTS)
        #expect(try !row(sheet.voiceRows, .tts(.edgeTTS)).needsConsent)
    }

    @Test("cancel stops the download and drops the pick, so a later finish does not stage it")
    func cancelDropsPendingPick() async throws {
        let harness = SheetHarness(onDisk: [])
        let sheet = harness.model("en", "es")
        sheet.pick(.stt(.parakeet))
        #expect(await waitUntil { harness.fake.isWaiting })
        sheet.cancel(.stt(.parakeet))
        #expect(harness.downloads.state(.parakeet) == .notOnDisk)
        harness.downloads.didFinish.send(.parakeet)
        #expect(sheet.staged.stt == nil)
    }
}
