# F8.2 — Multi-Engine TTS Fallback — Technical Design

## 1. Technology Decision: Custom Edge TTS Client

**Chosen**: Custom WebSocket implementation of Edge TTS protocol

| Option | Integration | Quality | Offline | Risk | Decision |
|--------|------------|---------|---------|------|----------|
| Edge TTS (custom WebSocket) | ~200 LOC | High (Neural) | No | Medium (unofficial API) | **CHOSEN** |
| Edge-TTS Swift lib | Archived | High | No | High (unmaintained) | Rejected |
| Piper via sherpa-onnx | CMake build | Medium | Yes | Medium | **DEFERRED** — optional future |
| macOS system voices | None needed | Low-Medium | Yes | None | Already have (AVSpeech) |

**Rationale**: Edge TTS provides 400+ neural voices across 100+ languages with no API key. The protocol is simple (~200 lines to implement). The risk of Microsoft changing the endpoint is real but acceptable — we use it only as a fallback when AVSpeech has no voice, so breakage degrades gracefully to text-only output.

**Piper deferred**: Integration via sherpa-onnx requires CMake builds and XCFramework, too heavy for M8. Can be revisited if offline TTS for unsupported languages becomes critical.

## 2. Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                      TTSEngineSelector                        │
│  Priority chain:                                              │
│  1. Voice Clone (Qwen3-TTS) — if enabled + locale supported  │
│  2. Kokoro              — if preferred + EN                   │
│  3. AVSpeech            — if voice exists for locale          │
│  4. Edge TTS            — cloud fallback for missing voices   │ ← NEW
└──────────────┬───────────────────────────────────────────────┘
               │
               ▼
┌──────────────────────────────┐     ┌──────────────────────────┐
│   EdgeTTSService             │     │  EdgeTTSVoiceCatalog     │
│   conforms: SynthesisService │     │  - availableVoices(for:) │
│                              │     │  - defaultVoice(for:)    │
│   - isSpeakingStream         │     └──────────────────────────┘
│   - speak(text:locale:)      │
│   - stopSpeaking()           │     ┌──────────────────────────┐
│   - deactivate()             │     │  EdgeTTSWebSocket        │
│                              │────▶│  - connect()             │
│   Uses: EdgeTTSWebSocket     │     │  - synthesize(ssml:)     │
│         EdgeTTSVoiceCatalog  │     │  - audioStream           │
│         AVAudioPlayerNode    │     └──────────────────────────┘
└──────────────────────────────┘
```

## 3. Edge TTS Protocol Implementation

### WebSocket Protocol (reverse-engineered from edge-tts Python/Go libraries)

**Endpoint**: `wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1`

**Query params**: `?TrustedClientToken=6A5AA1D4EAFF4E9FB37E23D68491D6F4&ConnectionId={uuid}`

**Headers**:
```
User-Agent: Mozilla/5.0 (macOS; ...) Chrome/130.0 Safari/537.36 Edg/130.0
Origin: chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold
```

**Flow**:
1. Connect WebSocket
2. Send text config message:
   ```
   Content-Type:application/json; charset=utf-8\r\n
   Path:speech.config\r\n\r\n
   {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}
   ```
3. Send SSML synthesis request:
   ```
   X-RequestId:{requestId}\r\n
   Content-Type:application/ssml+xml\r\n
   Path:ssml\r\n\r\n
   <speak version='1.0' xmlns='...' xml:lang='{lang}'>
     <voice name='{voiceName}'>
       <prosody rate='{rate}%' pitch='{pitch}Hz' volume='{volume}%'>
         {text}
       </prosody>
     </voice>
   </speak>
   ```
4. Receive binary messages (MP3 audio chunks) and text messages (metadata)
5. Audio complete when `Path:turn.end` text message arrives

### EdgeTTSWebSocket

```swift
actor EdgeTTSWebSocket {
    private var webSocket: URLSessionWebSocketTask?

    /// Connect to Edge TTS endpoint. Reuses connection across calls.
    func connect() async throws

    /// Synthesize text. Returns AsyncStream of audio Data chunks (MP3).
    func synthesize(
        text: String,
        voice: String,
        rate: Int = 0,       // -100 to +100 percent
        pitch: Int = 0,      // -100 to +100 Hz
        volume: Int = 0      // -100 to +100 percent
    ) -> AsyncThrowingStream<Data, Error>

    /// Close WebSocket connection.
    func disconnect()
}
```

### Audio Format

Edge TTS returns MP3 audio (24 kHz, mono). We need to decode and play it:

```
MP3 chunks from WebSocket
    │
    ▼
AVAudioFile or AudioConverter (MP3 → PCM)
    │  Use AVAudioCompressedBuffer + AVAudioConverter
    │  or write chunks to temp file + AVAudioFile
    ▼
