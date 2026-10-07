# TranslateCall - Technical Architecture

## 🏗️ System Architecture Overview

TranslateCall uses a layered architecture with clear separation of concerns, enabling maintainability, testability, and future extensibility.

```
┌─────────────────────────────────────────────────────────────────┐
│                     UI LAYER (SwiftUI)                          │
├─────────────────────────────────────────────────────────────────┤
│                  VIEW MODELS (MVVM)                             │
├─────────────────────────────────────────────────────────────────┤
│                    BUSINESS LOGIC                               │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐       │
│  │  Translation │  │     Voice    │  │     Audio       │       │
│  │  Coordinator │  │  Coordinator │  │   Coordinator   │       │
│  └──────────────┘  └──────────────┘  └─────────────────┘       │
├─────────────────────────────────────────────────────────────────┤
│                     CORE SERVICES                               │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐       │
│  │   Audio      │  │  Recognition │  │  Translation    │       │
│  │   Manager    │  │   Service    │  │    Service      │       │
│  └──────────────┘  └──────────────┘  └─────────────────┘       │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────┐       │
│  │  Synthesis   │  │    Voice     │  │     Delay       │       │
│  │   Service    │  │   Profile    │  │    Manager      │       │
│  └──────────────┘  └──────────────┘  └─────────────────┘       │
│  ┌──────────────┐                                               │
│  │     VAD      │  ← NEW: FluidAudio Silero                    │
│  │   Service    │                                               │
│  └──────────────┘                                               │
├─────────────────────────────────────────────────────────────────┤
│                    FRAMEWORK LAYER                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Apple: AVFoundation | Speech | Translation | Accelerate │   │
│  ├─────────────────────────────────────────────────────────┤   │
│  │ Third-Party: FluidAudio | MLX-Audio | whisper.cpp       │   │
│  └─────────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────────┤
│                 VIRTUAL AUDIO DRIVER                            │
│                    (BlackHole)                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🎯 Core Components

### 1. Audio Layer

#### AudioManager
Central hub for all audio I/O operations.

```swift
class AudioManager {
    // Audio Engine
    private let engine: AVAudioEngine
    private let inputNode: AVAudioInputNode
    private let outputNode: AVAudioOutputNode
    
    // Device Management
    private var physicalMicDevice: AudioDeviceID?
    private var virtualMicDevice: AudioDeviceID?
    private var outputDevice: AudioDeviceID?
    
    // Buffer Management
    private var audioBufferQueue: AsyncStream<AVAudioPCMBuffer>
    
    // Public API
    func startCapture() -> AsyncStream<AVAudioPCMBuffer>
    func stopCapture()
    func playAudio(_ buffer: AVAudioPCMBuffer) async
    func configureDevices(input: AudioDeviceID, output: AudioDeviceID) throws
    
    // Device Discovery
    func getInputDevices() -> [AudioDevice]
    func getOutputDevices() -> [AudioDevice]
}
```

**Technical Specifications**:
```yaml
Sample Rate: 48000 Hz (video calls) / 16000 Hz (ML models)
Bit Depth: 32-bit float
Channels: 1 (mono) for speech processing
Buffer Size: 4096 frames (~85ms at 48kHz)
Format: PCM Linear Float32
```

#### VirtualDeviceManager
Manages BlackHole virtual audio devices.

```swift
class VirtualDeviceManager {
    // Installation
    func isBlackHoleInstalled() -> Bool
    func installBlackHole() async throws
    
    // Device Configuration
    func configureVirtualMicrophone() throws -> AudioDeviceID
    func configureVirtualSpeaker() throws -> AudioDeviceID
    
    // Discovery
    func findBlackHoleDevices() -> [AudioDeviceID]
}
```

#### DelayManager
Manages audio synchronization and buffering.

```swift
class DelayManager {
    private var delayMs: Int
    private var audioQueue: [(buffer: AVAudioPCMBuffer, playAt: Date)]
    
