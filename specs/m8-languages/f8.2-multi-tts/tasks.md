# F8.2 — Multi-Engine TTS Fallback — Tasks

## Dependency Graph

```
T1 (EdgeTTSVoiceCatalog)
 │
 ├──▶ T2 (EdgeTTSWebSocket)
 │        │
 │        ▶ T3 (EdgeTTSService)
 │
 ├──▶ T4 (EdgeTTSConsentManager)
 │
 ├──▶ T5 (TTSEngine + TTSEngineSelector changes + AVSpeech voice detection)
 │        │
 │        ▶ T6 (UI: consent dialog + cloud badge)
 │
 └──▶ T7 (Tests)
```

**Recommended order**: T1 → T2 → T3 → T4 → T5 → T6 → T7

---

## T1 — Create `EdgeTTSVoiceCatalog`

**File**: `TranslateCall/Core/TTS/EdgeTTSVoiceCatalog.swift` (NEW)

**Steps**:
1. Create `EdgeTTSVoice: Sendable, Codable` struct:
   - `shortName: String` (e.g. `"uk-UA-PolinaNeural"`)
   - `locale: String` (e.g. `"uk-UA"`)
   - `gender: String` (`"Female"` or `"Male"`)
   - `friendlyName: String` (e.g. `"Polina"`)
2. Create `EdgeTTSVoiceCatalog` enum with:
   - `static let voices: [EdgeTTSVoice]` — hard-coded catalog of ~50 key voices covering:
     - Ukrainian: `uk-UA-PolinaNeural`, `uk-UA-OstapNeural`
     - All major languages + languages missing from AVSpeech
   - `static func availableVoices(for locale: Locale) -> [EdgeTTSVoice]` — filter by locale prefix
   - `static func defaultVoice(for locale: Locale) -> EdgeTTSVoice?` — first match
   - `static func supports(_ locale: Locale) -> Bool`

**Acceptance**:
- `EdgeTTSVoiceCatalog.defaultVoice(for: Locale(identifier: "uk"))` returns `uk-UA-PolinaNeural`
- `EdgeTTSVoiceCatalog.supports(Locale(identifier: "uk"))` returns `true`
- Catalog covers at least 30 locales

---

## T2 — Create `EdgeTTSWebSocket`

**File**: `TranslateCall/Core/TTS/EdgeTTSWebSocket.swift` (NEW)

**Steps**:
1. Create `actor EdgeTTSWebSocket`
2. Private state:
   - `webSocket: URLSessionWebSocketTask?`
   - `session: URLSession`
3. Constants:
   - Endpoint URL: `wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1`
   - Token: `6A5AA1D4EAFF4E9FB37E23D68491D6F4`
   - Output format: `audio-24khz-48kbitrate-mono-mp3`
4. `connect() async throws`:
   - Build URL with query params (TrustedClientToken, ConnectionId=UUID)
   - Create `URLSessionWebSocketTask` with required headers (User-Agent, Origin)
   - Resume task
   - Send speech.config message (JSON with output format)
5. `synthesize(text:voice:rate:pitch:volume:) -> AsyncThrowingStream<Data, Error>`:
   - Build SSML string with voice name, prosody params, text
   - Send SSML message with X-RequestId header
   - Return stream that:
     - Receives WebSocket messages in a loop
     - For binary messages: extract MP3 data (skip header bytes before "Path:audio\r\n"), yield data
     - For text messages: check for `Path:turn.end` → finish stream
     - On error: throw and finish
6. `disconnect()`:
   - Cancel WebSocket task
   - Set to nil
7. Helper: `buildSSML(text:voice:rate:pitch:volume:) -> String`

**Acceptance**:
- Connects to Edge TTS WebSocket
- Sends valid SSML
- Returns MP3 audio chunks as Data
- Detects turn.end to finish stream

---

## T3 — Create `EdgeTTSService`

**File**: `TranslateCall/Core/TTS/EdgeTTSService.swift` (NEW)

**Steps**:
1. Create `actor EdgeTTSService: SynthesisService`
2. Protocol conformance:
   - `nonisolated let isSpeakingStream: AsyncStream<Bool>`
3. Private state:
   - `speakingContinuation: AsyncStream<Bool>.Continuation?`
   - `engine: AVAudioEngine` (nonisolated(unsafe))
   - `playerNode: AVAudioPlayerNode` (nonisolated(unsafe))
   - `mixerNode: AVAudioMixerNode` (nonisolated(unsafe))
   - `webSocket: EdgeTTSWebSocket`
   - `voiceName: String`
   - `currentTask: Task<Void, Never>?`
