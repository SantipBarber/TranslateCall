import Combine
import Foundation

// MARK: - PairEngine

/// One engine of the "Advanced…" models sheet: a speech-recognition or a voice engine.
nonisolated enum PairEngine: Hashable, Sendable {
    case stt(STTEngine)
    case tts(TTSEngine)

    /// True for the voice stage.
    var isVoice: Bool {
        if case .tts = self { return true }
        return false
    }

    /// The model behind the engine; nil when it needs no download.
    var downloadable: DownloadableModel? {
        switch self {
        case .stt(let engine): DownloadableModel(engine)
        case .tts(let engine): DownloadableModel(engine)
        }
    }

    var isCloud: Bool { self == .tts(.edgeTTS) }
}

// MARK: - Recommendation

/// Whether the catalog recommends an engine for this pair, and for which language (REQ-ST-11).
nonisolated enum Recommendation: Equatable, Sendable {
    case none
    case both
    case only(language: String)
}

// MARK: - EngineRowState

/// One row of the sheet.
nonisolated struct EngineRowState: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case selectable
        /// Serves one of the two languages only.
        case partial(language: String)
        case notForPair
        /// The catalog marks the engine unavailable (S-3).
        case unavailable
    }

    let engine: PairEngine
    let name: String
    let recommendation: Recommendation
    let isCloud: Bool
    /// A cloud engine the user has not consented to yet: picking it asks first (REQ-ST-15).
    let needsConsent: Bool
    let tested: Bool
    let latency: String?
    let availability: Availability
    /// nil when the engine needs no download.
    let download: DownloadState?
    let isSelected: Bool

    var id: PairEngine { engine }
}

// MARK: - PairModelsModel

/// The "Advanced…" sheet for one language pair (M9 UI settings REQ-ST-10…18): staged choices that Done
/// stores and Cancel drops, the rows with their download state, and the cloud consent step.
@MainActor
final class PairModelsModel: ObservableObject {
    /// One language the pair hears or speaks, and in which direction.
    private struct Side {
        let locale: Locale
        let direction: TranscriptDirection
        let name: String
    }

    @Published private(set) var staged: PairModelChoice
    @Published private(set) var pendingConsent: TTSEngine?

    let pair: PairKey
    let title: String
    /// "ES · DE": the pair's codes in the title's order, for the "Tested" chip (REQ-ST-12).
    let testedLabel: String

    private let myName: String
    private let theirName: String
    private let myLocale: Locale
    private let theirLocale: Locale
    private let choices: PairModelChoices
    private let cloud: CloudPolicy
    private let downloads: ModelDownloads
    private let catalog: ModelCatalog
    private let voiceCloneOn: Bool
    /// The pick waiting on its download, per stage (key: `isVoice`).
    private var pendingPicks: [Bool: PairEngine] = [:]
    private var cancellables: Set<AnyCancellable> = []

    init(source: Locale.Language, target: Locale.Language, displayName: (Locale.Language) -> String,
         choices: PairModelChoices, cloud: CloudPolicy, downloads: ModelDownloads,
         catalog: ModelCatalog = .bundled, voiceCloneOn: Bool) {
        pair = PairKey(source, target)
        myName = displayName(source)
        theirName = displayName(target)
        myLocale = Locale(identifier: source.minimalIdentifier)
        theirLocale = Locale(identifier: target.minimalIdentifier)
        testedLabel = "\(PairKey.code(source).uppercased()) · \(PairKey.code(target).uppercased())"
        title = String(localized: "Models for \(myName) ↔ \(theirName)")
        self.choices = choices
        self.cloud = cloud
        self.downloads = downloads
        self.catalog = catalog
        self.voiceCloneOn = voiceCloneOn
        staged = choices.choice(for: pair)
        downloads.refresh()
        downloads.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        cloud.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        downloads.$states.sink { [weak self] states in self?.dropFailedPicks(states) }.store(in: &cancellables)
        downloads.didFinish.sink { [weak self] model in self?.downloadFinished(model) }.store(in: &cancellables)
    }

    // MARK: Rows

    /// Downloads wait until the call ends (S-7).
    var downloadsBlocked: Bool { downloads.isBlocked }

    /// Shown only with "Use my voice" on and their language supported (REQ-ST-18).
    var voiceCloneLine: String? {
        guard voiceCloneOn, TTSEngine.voiceClone.supports(locale: theirLocale) else { return nil }
        return String(localized: "Your voice is used for \(theirName) while “Use my voice” is on.")
    }

    var speechRows: [EngineRowState] {
        [STTEngine.whisper, .appleSpeech, .parakeet].map { row(for: .stt($0)) }
    }

    var voiceRows: [EngineRowState] {
        var engines: [TTSEngine] = [.avSpeech, .kokoro]
        if cloud.allowed { engines.append(.edgeTTS) }
        return engines.map { row(for: .tts($0)) }
    }

    nonisolated static func name(_ engine: PairEngine) -> String {
        switch engine {
        case .stt(.whisper): String(localized: "Whisper")
        case .stt(.appleSpeech): String(localized: "Apple Speech")
        case .stt(.parakeet): String(localized: "Parakeet")
        case .tts(.avSpeech): String(localized: "Apple voices")
        case .tts(.kokoro): String(localized: "Kokoro")
        case .tts(.edgeTTS): String(localized: "Microsoft Edge voices")
        case .tts(.voiceClone): String(localized: "My voice")
        }
    }

    // MARK: Actions

