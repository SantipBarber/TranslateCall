# F2.3: Text-to-Speech — Technical Design

**Feature**: Text-to-Speech Synthesis
**Milestone**: M2 — Speech Pipeline
**Status**: DRAFT — awaiting Gate 2 review
**Date**: 2026-03-07
**Prerequisites**: requirements.md (Gate 1 approved)

---

## 1. Key Design Decisions

### 1.1 `write(_:toBufferCallback:)` instead of `speak(_:)`

> Cupertino finding: `AVSpeechSynthesizer.write(_:toBufferCallback:)` is available macOS 10.15+ — within our deployment target (15.0).

`speak(_:)` always routes audio to the system default output and cannot be redirected. `write(_:toBufferCallback:)` delivers raw PCM buffers (as `AVAudioBuffer`) which we schedule on an `AVAudioPlayerNode` connected to an `AVAudioEngine`. This lets M4 redirect output to BlackHole by simply changing the engine's output device — no API change.

```swift
synthesizer.write(utterance) { [weak self] buffer in
    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
    self?.playerNode.scheduleBuffer(pcm, completionHandler: nil)
}
```

### 1.2 Actor-based `SynthesisService` protocol

Same isolation pattern as `VADService` and `SpeechRecognizerService`. The actor serializes synthesis requests naturally (actor queue = synthesis queue). No explicit `OperationQueue` or `DispatchSemaphore` needed.

### 1.3 `AVSpeechSynthesizer` is not actor-safe — wrap with `nonisolated(unsafe)`

`AVSpeechSynthesizer` is not `Sendable`. It must live on a single thread. As an actor-isolated `var`, it is always accessed from the actor's executor — safe. Declare as plain `private var synthesizer: AVSpeechSynthesizer` (actor-isolated).

The `write(_:toBufferCallback:)` callback, however, arrives on an arbitrary background thread. We bridge it back to the actor using `Task { await self.scheduleBuffer(pcm) }`.

### 1.4 Voice selection: `.premium` > `.enhanced` > `.default`

> **Tavily finding**: iOS 16 / macOS 13 added `.premium` as a third quality tier above `.enhanced`. Users download them via Settings > Accessibility > Spoken Content > Voices. Our deployment target (macOS 15.0) fully supports `.premium`.

```swift
func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
    let lang = String(locale.identifier.replacingOccurrences(of: "_", with: "-").prefix(2))
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
    return voices.first(where: { $0.quality == .premium })
        ?? voices.first(where: { $0.quality == .enhanced })
        ?? voices.first   // .default fallback
}
```

`AVSpeechSynthesisVoice.speechVoices()` returns all installed voices. No internet required.

### 1.5 Synthesis + playback in the same `AVAudioEngine`

A separate `AVAudioEngine` dedicated to TTS output avoids any interference with `AudioManager`'s capture engine (REQ-NFR-TTS-04). The TTS engine has:
- One `AVAudioPlayerNode` for scheduling PCM buffers
- Connected to `engine.outputNode` (system default in M2, specific device in M4)

### 1.6 Completion detection via `AVSpeechSynthesizerDelegate`

`write(_:toBufferCallback:)` does not provide a synthesis-complete callback on its own. We use `AVSpeechSynthesizerDelegate.speechSynthesizer(_:didFinish:)` to detect when an utterance is fully synthesized and all buffers have been scheduled.

---

## 2. Architecture Overview

```
AudioViewModel (@MainActor)
  speak(text:locale:) ──────────────────────────────────────▶ AVSpeechService (actor)
  @Published isSpeaking ◀── isSpeakingStream (AsyncStream<Bool>)   │
                                                                     │
                              ┌──────────────────────────────────────┤
                              │  AVSpeechSynthesizer                 │
                              │  .write(utterance) { pcmBuffer in    │
                              │      playerNode.scheduleBuffer(pcm)  │
                              │  }                                   │
                              │                                      │
                              │  AVAudioEngine                       │
                              │  ├── AVAudioPlayerNode               │
                              │  └── outputNode ──▶ 🔊 Speaker       │
                              └──────────────────────────────────────┘
```