    func configure(delayMs: Int)
    func enqueue(_ buffer: AVAudioPCMBuffer)
    func dequeueReady() -> AVAudioPCMBuffer?
    func getCurrentLatency() -> TimeInterval
    func autoCalibrate() async
}
```

**Latency Budget**:
```
Total Target: 2000-3000ms

Breakdown:
├─ VAD Detection:        100ms
├─ Speech Recognition:   500-800ms
├─ Translation:          300-600ms
├─ Speech Synthesis:     400-600ms
├─ Voice Style Transfer: 200-400ms
└─ Buffer/Network:       200-400ms
```

---

### 2. Voice Activity Detection (VAD) Layer

#### VADService Protocol

```swift
protocol VADService {
    func startDetection(audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<VADEvent>
    func stopDetection()
    var isDetecting: Bool { get }
}

enum VADEvent {
    case speechStarted(at: TimeInterval)
    case speechEnded(at: TimeInterval)
    case probabilityUpdate(Float)
}
```

#### FluidAudioVAD (Primary - Recommended)

```swift
import FluidAudio

class FluidAudioVAD: VADService {
    private let manager: VadManager
    private var state: VadStreamState
    
    init() async throws {
        self.manager = try await VadManager()
        self.state = await manager.makeStreamState()
    }
    
    func startDetection(audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<VADEvent> {
        AsyncStream { continuation in
            Task {
                for await buffer in audioStream {
                    let samples = buffer.toFloat32Array()
                    
                    let result = try await manager.processStreamingChunk(
                        samples,
                        state: state,
                        config: .default,
                        returnSeconds: true
                    )
                    
                    state = result.state
                    
                    continuation.yield(.probabilityUpdate(Float(result.probability)))
                    
                    if let event = result.event {
                        switch event.kind {
                        case .speechStart:
                            continuation.yield(.speechStarted(at: event.time ?? 0))
                        case .speechEnd:
                            continuation.yield(.speechEnded(at: event.time ?? 0))
                        }
                    }
                }
            }
        }
    }
}
```

**Why FluidAudio Silero VAD**:
- ✅ State-of-the-art accuracy
- ✅ Native Swift API with streaming support
- ✅ Optimized for Apple Neural Engine
- ✅ Configurable thresholds and timing
- ✅ MIT license

#### SimpleEnergyVAD (Fallback)

```swift
class SimpleEnergyVAD: VADService {
    var energyThreshold: Float = -50.0 // dB
    var silenceDuration: TimeInterval = 0.8
    var minSpeechDuration: TimeInterval = 0.3
    
    private var lastVoiceTime: Date?
    private var speechStartTime: Date?
    
    func startDetection(audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<VADEvent> {
        AsyncStream { continuation in
            Task {
                for await buffer in audioStream {
                    let energy = calculateRMSdB(buffer)
                    let isSpeech = energy > energyThreshold
                    
                    if isSpeech {
                        if speechStartTime == nil {
                            speechStartTime = Date()
                            continuation.yield(.speechStarted(at: 0))
                        }
                        lastVoiceTime = Date()
                    } else if let lastVoice = lastVoiceTime,
                              Date().timeIntervalSince(lastVoice) > silenceDuration {
                        if speechStartTime != nil {
                            continuation.yield(.speechEnded(at: 0))
                            speechStartTime = nil
                        }
                    }
                }
            }
        }
    }
    
    private func calculateRMSdB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return -100 }
        let frameLength = Int(buffer.frameLength)
        
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(frameLength))
        
        return 20 * log10(rms + 1e-10)
    }
}
```

---

### 3. Speech Recognition Layer

#### SpeechRecognizerService Protocol

```swift
protocol SpeechRecognizerService {
    var supportedLanguages: [Language] { get }
    
    func startRecognition(language: Language, audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<RecognitionResult>
    func stopRecognition()
}

struct RecognitionResult {
    let text: String
    let isFinal: Bool
    let confidence: Float
    let language: Language
}
```

#### AppleSpeechRecognizer (Primary - MVP)

```swift
import Speech

class AppleSpeechRecognizer: SpeechRecognizerService {
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    
    var supportedLanguages: [Language] {
        SFSpeechRecognizer.supportedLocales()
            .compactMap { Language(locale: $0) }
    }
    