4. Init:
   ```swift
   init(outputDeviceID: AudioDeviceID? = nil, voiceName: String) throws
   ```
   - Set up AVAudioEngine + playerNode + mixer (same pattern as AVSpeechService/KokoroSpeechService)
   - Route to specified output device if provided
   - Create EdgeTTSWebSocket
5. `speak(text: String, locale: Locale) async`:
   - Cancel current task if any
   - Emit `isSpeaking = true`
   - Connect WebSocket if needed
   - Call `webSocket.synthesize(text:voice:...)` to get audio stream
   - Accumulate MP3 chunks → write to temp file
   - After sufficient data (~6KB / 0.5s): decode with `AVAudioFile`, schedule PCM on player
   - Continue accumulating + decoding + scheduling for streaming playback
   - On turn.end: decode remaining, wait for player to finish
   - Emit `isSpeaking = false`
   - Record TTSMetrics
6. `stopSpeaking() async`:
   - Cancel currentTask
   - Stop playerNode
   - Emit `isSpeaking = false`
7. `deactivate() async`:
   - Stop speaking
   - Disconnect WebSocket
   - Stop engine
8. Private helper: `decodeMp3Chunk(data: Data, into: AVAudioPCMBuffer?) -> AVAudioPCMBuffer?`
   - Write data to temp file, open as AVAudioFile, read frames

**Acceptance**:
- Conforms to `SynthesisService`
- Plays audio from Edge TTS
- Streaming playback (audio starts before full response)
- `isSpeakingStream` emits correct states
- Handles errors gracefully (network failure → log + continue)

---

## T4 — Create `EdgeTTSConsentManager`

**File**: `TranslateCall/Core/TTS/EdgeTTSConsentManager.swift` (NEW)

**Steps**:
1. Create `EdgeTTSConsentManager` enum with:
   - `private static let consentKey = "tlk.edgeTTS.consentGiven"`
   - `static var consentGiven: Bool` — reads from UserDefaults
   - `static func grantConsent()` — sets UserDefaults to true
   - `static func revokeConsent()` — removes key
2. Accept optional `UserDefaults` parameter for test isolation

**Acceptance**:
- `consentGiven` is `false` initially
- After `grantConsent()`, `consentGiven` is `true`
- After `revokeConsent()`, `consentGiven` is `false`

---

## T5 — Update `TTSEngine`, `TTSEngineSelector`, and `AVSpeechService`

**Files**:
- `TranslateCall/Core/TTS/TTSEngine.swift` (MODIFY)
- `TranslateCall/Core/TTS/TTSEngineSelector.swift` (MODIFY)
- `TranslateCall/Core/TTS/AVSpeechService.swift` (MODIFY)

**Steps**:

### TTSEngine.swift
1. Add `.edgeTTS` case
2. Update `displayName`: `"Edge TTS (Cloud)"`
3. Update `supports(locale:)`: delegate to `EdgeTTSVoiceCatalog.supports(locale)`

### AVSpeechService.swift
1. Add static helper:
   ```swift
   nonisolated static func hasVoice(for locale: Locale) -> Bool
   ```
   - Get language prefix from locale (2-letter code)
   - Check `AVSpeechSynthesisVoice.speechVoices()` for any voice matching that prefix
   - Return true if at least one voice exists

### TTSEngineSelector.swift
1. Add factory property:
   ```swift
   var edgeTTSFactory: (AudioDeviceID?, String) throws -> any SynthesisService = { deviceID, voice in
       try EdgeTTSService(outputDeviceID: deviceID, voiceName: voice)
   }
   ```
2. Add published property:
   - `@Published var edgeTTSConsentGiven: Bool` — initialized from `EdgeTTSConsentManager.consentGiven`
3. Update `makeOutgoingService(for:deviceID:)`:
   - After Voice Clone and Kokoro checks:
   - If `AVSpeechService.hasVoice(for: locale)` → return avSpeechFactory
   - Else if `edgeTTSConsentGiven`, let `voice = EdgeTTSVoiceCatalog.defaultVoice(for: locale)` → return edgeTTSFactory
   - Else → return avSpeechFactory (silent fallback, UI should prompt consent)
4. Update `makeIncomingService(for:deviceID:)`:
   - Same logic: AVSpeech if voice exists, else Edge TTS if consented
5. Add `var needsEdgeTTSConsent: Bool`:
   - `true` if current locale has no AVSpeech voice AND consent not given