    /// Stages `engine`. A model not on disk downloads first and is staged when it finishes (REQ-ST-14); a
    /// cloud engine asks for consent first.
    func pick(_ engine: PairEngine) {
        let current = row(for: engine)
        guard current.availability != .notForPair, current.availability != .unavailable else { return }
        if let model = engine.downloadable, downloads.state(model) != .ready {
            guard !downloads.isBlocked else { return }
            pendingPicks[engine.isVoice] = engine
            downloads.start(model)
            return
        }
        if case .tts(let tts) = engine, engine.isCloud, !cloud.hasConsent(tts) {
            pendingConsent = tts
            return
        }
        stage(engine)
    }

    /// Stops the engine's download and forgets the pick that was waiting on it.
    func cancel(_ engine: PairEngine) {
        if pendingPicks[engine.isVoice] == engine { pendingPicks[engine.isVoice] = nil }
        if let model = engine.downloadable { downloads.cancel(model) }
    }

    func confirmConsent() {
        guard let engine = pendingConsent else { return }
        pendingConsent = nil
        cloud.grantConsent(engine)
        stage(.tts(engine))
    }

    func declineConsent() {
        pendingConsent = nil
    }

    /// Back to "Recommended" for both stages (stored by `commit()`).
    func reset() {
        pendingPicks = [:]
        staged = PairModelChoice()
    }

    /// Done: stores the staged choice; an empty one removes the pair's entry.
    func commit() {
        choices.set(staged, for: pair)
    }

    // MARK: - Private

    private func stage(_ engine: PairEngine) {
        pendingPicks[engine.isVoice] = nil
        let recommended = row(for: engine).recommendation == .both   // recommended for both: stays "Recommended" (P6)
        switch engine {
        case .stt(let stt): staged.stt = recommended ? nil : stt
        case .tts(let tts): staged.voice = recommended ? nil : tts
        }
    }

    private func downloadFinished(_ model: DownloadableModel) {
        guard let engine = pendingPicks.values.first(where: { $0.downloadable == model }) else { return }
        stage(engine)
    }

    /// A failed download drops its pending pick; "Try again" sets it again through `pick(_:)`.
    private func dropFailedPicks(_ states: [DownloadableModel: DownloadState]) {
        for (stage, engine) in pendingPicks {
            if let model = engine.downloadable, case .failed = states[model] { pendingPicks[stage] = nil }
        }
    }

    private var speechSides: [Side] {
        [Side(locale: myLocale, direction: .outgoing, name: myName),
         Side(locale: theirLocale, direction: .incoming, name: theirName)]
    }

    private var voiceSides: [Side] {
        [Side(locale: theirLocale, direction: .outgoing, name: theirName),
         Side(locale: myLocale, direction: .incoming, name: myName)]
    }

    private func row(for engine: PairEngine) -> EngineRowState {
        let sides = engine.isVoice ? voiceSides : speechSides
        let recommendation = recommendation(for: engine, sides: sides)
        let metrics = catalog.metrics(for: pair, engine: Self.rawName(engine))
        let selected: Bool
        switch engine {
        case .stt: selected = staged.stt.map { .stt($0) == engine } ?? (recommendation != .none)
        case .tts: selected = shownVoice.map { .tts($0) == engine } ?? (recommendation != .none)
        }
        return EngineRowState(engine: engine, name: Self.name(engine), recommendation: recommendation,
                              isCloud: engine.isCloud, needsConsent: needsConsent(engine),
                              tested: metrics?.tested ?? false,
                              latency: metrics?.latencyLabel(isVoice: engine.isVoice),
                              availability: availability(of: engine, sides: sides),
                              download: engine.downloadable.map { downloads.state($0) }, isSelected: selected)
    }

    /// The staged voice, unless it has no row (Edge with cloud off): then the recommended row shows.
    private var shownVoice: TTSEngine? {
        staged.voice == .edgeTTS && !cloud.allowed ? nil : staged.voice
    }

    private func needsConsent(_ engine: PairEngine) -> Bool {
        guard case .tts(let tts) = engine, engine.isCloud else { return false }
        return !cloud.hasConsent(tts)
    }

    private func availability(of engine: PairEngine, sides: [Side]) -> EngineRowState.Availability {
        if case .tts(let tts) = engine, catalog.isUnavailable(tts) { return .unavailable }
        let serving = sides.filter { serves(engine, $0) }
        guard let first = serving.first else { return .notForPair }
        if serving.count == 1, sides.count == 2, Set(sides.map(\.name)).count == 2 {
            return .partial(language: first.name)
        }
        return .selectable
    }

    private func recommendation(for engine: PairEngine, sides: [Side]) -> Recommendation {
        let matching = sides.filter { recommended(for: $0, isVoice: engine.isVoice) == engine }
        if matching.isEmpty { return .none }
        if matching.count == sides.count { return .both }
        return .only(language: matching[0].name)
    }

    private func serves(_ engine: PairEngine, _ side: Side) -> Bool {
        switch engine {
        case .stt(let stt): ModelChoice.serves(stt, locale: side.locale, direction: side.direction)
        case .tts(let tts): ModelChoice.serves(tts, locale: side.locale, direction: side.direction)
        }
    }

    /// What the catalog would run for `side` with everything downloaded.
    private func recommended(for side: Side, isVoice: Bool) -> PairEngine {
        if isVoice {
            return .tts(ModelChoice.tts(for: side.locale, direction: side.direction, catalog: catalog,
                                        availability: .allOnDisk))
        }
        return .stt(ModelChoice.stt(for: side.locale, direction: side.direction, catalog: catalog,
                                    availability: .allOnDisk))
    }

    private static func rawName(_ engine: PairEngine) -> String {
        switch engine {
        case .stt(let stt): stt.rawValue
        case .tts(let tts): tts.rawValue
        }
    }
}