    func startRecognition(language: Language, audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<RecognitionResult> {
        AsyncStream { continuation in
            recognizer = SFSpeechRecognizer(locale: language.locale)
            
            guard let recognizer = recognizer, recognizer.isAvailable else {
                continuation.finish()
                return
            }
            
            request = SFSpeechAudioBufferRecognitionRequest()
            request?.requiresOnDeviceRecognition = true
            request?.shouldReportPartialResults = true
            
            recognitionTask = recognizer.recognitionTask(with: request!) { result, error in
                if let result = result {
                    continuation.yield(RecognitionResult(
                        text: result.bestTranscription.formattedString,
                        isFinal: result.isFinal,
                        confidence: result.bestTranscription.segments.last?.confidence ?? 0,
                        language: language
                    ))
                }
                
                if result?.isFinal == true || error != nil {
                    continuation.finish()
                }
            }
            
            // Feed audio buffers
            Task {
                for await buffer in audioStream {
                    request?.append(buffer)
                }
                request?.endAudio()
            }
        }
    }
}
```

#### FluidAudioRecognizer (Phase 2 - European Languages)

```swift
import FluidAudio

class FluidAudioRecognizer: SpeechRecognizerService {
    private var asrManager: AsrManager?
    private var streamingManager: StreamingAsrManager?
    
    var supportedLanguages: [Language] {
        // 25 European languages
        [.english, .spanish, .french, .german, .italian, .portuguese,
         .dutch, .polish, .russian, .ukrainian, .czech, .romanian,
         .hungarian, .bulgarian, .croatian, .slovak, .slovenian,
         .lithuanian, .latvian, .estonian, .finnish, .swedish,
         .norwegian, .danish, .greek]
    }
    
    func startRecognition(language: Language, audioStream: AsyncStream<AVAudioPCMBuffer>) -> AsyncStream<RecognitionResult> {
        AsyncStream { continuation in
            Task {
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                streamingManager = StreamingAsrManager(config: .streaming)
                try await streamingManager?.initialize(models: models)
                
                // Process updates
                Task {
                    guard let updates = streamingManager?.transcriptionUpdates else { return }
                    for await update in updates {
                        continuation.yield(RecognitionResult(
                            text: update.text,
                            isFinal: update.isConfirmed,
                            confidence: Float(update.confidence),
                            language: language
                        ))
                    }
                }
                
                // Feed audio
                for await buffer in audioStream {
                    streamingManager?.streamAudio(buffer)
                }
                
                let final = try await streamingManager?.finish()
                if let text = final {
                    continuation.yield(RecognitionResult(
                        text: text,
                        isFinal: true,
                        confidence: 1.0,
                        language: language
                    ))
                }
                continuation.finish()
            }
        }
    }
}
```

#### RecognizerFactory

```swift
class RecognizerFactory {
    static func createRecognizer(for language: Language, preferAccuracy: Bool = false) -> SpeechRecognizerService {
        let europeanLanguages: Set<Language> = [
            .english, .spanish, .french, .german, .italian, .portuguese,
            .dutch, .polish, .russian /* ... */
        ]
        
        if preferAccuracy && europeanLanguages.contains(language) {
            // FluidAudio has better accuracy for European languages
            return FluidAudioRecognizer()
        }
        
        // Apple Speech for broader language support
        return AppleSpeechRecognizer()
    }
}
```

---

### 4. Translation Layer

#### TranslationService

See [TranslationBridge (F8.5.4)](#translationbridge-f854) below for the current design.

#### TranslationBridge (F8.5.4)

`TranslationSession` has no public initializer on macOS 15: it only exists inside SwiftUI's
`.translationTask`. Each direction has a `TranslationBridgeModel` whose `TranslationBridge` view lives in
`TranslationHostWindow`, an off-screen borderless window owned by `AppContainer` — translation keeps
working with the main window closed.

```
AudioCoordinator ─► AppleTranslationService ─► TranslationBridgeModel (FIFO queue, watchdog)
                                                   │ configuration: pair change / warm-up / rebuild only
                                                   ▼
                    TranslationHostWindow ─► TranslationBridge ─ .translationTask { run(session:) }
```

- **One session per direction, kept open.** `run(session:)` serves queued requests until the
  configuration changes; it never invalidates per sentence.
- **Pack check, then warm-up at Start.** A call does not start unless both directions' packs are
  installed (the hidden bridges cannot show the download sheet; the user gets "Languages Not
  Downloaded"). The first translation of a pair costs ~0.8–1.1 s (model load); at Start each bridge
  opens its session and translates a one-word probe, which brings the first sentence down to
  ~0.2–0.45 s. Later sentences cost ~250–450 ms: that is model inference, not session set-up (measured
  in F8.5.4, `TranslationLatencyTests`).
- **Bounded.** The request being served has a 5 s watchdog: one retry on a rebuilt session, then
  `TranslationError.timedOut`. The coordinator skips that sentence with a notice; only configuration
  errors (unsupported pair, models not downloaded) raise an alert, once per session.
- **Downloads** use a separate `.translationTask` on `LanguagePairView`, so the system sheet appears
  in the main window.

---

### 5. Speech Synthesis Layer

#### SynthesisService Protocol

```swift
protocol SynthesisService {
    func synthesize(text: String, language: Language, voice: Voice?) async throws -> AVAudioPCMBuffer
    func getAvailableVoices(for language: Language) -> [Voice]
}

struct Voice {
    let id: String
    let name: String
    let language: Language
    let quality: VoiceQuality
}

enum VoiceQuality {
    case standard
    case enhanced
    case premium
}
```

#### AppleSynthesizer (MVP)

```swift
import AVFoundation

class AppleSynthesizer: SynthesisService {
    private let synthesizer = AVSpeechSynthesizer()
    
