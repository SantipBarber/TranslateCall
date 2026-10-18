#if DEBUG
import SwiftUI

/// One state of the models sheet on fixture stores (previews never touch the disk, the network or a model).
@MainActor
struct PairModelsFixture {
    var source = "es"
    var target = "de"
    var onDisk: Set<DownloadableModel> = [.whisper, .parakeet, .kokoro]
    var cloudAllowed = false
    var blocked = false
    var voiceCloneOn = false
    var catalog = ModelCatalog.bundled
    var download: DownloadableModel?
    var failing = false

    var sheet: some View {
        let name = "preview.models"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        defaults.set(cloudAllowed, forKey: CloudPolicy.allowedKey)
        let disk = onDisk
        let probe = ModelCacheProbe(parakeet: { disk.contains(.parakeet) }, whisper: { disk.contains(.whisper) },
                                    kokoro: { disk.contains(.kokoro) }, voiceClone: { disk.contains(.voiceClone) })
        let isBlocked = blocked
        let fails = failing
        let managers = DownloadManagers(download: { _ in
            if fails { throw URLError(.notConnectedToInternet) }
            try await Task.sleep(for: .seconds(3600))
        }, cancel: { _ in })
        let downloads = ModelDownloads(probe: probe, managers: managers, isSessionActive: { isBlocked })
        let cloud = CloudPolicy(defaults: defaults, edgeConsentGiven: { false }, grantEdgeConsent: {})
        let names = ["es": "Español", "de": "Deutsch", "en": "English"]
        let model = PairModelsModel(
            source: Locale.Language(identifier: source), target: Locale.Language(identifier: target),
            displayName: { names[$0.minimalIdentifier] ?? $0.minimalIdentifier },
            choices: PairModelChoices(defaults: defaults), cloud: cloud, downloads: downloads,
            catalog: catalog, voiceCloneOn: voiceCloneOn)
        if let download { downloads.start(download) }
        return PairModelsSheet(model: model, onClose: {})
            .environmentObject(downloads)
            .background(Color(.windowBackgroundColor))
    }
}

#Preview("ES ↔ DE — light") { PairModelsFixture().sheet }
#Preview("ES ↔ DE — dark") { PairModelsFixture().sheet.preferredColorScheme(.dark) }
#Preview("EN ↔ ES, Parakeet not on disk") {
    PairModelsFixture(source: "en", target: "es", onDisk: [.whisper, .kokoro]).sheet
}
#Preview("Downloading") {
    PairModelsFixture(source: "en", target: "es", onDisk: [.whisper], download: .parakeet).sheet
}
#Preview("Download failed") {
    PairModelsFixture(source: "en", target: "es", onDisk: [.whisper], download: .parakeet, failing: true).sheet
}
#Preview("Blocked during a call") {
    PairModelsFixture(source: "en", target: "es", onDisk: [.whisper], blocked: true).sheet
}
#Preview("Cloud on, Edge unavailable") {
    PairModelsFixture(cloudAllowed: true, catalog: .builtIn).sheet
}
#Preview("Catalog with metrics") { PairModelsFixture(catalog: .sampleWithMetrics).sheet }

private extension ModelCatalog {
    /// A catalog with benchmark data for ES ↔ DE (the bundled one has none yet, S-2).
    static var sampleWithMetrics: ModelCatalog {
        var catalog = ModelCatalog.bundled
        catalog.pairs = ["de|es": ["whisper": EngineMetrics(tested: true, latencyMs: 400),
                                   "appleSpeech": EngineMetrics(tested: true, latencyMs: 300),
                                   "avSpeech": EngineMetrics(tested: true, latencyMs: 100),
                                   "kokoro": EngineMetrics(tested: false, latencyMs: nil)]]
        return catalog
    }
}
#Preview("Use my voice on") { PairModelsFixture(voiceCloneOn: true).sheet }
#endif