6. Add `func grantEdgeTTSConsent()`:
   - `EdgeTTSConsentManager.grantConsent()`
   - `edgeTTSConsentGiven = true`

**Acceptance**:
- `TTSEngine.edgeTTS` in `allCases`
- `AVSpeechService.hasVoice(for: Locale(identifier: "uk"))` returns `false`
- `AVSpeechService.hasVoice(for: Locale(identifier: "en"))` returns `true`
- Selector returns Edge TTS for Ukrainian when consented
- Selector returns AVSpeech (silent) for Ukrainian when not consented
- `needsEdgeTTSConsent` is `true` for Ukrainian locale without consent

---

## T6 — UI: Consent Dialog and Cloud Badge

**Files**:
- `TranslateCall/Features/Main/ContentView.swift` (MODIFY)
- `TranslateCall/Features/Main/TranscriptionView.swift` (MODIFY — optional badge)

**Steps**:

### Consent Dialog
1. In `ContentView`, observe `ttsEngineSelector.needsEdgeTTSConsent`
2. Show `.alert` when Edge TTS consent needed:
   ```
   Title: "Cloud TTS Required"
   Message: "No voice is available for [Language] on this device.
             Enable Cloud TTS? Text will be sent to Microsoft for speech synthesis."
   Buttons: "Enable" → grantEdgeTTSConsent(), "Not Now" → dismiss
   ```
3. Show alert once per session (use `@State` flag to avoid repeated prompts)

### Cloud Badge
1. In the TTS status area, show cloud icon when Edge TTS is active:
   ```swift
   if isUsingEdgeTTS {
       Label("Cloud", systemImage: "cloud")
           .font(.caption2)
           .foregroundStyle(.secondary)
   }
   ```
2. Add `isUsingEdgeTTS` computed property to `AudioViewModel` (checks if current TTS engine is Edge TTS)

### Offline Warning
1. If no AVSpeech voice AND offline AND no Edge TTS consent:
   ```swift
   Label("TTS unavailable", systemImage: "speaker.slash")
       .foregroundStyle(.orange)
       .font(.caption2)
   ```

**Acceptance**:
- Consent dialog appears when switching to Ukrainian (or any language without AVSpeech voice)
- Cloud badge visible when Edge TTS is synthesizing
- Consent persists across app launches

---

## T7 — Tests

**File**: `TranslateCallTests/EdgeTTSTests.swift` (NEW)

**Tests**:

### EdgeTTSVoiceCatalog
1. `testUkrainianVoiceExists` — defaultVoice for "uk" returns PolinaNeural
2. `testEnglishVoicesExist` — availableVoices for "en" is non-empty
3. `testSupportsUkrainian` — true
4. `testDoesNotSupportFictionalLocale` — supports "xx" → false
5. `testAvailableVoicesMatchLocale` — all returned voices have matching locale prefix

### EdgeTTSWebSocket
6. `testBuildSSML` — verify SSML structure with voice name, prosody, text
7. `testConnectURLConstruction` — verify URL with token and ConnectionId

### EdgeTTSService
8. `testConformsSynthesisService` — protocol conformance check
9. `testSpeakEmitsIsSpeaking` — mock WebSocket, verify isSpeaking true then false
10. `testStopSpeakingEmitsFalse` — verify isSpeaking false after stop
11. `testDeactivateDisconnects` — verify WebSocket disconnect called

### EdgeTTSConsentManager
12. `testInitialConsentFalse` — fresh UserDefaults → consentGiven false
13. `testGrantConsent` — after grant, consentGiven true
14. `testRevokeConsent` — after revoke, consentGiven false

### TTSEngineSelector (Edge TTS additions)
15. `testAVSpeechHasVoiceForEnglish` — true
16. `testAVSpeechNoVoiceForUkrainian` — false (verify on macOS)
17. `testSelectorReturnsEdgeTTSForUkrainian` — consent given + no AVSpeech voice → edgeTTSFactory called
18. `testSelectorReturnsAVSpeechWhenConsentNotGiven` — no consent → avSpeechFactory called
19. `testNeedsEdgeTTSConsent` — locale has no AVSpeech voice + no consent → true
20. `testNeedsEdgeTTSConsentFalseForEnglish` — English has AVSpeech voice → false

**Acceptance**:
- All 20 tests pass
- Zero warnings
- No real WebSocket connections in tests (mock WebSocket)
- No real AVAudioEngine in most tests (mock factories)