---

## 3. Type Definitions

### 3.1 `SynthesisConfiguration`

```swift
struct SynthesisConfiguration: Sendable {
    /// Speech rate. Use AVSpeechUtteranceDefaultSpeechRate (0.5) as default.
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Pitch multiplier (0.5 – 2.0). Default: 1.0 (unchanged).
    var pitchMultiplier: Float = 1.0
    /// Volume (0.0 – 1.0). Default: 1.0.
    var volume: Float = 1.0

    static let `default` = SynthesisConfiguration()
}
```

### 3.2 `STSError`

```swift
enum STSError: LocalizedError {
    case voiceUnavailable(Locale)
    case engineStartFailed(Error)
}
```

### 3.3 `SynthesisService` protocol

```swift
protocol SynthesisService: Actor {
    /// `true` when speaking, `false` when idle. Set in init().
    nonisolated var isSpeakingStream: AsyncStream<Bool> { get }

    /// Synthesize and play text in the given locale. Queued if already speaking.
    func speak(text: String, locale: Locale) async

    /// Immediately stop current utterance and clear queue.
    func stopSpeaking() async

    /// Stop synthesis, clear queue, stop audio engine.
    func deactivate() async
}
```

---

## 4. `AVSpeechService` — Implementation Design

### 4.1 Initialization

```swift
actor AVSpeechService: SynthesisService, AVSpeechSynthesizerDelegate {
    nonisolated let isSpeakingStream: AsyncStream<Bool>

    private var speakingContinuation: AsyncStream<Bool>.Continuation?
    private let config: SynthesisConfiguration

    // Audio engine (actor-isolated)
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var synthesizer = AVSpeechSynthesizer()

    // Queue (actor-isolated)
    private var utteranceQueue: [(text: String, locale: Locale)] = []
    private var isSynthesizing = false

    init(config: SynthesisConfiguration = .default) throws {
        self.config = config
        var cont: AsyncStream<Bool>.Continuation?
        isSpeakingStream = AsyncStream { cont = $0 }
        speakingContinuation = cont

        // Wire audio engine
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.outputNode,
                       format: engine.outputNode.outputFormat(forBus: 0))
        try engine.start()

        // Set delegate after init — safe because no async work yet
        synthesizer.delegate = self  // delegate is a weak reference in ObjC
    }
}
```

> **Note on `AVSpeechSynthesizerDelegate`**: The delegate is an ObjC protocol. Setting `synthesizer.delegate = self` inside an actor `init` is safe because no synthesis has started yet and no callbacks can arrive before `init` completes.

### 4.2 Speaking

```swift
func speak(text: String, locale: Locale) async {
    utteranceQueue.append((text: text, locale: locale))
    if !isSynthesizing {
        await processNextUtterance()
    }
}

private func processNextUtterance() async {
    guard !utteranceQueue.isEmpty, !isSynthesizing else { return }
    let (text, locale) = utteranceQueue.removeFirst()

    guard let voice = bestVoice(for: locale) else {
        // No voice for locale — skip silently, log
        return
    }

    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    utterance.rate = config.rate
    utterance.pitchMultiplier = config.pitchMultiplier
    utterance.volume = config.volume

    isSynthesizing = true
    speakingContinuation?.yield(true)

    synthesizer.write(utterance) { [weak self] buffer in
        guard let self, let pcm = buffer as? AVAudioPCMBuffer,
              pcm.frameLength > 0 else { return }
        Task { await self.scheduleBuffer(pcm) }
    }
    // Completion detected via delegate (didFinish:)
}

private func scheduleBuffer(_ pcm: AVAudioPCMBuffer) async {
    if !playerNode.isPlaying { playerNode.play() }
    playerNode.scheduleBuffer(pcm, completionHandler: nil)
}

private func bestVoice(for locale: Locale) -> AVSpeechSynthesisVoice? {
    let lang = String(locale.identifier.replacingOccurrences(of: "_", with: "-").prefix(2))
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
    return voices.first(where: { $0.quality == .enhanced })
        ?? voices.first
}
```