    func synthesize(text: String, language: Language, voice: Voice?) async throws -> AVAudioPCMBuffer {
        return try await withCheckedThrowingContinuation { continuation in
            let utterance = AVSpeechUtterance(string: text)
            
            if let voice = voice {
                utterance.voice = AVSpeechSynthesisVoice(identifier: voice.id)
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: language.code)
            }
            
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            
            var audioBuffers: [AVAudioPCMBuffer] = []
            
            synthesizer.write(utterance) { buffer in
                if let pcmBuffer = buffer as? AVAudioPCMBuffer {
                    audioBuffers.append(pcmBuffer)
                }
            }
            
            // Combine buffers
            let combined = combineBuffers(audioBuffers)
            continuation.resume(returning: combined)
        }
    }
    
    func getAvailableVoices(for language: Language) -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language.code) }
            .map { Voice(
                id: $0.identifier,
                name: $0.name,
                language: language,
                quality: mapQuality($0.quality)
            )}
    }
}
```

#### MLXAudioSynthesizer (Phase 2)

```swift
class MLXAudioSynthesizer: SynthesisService {
    private let serverURL: URL
    
    init(serverURL: URL = URL(string: "http://localhost:8000")!) {
        self.serverURL = serverURL
    }
    
    func synthesize(text: String, language: Language, voice: Voice?) async throws -> AVAudioPCMBuffer {
        var request = URLRequest(url: serverURL.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        
        let formData = MultipartFormData()
        formData.append(text, withName: "text")
        formData.append(voice?.id ?? "af_heart", withName: "voice")
        formData.append("1.0", withName: "speed")
        
        request.httpBody = formData.encode()
        request.setValue(formData.contentType, forHTTPHeaderField: "Content-Type")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decodeAudioBuffer(from: data)
    }
}
```

---

### 6. Voice Cloning Layer

#### VoiceProfileManager

```swift
class VoiceProfileManager {
    private let storage: VoiceProfileStorage
    
    func createProfile(for language: Language) -> VoiceProfile {
        VoiceProfile(id: UUID(), language: language, createdAt: Date())
    }
    
    func saveProfile(_ profile: VoiceProfile) async throws {
        try await storage.save(profile)
    }
    