AVAudioPCMBuffer (24 kHz mono Float32)
    │
    ▼
AVAudioConverter SRC → output device format
    │
    ▼
AVAudioPlayerNode.scheduleBuffer()
```

**MP3 decoding approach**: Accumulate MP3 data in a buffer. Use `AVAudioFile` with a temporary file, or use `AVAudioCompressedBuffer` with `AVAudioConverter` for streaming decode. The temp file approach is simpler and proven:

1. Write MP3 data to a temp file as chunks arrive
2. Open with `AVAudioFile(forReading:)` once enough data accumulates
3. Read PCM frames and schedule on player node
4. For streaming feel: decode in 0.5s chunks (every ~6KB of MP3 at 48kbps)

## 4. EdgeTTSService — Implementation Design

```swift
actor EdgeTTSService: SynthesisService {
    nonisolated let isSpeakingStream: AsyncStream<Bool>
    private var speakingContinuation: AsyncStream<Bool>.Continuation?

    private let outputDeviceID: AudioDeviceID?
    private let voiceName: String
    nonisolated(unsafe) private var engine: AVAudioEngine?
    nonisolated(unsafe) private var playerNode: AVAudioPlayerNode?
    private let webSocket: EdgeTTSWebSocket

    init(outputDeviceID: AudioDeviceID? = nil, voiceName: String) throws

    func speak(text: String, locale: Locale) async {
        // 1. Emit isSpeaking = true
        // 2. Connect WebSocket if needed
        // 3. Send SSML with text + voiceName
        // 4. Receive MP3 chunks, decode to PCM, schedule on player
        // 5. Wait for turn.end
        // 6. Wait for player to finish
        // 7. Emit isSpeaking = false
    }

    func stopSpeaking() async {
        // Cancel current synthesis
        // Stop player node
        // Emit isSpeaking = false
    }

    func deactivate() async {
        // Stop speaking
        // Disconnect WebSocket
        // Stop engine
    }
}
```

### Streaming Playback

To achieve low latency, we don't wait for the full MP3 to arrive:

1. Accumulate MP3 data until we have ~6KB (~0.5s of audio at 48kbps)
2. Write to temp file, decode the new portion
3. Schedule PCM buffer on player node
4. Continue accumulating + decoding + scheduling
5. Player plays buffers sequentially → near-real-time output

This gives ~0.5-1s initial latency (network RTT + first chunk) instead of waiting for full synthesis.

## 5. EdgeTTSVoiceCatalog

```swift
struct EdgeTTSVoice: Sendable, Codable {
    let shortName: String      // e.g. "uk-UA-PolinaNeural"
    let locale: String         // e.g. "uk-UA"
    let gender: String         // "Female" or "Male"
    let friendlyName: String   // e.g. "Polina"
}

enum EdgeTTSVoiceCatalog {
    /// Hard-coded catalog of key voices per locale.
    /// Full list has 400+ voices; we include the most useful ones.
    static func availableVoices(for locale: Locale) -> [EdgeTTSVoice]
    static func defaultVoice(for locale: Locale) -> EdgeTTSVoice?

    /// Check if Edge TTS has ANY voice for this locale
    static func supports(_ locale: Locale) -> Bool
}
```

The catalog is a static lookup. We don't fetch the voice list from Edge TTS at runtime (avoids network dependency at startup). We include ~50 voices covering all major languages and specifically Ukrainian.

Key voices:
- `uk-UA-PolinaNeural` (Female, Ukrainian)
- `uk-UA-OstapNeural` (Male, Ukrainian)
- Plus voices for all languages missing from AVSpeech

## 6. TTSEngine & TTSEngineSelector Changes

### TTSEngine Extension

```swift
enum TTSEngine: String, Codable, Sendable, CaseIterable {
    case avSpeech
    case kokoro
    case voiceClone
    case edgeTTS      // ← NEW
}
```

### TTSEngineSelector Changes

```swift
// New factory
var edgeTTSFactory: (AudioDeviceID?, String) throws -> any SynthesisService = { deviceID, voice in
    try EdgeTTSService(outputDeviceID: deviceID, voiceName: voice)
}

