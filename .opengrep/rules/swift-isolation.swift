actor SpeechService {
    // ruleid: no-nonisolated-unsafe-stt-translation
    nonisolated(unsafe) private(set) var locale: Locale
    // ok: no-nonisolated-unsafe-stt-translation
    private let localeState: Mutex<Locale>
    // ok: no-nonisolated-unsafe-stt-translation
    nonisolated var current: Locale { localeState.withLock { $0 } }
}