    func loadProfile(for language: Language) async -> VoiceProfile? {
        await storage.load(for: language)
    }
    
    func deleteProfile(id: UUID) async throws {
        try await storage.delete(id: id)
    }
}
```

#### VoiceProfile

```swift
struct VoiceProfile: Codable {
    let id: UUID
    let language: Language
    let createdAt: Date
    var updatedAt: Date
    
    // Pitch Characteristics
    var fundamentalFrequency: Float      // Average F0 in Hz
    var pitchRange: ClosedRange<Float>   // Min-max F0
    var pitchVariability: Float          // Std deviation
    
    // Timbre Characteristics
    var formants: [Float]                // F1, F2, F3, F4 (Hz)
    var mfcc: [Float]                    // 13 MFCC coefficients
    var spectralCentroid: Float
    
    // Prosody Characteristics
    var speakingRate: Float              // Syllables per second
    var averagePauseDuration: Float
    
    // Training Data
    var sampleURLs: [URL]
    var qualityScore: Float              // 0-1
    
    // For MLX-Audio CSM (Phase 2)
    var referenceAudioURL: URL?          // 30-sec reference for neural cloning
}
```

#### VoiceStyleTransfer (MVP - DSP)

```swift
import Accelerate

class DSPVoiceStyleTransfer {
    func apply(profile: VoiceProfile, to buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        var processed = buffer
        
        // 1. Pitch shifting to match profile
        processed = applyPitchShift(processed, targetF0: profile.fundamentalFrequency)
        
        // 2. Time stretching for speaking rate
        processed = applyTimeStretch(processed, targetRate: profile.speakingRate)
        
        // 3. Formant shaping via EQ
        processed = applyFormantEQ(processed, formants: profile.formants)
        
        // 4. Energy normalization
        processed = normalizeEnergy(processed)
        
        return processed
    }
    
    private func applyPitchShift(_ buffer: AVAudioPCMBuffer, targetF0: Float) -> AVAudioPCMBuffer {
        let currentF0 = extractPitch(buffer)
        let shiftCents = 1200 * log2(targetF0 / currentF0)
        
        let timePitch = AVAudioUnitTimePitch()
        timePitch.pitch = shiftCents
        timePitch.rate = 1.0  // No time change
        
        return processThrough(buffer, unit: timePitch)
    }
}
```

#### MLXVoiceCloner (Phase 2 - Real Cloning)

```swift
class MLXVoiceCloner {
    private let serverURL: URL
    
    func clone(text: String, referenceAudioURL: URL) async throws -> AVAudioPCMBuffer {
        var request = URLRequest(url: serverURL.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        
        let formData = MultipartFormData()
        formData.append(text, withName: "text")
        formData.append("mlx-community/csm-1b", withName: "model")
        
        let audioData = try Data(contentsOf: referenceAudioURL)
        formData.append(audioData, withName: "reference_audio", fileName: "ref.wav", mimeType: "audio/wav")
        
        request.httpBody = formData.encode()
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return try decodeAudioBuffer(from: data)
    }
}
```

---

### 7. Orchestration Layer

#### TranslationCoordinator

```swift
@MainActor
class TranslationCoordinator: ObservableObject {
    // Services
    private let audioManager: AudioManager
    private let vadService: VADService
    private let recognizerService: SpeechRecognizerService
    private let translationService: TranslationService
    private let synthesisService: SynthesisService
    private let voiceTransfer: DSPVoiceStyleTransfer
    private let delayManager: DelayManager
    
    // State
    @Published var isActive = false
    @Published var currentState: PipelineState = .idle
    @Published var lastTranscription: String = ""
    @Published var lastTranslation: String = ""
    
    // Configuration
    var config: TranslationConfig
    var voiceProfile: VoiceProfile?
    
    func start() async throws {
        isActive = true
        currentState = .listening
        
        // Start audio capture
        let audioStream = audioManager.startCapture()
        
        // Start VAD
        let vadEvents = vadService.startDetection(audioStream: audioStream)
        
        // Process VAD events
        for await event in vadEvents {
            switch event {
            case .speechStarted:
                currentState = .recognizing
                await startRecognition()
                
            case .speechEnded:
                await finishRecognitionAndTranslate()
                
            case .probabilityUpdate:
                break
            }
        }
    }
    