// Updated makeOutgoingService:
func makeOutgoingService(for locale: Locale, deviceID: AudioDeviceID?) throws -> any SynthesisService {
    // 1. Voice Clone
    if voiceCloningActive, let profileId = activeVoiceProfileId,
       QwenCloneConfiguration.supportsLocale(locale) {
        return try voiceCloneFactory(deviceID, profileId, profileStore)
    }
    // 2. Kokoro (English)
    if preferredEngine == .kokoro && kokoroAvailable && locale.isEnglish {
        return try kokoroFactory(deviceID, .default)
    }
    // 3. AVSpeech (if voice exists)
    if AVSpeechService.hasVoice(for: locale) {
        return try avSpeechFactory(deviceID)
    }
    // 4. Edge TTS (cloud fallback)
    if let voice = EdgeTTSVoiceCatalog.defaultVoice(for: locale) {
        return try edgeTTSFactory(deviceID, voice.shortName)
    }
    // 5. Last resort: AVSpeech anyway (will be silent but won't crash)
    return try avSpeechFactory(deviceID)
}
```

### AVSpeech Voice Detection

Add a static helper to `AVSpeechService`:

```swift
extension AVSpeechService {
    /// Returns true if AVSpeechSynthesizer has at least one voice for this locale.
    nonisolated static func hasVoice(for locale: Locale) -> Bool {
        let langCode = locale.identifier.replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: "-").prefix(2).joined(separator: "-")
        return !AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(langCode.prefix(2).description) }
            .isEmpty
    }
}
```

## 7. Privacy Consent

Edge TTS sends text to Microsoft servers. We need a one-time consent dialog:

```swift
struct EdgeTTSConsentManager {
    private static let consentKey = "tlk.edgeTTS.consentGiven"

    static var consentGiven: Bool {
        UserDefaults.standard.bool(forKey: consentKey)
    }

    static func grantConsent() {
        UserDefaults.standard.set(true, forKey: consentKey)
    }
}
```

In `TTSEngineSelector.makeOutgoingService()`, before returning Edge TTS, check consent. If not given, the caller (AudioCoordinator) should show the consent dialog. Flow:

1. Selector detects Edge TTS is needed (no AVSpeech voice)
2. If consent not given → return AVSpeech (silent) + set flag to show consent prompt
3. UI shows: "No voice available for [Language]. Enable Cloud TTS? Text will be sent to Microsoft for synthesis."
4. User accepts → `EdgeTTSConsentManager.grantConsent()`
5. Next synthesis → Edge TTS is used

## 8. UI Indicators

### Cloud TTS Badge

When Edge TTS is active, show a small cloud icon next to the TTS engine name:

```swift
if isUsingEdgeTTS {
    Label("Cloud TTS", systemImage: "cloud")
        .font(.caption2)
        .foregroundStyle(.secondary)
}
```

### Fallback Warning

When offline + no AVSpeech voice + no Edge TTS:
```swift
Label("TTS unavailable for \(languageName)", systemImage: "speaker.slash")
    .foregroundStyle(.orange)
```

## 9. File Structure

```
TranslateCall/Core/TTS/
├── AVSpeechService.swift            (MODIFY — add hasVoice(for:))
├── KokoroConfiguration.swift        (existing)
├── KokoroModelManager.swift         (existing)
├── KokoroSpeechService.swift        (existing)
├── SynthesisService.swift           (existing)
├── TTSEngine.swift                  (MODIFY — add .edgeTTS)
├── TTSEngineSelector.swift          (MODIFY — add Edge TTS routing)
├── TTSMetrics.swift                 (existing, no change)
├── TTSMetricsCollector.swift        (existing, no change)
├── EdgeTTSService.swift             (NEW)
├── EdgeTTSWebSocket.swift           (NEW)
├── EdgeTTSVoiceCatalog.swift        (NEW)
└── EdgeTTSConsentManager.swift      (NEW)
```

## 10. Testing Strategy

| Test | Type | Description |
|------|------|-------------|
| EdgeTTSWebSocketTests | Unit | Mock URLSession, verify SSML generation, message parsing |
| EdgeTTSServiceTests | Unit | Protocol conformance, isSpeaking stream, speak/stop lifecycle |
| EdgeTTSVoiceCatalogTests | Unit | Voice lookup for 10+ locales, Ukrainian presence |
| TTSEngineSelectorEdgeTests | Unit | Fallback chain: AVSpeech has no voice → Edge TTS returned |
| AVSpeechHasVoiceTests | Unit | Voice detection for common + uncommon locales |
| EdgeTTSConsentTests | Unit | Consent state management |
| Integration | Manual | Real WebSocket connection, Ukrainian synthesis, audio playback |

Mock strategy: `EdgeTTSService` receives `EdgeTTSWebSocket` via init. Tests inject a mock WebSocket that returns pre-recorded MP3 data.

## 11. Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Microsoft changes Edge TTS endpoint/token | Graceful degradation to text-only; endpoint is configurable; monitor edge-tts community for updates |
| MP3 decoding latency too high | Use streaming decode (0.5s chunks); if still slow, switch to `audio-24khz-96kbitrate-mono-mp3` format |
| Network latency > 2s | Streaming playback starts before full response; acceptable for fallback use |
| Edge TTS rate limiting | Unlikely for single-user app; add exponential backoff if 429 errors appear |
| Privacy concerns | One-time consent dialog; clear disclosure; Edge TTS only used when no local voice exists |
