import Foundation

/// The "Models per language pair" list of Settings › Advanced (REQ-ST-30, 31).
nonisolated enum AdvancedPairs {
    /// ES ↔ DE, ES ↔ EN, DE ↔ EN, in the prototype's order.
    static let priority = [PairKey("es", "de"), PairKey("es", "en"), PairKey("de", "en")]
    /// Which language a pair's title names first when the current source is not in it.
    static let titleOrder = ["es", "de", "en"]

    /// The priority pairs, the current pair, then the customised pairs by key, without duplicates.
    static func list(current: PairKey, customized: [PairKey]) -> [PairKey] {
        var seen = Set<PairKey>()
        return (priority + [current] + customized.sorted { $0.storageKey < $1.storageKey })
            .filter { seen.insert($0).inserted }
    }

    /// The pair's two codes, "mine" first: the current source language when it is in the pair, else by
    /// `titleOrder`, else alphabetical. The sheet opens with this order.
    static func ordered(_ pair: PairKey, currentSource: String) -> (mine: String, theirs: String) {
        let codes = [pair.first, pair.second]
        if let mine = codes.first(where: { $0 == currentSource }) {
            return (mine, codes.first { $0 != mine } ?? mine)
        }
        let rank = { (code: String) in titleOrder.firstIndex(of: code) ?? titleOrder.count }
        let sorted = codes.sorted { (rank($0), $0) < (rank($1), $1) }
        return (sorted[0], sorted[1])
    }

    /// "Recommended", or "Custom · <engine>" naming the speech-recognition choice, else the voice.
    static func value(for choice: PairModelChoice) -> String {
        if let stt = choice.stt { return String(localized: "Custom · \(PairModelsModel.name(.stt(stt)))") }
        if let voice = choice.voice { return String(localized: "Custom · \(PairModelsModel.name(.tts(voice)))") }
        return String(localized: "Recommended")
    }
}