    private func startRecognition() async {
        // Buffer audio for recognition
    }
    
    private func finishRecognitionAndTranslate() async {
        // 1. Get final transcription
        // 2. Translate
        // 3. Synthesize
        // 4. Apply voice transfer
        // 5. Queue for playback
        currentState = .translating
        
        let translation = try await translationService.translate(
            text: lastTranscription,
            from: config.sourceLanguage,
            to: config.targetLanguage
        )
        lastTranslation = translation
        
        currentState = .synthesizing
        
        var audioBuffer = try await synthesisService.synthesize(
            text: translation,
            language: config.targetLanguage,
            voice: nil
        )
        
        if let profile = voiceProfile, config.useVoiceCloning {
            audioBuffer = voiceTransfer.apply(profile: profile, to: audioBuffer)
        }
        
        delayManager.enqueue(audioBuffer)
        currentState = .listening
    }
    
    func stop() {
        isActive = false
        vadService.stopDetection()
        audioManager.stopCapture()
        currentState = .idle
    }
}

enum PipelineState {
    case idle
    case listening
    case recognizing
    case translating
    case synthesizing
    case speaking
}
```

---

## ⚠️ Critical Technical Considerations

### Double Talk and Echo Cancellation

**Problem**: When TTS plays while the user speaks, the microphone captures both signals.

```
┌─────────────────────────────────────────────────────────────┐
│                    FEEDBACK LOOP                            │
│                                                             │
│  User speaks ──► Microphone ◄── TTS playing                │
│                        │                                    │
│                        ▼                                    │
│              Microphone captures BOTH                       │
│                        │                                    │
│                        ▼                                    │
│         STT processes contaminated audio                    │
└─────────────────────────────────────────────────────────────┘
```

**Solution (F8.5.3): headphones by default, mic echo gate in speakers mode**

Half-duplex suppression (the MVP's `HalfDuplexManager`) was removed in F8.5.3: it dropped sentences
in both directions and still leaked echo, because it was checked when the transcription arrived,
long after the audio had been captured.

- **Headphones (default):** the mic cannot hear the translation, so both directions are always live
  and no sentence is ever dropped.
- **Speakers ("I use speakers"):** `MicEchoGate` sits between the mic stream and the outgoing VAD and
  replaces mic buffers with silence while the remote side's translation plays, plus a 300 ms tail.
  The echo never reaches VAD/STT; the UI shows "Mic paused (speakers)". The gate's output goes through
  `SessionAudioStream(label: "outgoing-gated")` (drops are counted and logged); its paused callback
  value is advisory, the coordinator re-reads `isMicPaused` on the main actor. Every incoming
  teardown marks incoming silent and reopens the gate.
- The incoming direction is never muted: ScreenCaptureKit captures only the call app, which does not
  play the user's own voice back.
- **TTS queue:** never drops a sentence. When it falls behind, pending sentences of the same locale
  are coalesced into one utterance, capped at 400 characters and at the primary engine's
  `UtteranceSynthesizer.maxTextLength` (Qwen 200, Kokoro 500).

```
mic ─► SessionAudioStream ─► MicEchoGate ─► VAD (Silero | Energy) ─► STT ─► translate ─► TTS ─► BlackHole
                                  ▲ speakers mode + incoming TTS speaking (+300 ms)
```

### Translation Framework SwiftUI Dependency

**Problem**: `TranslationSession` requires SwiftUI context.

**Solution**: `TranslationBridge` in an off-screen `TranslationHostWindow`, one kept session per direction (see Section 4, F8.5.4).

---

## 🔄 Data Flow Diagrams

### Outgoing Pipeline (Your Voice → Remote)

```
┌──────────────┐
│ Physical Mic │
└──────┬───────┘
       │ Raw Audio (48kHz PCM)
       ▼
┌─────────────────┐
│  AudioManager   │ ← Capture & Buffer
└──────┬──────────┘
       │ AVAudioPCMBuffer
       ▼
┌─────────────────┐
│  VADService     │ ← FluidAudio Silero
│  (Silero VAD)   │
└──────┬──────────┘
       │ Speech Detected
       ▼
┌─────────────────┐
│ SpeechRecognizer│ ← Apple Speech / FluidAudio
└──────┬──────────┘
       │ "Hola, ¿cómo estás?"
       ▼
┌─────────────────┐
│ TranslationSvc  │ ← Apple Translation
└──────┬──────────┘
       │ "Hello, how are you?"
       ▼
┌─────────────────┐
│ SynthesisService│ ← AVSpeech / MLX-Audio
└──────┬──────────┘
       │ Synthetic Audio Buffer
       ▼
┌─────────────────┐
│ VoiceTransfer   │ ← DSP / MLX-Audio CSM
└──────┬──────────┘
       │ Styled Audio Buffer
       ▼
┌─────────────────┐
│  DelayManager   │ ← Buffer & sync
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ Virtual Mic Out │ ← BlackHole
└──────┬──────────┘
       │
       ▼
┌─────────────────┐
│ Zoom/Teams/Meet │
└─────────────────┘
```

---

## 🗄️ Data Models

```swift
// Language.swift
enum Language: String, Codable, CaseIterable {
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case chinese = "zh"
    case japanese = "ja"
    case korean = "ko"
    case russian = "ru"
    case arabic = "ar"
    