### 4.3 Delegate — Completion Detection

```swift
// AVSpeechSynthesizerDelegate
nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
) {
    Task { await self.utteranceDidFinish() }
}

private func utteranceDidFinish() async {
    isSynthesizing = false
    if utteranceQueue.isEmpty {
        speakingContinuation?.yield(false)
        playerNode.stop()
    } else {
        await processNextUtterance()
    }
}
```

### 4.4 Stop and Deactivate

```swift
func stopSpeaking() async {
    utteranceQueue.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
    playerNode.stop()
    isSynthesizing = false
    speakingContinuation?.yield(false)
}

func deactivate() async {
    await stopSpeaking()
    engine.stop()
    speakingContinuation?.finish()
}
```

---

## 5. ViewModel Integration

```swift
// AudioViewModel additions
@Published var isSpeaking: Bool = false
private var synthesisService: (any SynthesisService)?
private var speakingTask: Task<Void, Never>?

func startSynthesis(text: String, locale: Locale) {
    Task { await synthesisService?.speak(text: text, locale: locale) }
}

func observeSynthesisState(_ service: any SynthesisService) {
    speakingTask?.cancel()
    speakingTask = Task { @MainActor [weak self] in
        for await active in service.isSpeakingStream {
            self?.isSpeaking = active
        }
    }
}
```

The `isSpeaking` flag integrates with `ContentView`'s status badge (F1.3): `true` → red badge "Speaking". In M4, `HalfDuplexCoordinator` will observe this to mute input.

---

## 6. File Structure

```
TranslateCall/
└── Core/
    └── TTS/
        ├── SynthesisService.swift      // protocol + SynthesisConfiguration + STSError
        └── AVSpeechService.swift       // AVSpeechSynthesizer implementation

TranslateCallTests/
└── TTSServiceTests.swift              // Unit tests
```

---

## 7. Threading and Swift 6 Compliance

| Concern | Solution |
|---------|---------|
| `AVSpeechSynthesizer` not Sendable | Actor-isolated `var` — always accessed from actor executor |
| `write(_:toBufferCallback:)` callback on background thread | Bridges to actor via `Task { await self.scheduleBuffer(pcm) }` |
| `AVSpeechSynthesizerDelegate` callbacks on arbitrary thread | `nonisolated func` + `Task { await self.utteranceDidFinish() }` |
| `AVAudioPlayerNode.scheduleBuffer` thread safety | Called from actor only (via Task bridge) |
| `isSpeakingStream` across actor boundary to ViewModel | `nonisolated let`, `Sendable` AsyncStream |
| `AVAudioEngine` start throws | Propagated from `init` as `throws` |

---

## 8. Error Handling

| Error | Behavior |
|-------|---------|
| `AVAudioEngine.start()` fails | `init` throws `STSError.engineStartFailed`; ViewModel shows alert; TTS not available |
| No voice for locale | Utterance skipped; logged via `os_log`; no crash; queue advances (AC-TTS-07) |
| `write(_:toBufferCallback:)` delivers zero-length buffer | Buffer ignored (guard on `pcm.frameLength > 0`) |
| `scheduleBuffer` while engine stopped | Guard `playerNode.play()` before scheduling |

---

## 9. Future Extensibility (M4)

To route to BlackHole in M4, the only change needed is setting the engine's output device:

```swift
// M4: route to specific output device
let audioDevice: AudioDeviceID = ...  // BlackHole device ID from AudioManager
try engine.outputNode.audioUnit?.setProperty(...)
// OR: use CoreAudio kAudioDevicePropertyDefaultOutputDevice
```

All synthesis and scheduling logic remains unchanged. This is why `write(_:toBufferCallback:)` was chosen over `speak(_:)` from the start.

---

*Gate 2 Review: human must approve this document before tasks.md is written.*
