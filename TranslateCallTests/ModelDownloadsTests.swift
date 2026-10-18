import Combine
import Foundation
import Synchronization
import Testing
@testable import TranslateCall

/// A fake download that waits until the test finishes or fails it; counts starts and cancels.
private final class FakeDownloads: Sendable {
    private let pending = Mutex<[DownloadableModel: CheckedContinuation<Void, any Error>]>([:])
    private let log = Mutex<[String]>([])
    var entries: [String] { log.withLock { $0 } }
    var isWaiting: Bool { pending.withLock { !$0.isEmpty } }

    var managers: DownloadManagers {
        DownloadManagers(
            download: { model in
                self.log.withLock { $0.append("download \(model.rawValue)") }
                try await withCheckedThrowingContinuation { continuation in
                    self.pending.withLock { $0[model] = continuation }
                }
            },
            cancel: { model in self.log.withLock { $0.append("cancel \(model.rawValue)") } })
    }

    func finish(_ model: DownloadableModel, error: (any Error)? = nil) {
        let continuation = pending.withLock { $0.removeValue(forKey: model) }
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }
}

private struct Boom: LocalizedError { var errorDescription: String? { "No network" } }

/// The disk check flips to true once a fake download finishes.
private final class FakeDisk: Sendable {
    let onDisk = Mutex<Set<DownloadableModel>>([])
    var probe: ModelCacheProbe {
        ModelCacheProbe(parakeet: { self.onDisk.withLock { $0.contains(.parakeet) } },
                        whisper: { self.onDisk.withLock { $0.contains(.whisper) } },
                        kokoro: { self.onDisk.withLock { $0.contains(.kokoro) } },
                        voiceClone: { self.onDisk.withLock { $0.contains(.voiceClone) } })
    }
}

@Suite("ModelDownloads (M9 UI settings S-4, S-7)") @MainActor
struct ModelDownloadsTests {

    @Test("states come from the disk; sizes are the legacy figures; engines map to models")
    func initialStates() {
        let disk = FakeDisk()
        disk.onDisk.withLock { $0 = [.whisper] }
        let downloads = ModelDownloads(probe: disk.probe, managers: FakeDownloads().managers)
        #expect(downloads.state(.whisper) == .ready)
        #expect(downloads.state(.parakeet) == .notOnDisk)
        #expect(DownloadableModel.parakeet.approximateSize == "≈800 MB")
        #expect(DownloadableModel.voiceClone.approximateSize == "≈2 GB")
        #expect(DownloadableModel(STTEngine.appleSpeech) == nil)
        #expect(DownloadableModel(TTSEngine.kokoro) == .kokoro)
        #expect(DownloadableModel(TTSEngine.edgeTTS) == nil)
    }

    @Test("start → downloading (no progress) → ready, and didFinish fires once")
    func downloadSucceeds() async {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers)
        var finished: [DownloadableModel] = []
        let token = downloads.didFinish.sink { finished.append($0) }
        downloads.start(.parakeet)
        #expect(downloads.state(.parakeet) == .downloading(progress: nil))
        downloads.start(.parakeet)   // a second start while downloading is ignored
        #expect(await waitUntil { fake.isWaiting })
        fake.finish(.parakeet)
        #expect(await waitUntil { downloads.state(.parakeet) == .ready })
        #expect(finished == [.parakeet])
        #expect(fake.entries == ["download parakeet"])
        token.cancel()
    }

    @Test("a failure shows the error; starting again retries")
    func downloadFails() async {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers)
        downloads.start(.kokoro)
        #expect(await waitUntil { fake.isWaiting })
        fake.finish(.kokoro, error: Boom())
        #expect(await waitUntil { downloads.state(.kokoro) == .failed("No network") })
        downloads.start(.kokoro)
        #expect(downloads.state(.kokoro) == .downloading(progress: nil))
        #expect(await waitUntil { fake.isWaiting })
        fake.finish(.kokoro)
        #expect(await waitUntil { downloads.state(.kokoro) == .ready })
    }

    @Test("refresh keeps a failure while the model is still not on disk (REQ-ST-14)")
    func refreshKeepsFailure() async {
        let disk = FakeDisk()
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: disk.probe, managers: fake.managers)
        downloads.start(.whisper)
        #expect(await waitUntil { fake.isWaiting })
        fake.finish(.whisper, error: Boom())
        #expect(await waitUntil { downloads.state(.whisper) == .failed("No network") })
        downloads.refresh()
        #expect(downloads.state(.whisper) == .failed("No network"))
        disk.onDisk.withLock { $0 = [.whisper] }
        downloads.refresh()
        #expect(downloads.state(.whisper) == .ready)
    }

    @Test("cancel asks the manager to stop and re-probes the disk; a late finish changes nothing")
    func cancelIsBestEffort() async {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers)
        var finished = 0
        let token = downloads.didFinish.sink { _ in finished += 1 }
        downloads.start(.whisper)
        #expect(await waitUntil { fake.isWaiting })
        downloads.cancel(.whisper)
        #expect(downloads.state(.whisper) == .notOnDisk)
        #expect(await waitUntil { fake.entries.contains("cancel whisper") })
        fake.finish(.whisper)
        await mainQueueHop()
        #expect(downloads.state(.whisper) == .notOnDisk)
        #expect(finished == 0)
        token.cancel()
    }

    @Test("no download starts while a session runs (S-7)")
    func blockedDuringSession() {
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: FakeDisk().probe, managers: fake.managers, isSessionActive: { true })
        #expect(downloads.isBlocked)
        downloads.start(.parakeet)
        #expect(downloads.state(.parakeet) == .notOnDisk)
        #expect(fake.entries.isEmpty)
    }

    @Test("a model already on disk is not downloaded again")
    func readyIsNoOp() {
        let disk = FakeDisk()
        disk.onDisk.withLock { $0 = [.voiceClone] }
        let fake = FakeDownloads()
        let downloads = ModelDownloads(probe: disk.probe, managers: fake.managers)
        downloads.start(.voiceClone)
        #expect(downloads.state(.voiceClone) == .ready)
        #expect(fake.entries.isEmpty)
    }
}