    var code: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }
    var localeLanguage: Locale.Language { Locale.Language(identifier: rawValue) }
    var displayName: String { locale.localizedString(forLanguageCode: rawValue) ?? rawValue }
}

// TranslationConfig.swift
struct TranslationConfig: Codable {
    var sourceLanguage: Language
    var targetLanguage: Language
    var delayMs: Int = 2000
    var useVoiceCloning: Bool = true
    var preferHighAccuracySTT: Bool = false
    var ttsVoiceId: String?
}
```

---

## 🧪 Testing Strategy

### Unit Tests
```swift
class VADServiceTests: XCTestCase {
    func testSileroVADDetectsSpeech() async throws { }
    func testSileroVADDetectsSilence() async throws { }
    func testEnergyVADFallback() async throws { }
}

class SpeechRecognizerTests: XCTestCase {
    func testAppleSpeechRecognition() async throws { }
    func testFluidAudioRecognition() async throws { }
    func testRecognizerFactory() async throws { }
}

class TranslationServiceTests: XCTestCase {
    func testAppleTranslation() async throws { }
    func testTranslationBridge() async throws { }
}
```

### Integration Tests
```swift
class PipelineIntegrationTests: XCTestCase {
    func testEndToEndOutgoingPipeline() async throws { }
    func testBidirectionalTranslation() async throws { }
    func testEchoGateKeepsEchoOut() async throws { }
}
```

### Performance Tests
```swift
class PerformanceTests: XCTestCase {
    func testLatencyUnder3Seconds() async throws {
        measure {
            // Full pipeline: VAD → STT → Translate → TTS → Voice Transfer
        }
    }
    
    func testMemoryUsageUnder400MB() async throws { }
    func testCPUUsageUnder40Percent() async throws { }
}
```

---

## 📊 Performance Targets

```yaml
Latency:
  Total End-to-End: < 3000ms
  VAD Detection: < 100ms
  Speech Recognition: < 800ms
  Translation: < 600ms
  Speech Synthesis: < 600ms
  Voice Transfer: < 400ms
  
Resource Usage:
  CPU: < 40% on M1 Mac
  Memory: < 400MB
  Battery Impact: < 15% increase per hour
  Disk Space: < 2GB (with all models)
  
Quality:
  STT Accuracy (WER): < 10% for clear speech
  Translation BLEU: > 0.7 for common pairs
  Voice Similarity: > 60% subjective rating
```

---

**Last Updated**: December 2025
**Version**: 2.0
**Status**: Ready for Development
