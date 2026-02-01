# TranslateCall - Technology Stack

## 🛠️ Core Technologies

### Programming Language
**Swift 6.0**
- **Why**: Native macOS development, performance, safety, modern concurrency
- **Features used**:
  - Swift Concurrency (async/await, actors)
  - Strong typing and generics
  - Protocol-oriented programming
  - Value types for data models
  - Automatic Reference Counting (ARC)

### UI Framework
**SwiftUI**
- **Why**: Modern, declarative, reactive, less code than AppKit
- **Features used**:
  - Declarative UI
  - State management (@State, @Published, @ObservedObject)
  - Combine integration
  - Native animations
  - Dark mode support

### Deployment Target
**macOS 14.0+ (Sonoma)**
- **Recommended**: macOS 15.0+ for Apple Intelligence features
- **Why**: Access to latest frameworks while maintaining reasonable compatibility

---

## 🎙️ Audio Stack

### Core Audio Frameworks

#### **AVFoundation**
Primary framework for audio I/O and processing.

```swift
import AVFoundation

Components used:
- AVAudioEngine: Audio processing graph
- AVAudioInputNode: Microphone input
- AVAudioOutputNode: Speaker output
- AVAudioPCMBuffer: Audio buffer handling
- AVAudioFormat: Format management
- AVAudioConverter: Format conversion
- AVAudioPlayerNode: Playback control
```

**Why AVFoundation**:
- ✅ High-level API, easier than Core Audio
- ✅ Excellent performance
- ✅ Built-in format conversion
- ✅ Real-time processing support
- ✅ Well-documented

**Technical Specifications**:
```yaml
Sample Rate: 48000 Hz (video calls) / 16000 Hz (ML models)
Bit Depth: 32-bit float
Channels: 1 (mono) for capture, 2 (stereo) for playback
Buffer Size: 4096 frames
Format: PCM Linear Float
```

#### **Core Audio** (Low-level, when needed)
For advanced audio routing and virtual device management.

```swift
import CoreAudio

Components used:
- AudioDevice APIs: Device enumeration
- AudioStream: Stream configuration
- AudioHardware: System audio control
```

### Virtual Audio Driver

#### **BlackHole** (Open Source)
Creates virtual audio devices for routing.

- **Version**: 2.0+
- **Source**: https://github.com/ExistentialAudio/BlackHole
- **License**: GPL-3.0
- **Why BlackHole**:
  - ✅ Open source and free
  - ✅ Stable and well-maintained
  - ✅ Zero-latency
  - ✅ Multi-channel support
  - ✅ Easy integration

**Installation via Homebrew**:
```bash
brew install blackhole-2ch
```

**Integration Strategy**:
```
1. Bundle BlackHole installer with app
2. Automated installation on first launch
3. Configure virtual devices via CoreAudio APIs
4. Restart coreaudiod after installation
```

---

## 🗣️ Speech Recognition (STT)

### Primary: Apple Speech Framework (MVP)

```swift
import Speech

Components used:
- SFSpeechRecognizer: Recognition engine
- SFSpeechAudioBufferRecognitionRequest: Audio buffer input
- SFSpeechRecognitionTask: Async recognition task
- SFSpeechRecognitionResult: Recognition results
```

**Why Speech Framework for MVP**:
- ✅ On-device recognition (privacy!)
- ✅ 50+ languages supported
- ✅ Native Swift API
- ✅ No additional dependencies
- ✅ Free (no API costs)
- ✅ Low latency (~500-800ms)

**Configuration**:
```swift
let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))!
recognizer.supportsOnDeviceRecognition // true on modern Macs

let request = SFSpeechAudioBufferRecognitionRequest()
request.requiresOnDeviceRecognition = true  // Force on-device
request.shouldReportPartialResults = true    // Get interim results
```

### Alternative A: FluidAudio Parakeet (Phase 2)

**Repository**: https://github.com/fluidinference/fluidaudio

Framework Swift nativo con modelos CoreML optimizados para Apple Neural Engine.

```swift
import FluidAudio

// Batch transcription
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asrManager = AsrManager(config: .default)
try await asrManager.initialize(models: models)

let result = try await asrManager.transcribe(samples)
print("Transcription: \(result.text)")

// Streaming transcription
let streamingManager = StreamingAsrManager(config: .streaming)
try await streamingManager.start(source: .microphone)

for await update in streamingManager.transcriptionUpdates {
    if update.isConfirmed {
        print("✓ Confirmed: \(update.text)")
    }
}
```

**Advantages**:
- ✅ ~209.8x RTF on M4 Pro
- ✅ Native Swift API
- ✅ Streaming support built-in
- ✅ ANE optimized (low battery)
- ✅ MIT/Apache 2.0 license

**Limitations**:
- ⚠️ 25 European languages only (not Asian languages)
- ⚠️ Newer project (less battle-tested)

**Supported Languages**:
English, Spanish, French, German, Italian, Portuguese, Dutch, Polish, Russian, Ukrainian, Czech, Romanian, Hungarian, Bulgarian, Croatian, Slovak, Slovenian, Lithuanian, Latvian, Estonian, Finnish, Swedish, Norwegian, Danish, Greek

### Alternative B: Lightning Whisper MLX (Phase 2)

**Repository**: https://github.com/mustafaaljadery/lightning-whisper-mlx

Whisper optimizado para Apple Silicon con MLX.

```python
from lightning_whisper_mlx import LightningWhisperMLX

whisper = LightningWhisperMLX(
    model="distil-medium.en",  # or "large-v3" for best quality
    batch_size=12,
    quant="4bit"  # Reduce memory usage
)

result = whisper.transcribe(audio_path="/audio.mp3")
print(result['text'])
```

**Advantages**:
- ✅ 99+ languages (full Whisper support)
- ✅ Distilled models available (faster)
- ✅ 4-bit/8-bit quantization
- ✅ Best accuracy

**Limitations**:
- ⚠️ Python (requires bridge or subprocess)
- ⚠️ No native streaming API

**Available Models**:
- tiny, small, base, medium, large, large-v2, large-v3
- distil-small.en, distil-medium.en, distil-large-v2, distil-large-v3

### Alternative C: whisper.cpp (Phase 2)

**Repository**: https://github.com/ggml-org/whisper.cpp

C/C++ implementation with CoreML support and Swift Package.

```bash
# Build with CoreML support
cmake -B build -DWHISPER_COREML=1
cmake --build build -j --config Release

# Real-time streaming
./build/bin/whisper-stream -m models/ggml-base.en.bin -t 8 --step 500
```

**Swift Package Integration**:
```swift
// Package.swift
.binaryTarget(
    name: "WhisperFramework",
    url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.7.5/whisper-v1.7.5-xcframework.zip",
    checksum: "..."
)
```

**Advantages**:
- ✅ Swift Package available
- ✅ CoreML/ANE optimized
- ✅ Native streaming support
- ✅ Works on Intel too

### STT Comparison Matrix

| Feature | Apple Speech | FluidAudio | Whisper MLX | whisper.cpp |
|---------|-------------|------------|-------------|-------------|
| Languages | 50+ | 25 | 99+ | 99+ |
| Swift Native | ✅ | ✅ | ❌ (Python) | ⚠️ (C) |
| Streaming | ✅ | ✅ | ❌ | ✅ |
| ANE Optimized | ✅ | ✅ | ✅ | ✅ |
| Accuracy | ★★★★ | ★★★★★ | ★★★★★ | ★★★★★ |
| Setup Complexity | Low | Medium | High | Medium |

**Recommendation**:
- **MVP**: Apple Speech Framework
- **v1.1**: FluidAudio for European languages
- **v2.0**: whisper.cpp for full language support

---

## 🎤 Voice Activity Detection (VAD)

### Primary: FluidAudio Silero VAD (Recommended)

```swift
import FluidAudio

let manager = try await VadManager()
var state = await manager.makeStreamState()

for chunk in microphoneChunks {
    let result = try await manager.processStreamingChunk(
        chunk,
        state: state,
        config: .default,
        returnSeconds: true,
        timeResolution: 2
    )
    
    state = result.state
    
    // Raw probability (0.0-1.0)
    print(String(format: "Probability: %.3f", result.probability))
    
    if let event = result.event {
        switch event.kind {
        case .speechStart:
            print("Speech began at \(event.time ?? 0)s")
        case .speechEnd:
            print("Speech ended at \(event.time ?? 0)s")
        }
    }
}
```

**Why Silero VAD**:
- ✅ State-of-the-art accuracy
- ✅ Streaming API
- ✅ ANE optimized
- ✅ Configurable thresholds
- ✅ MIT license

### Fallback: Energy-based VAD

Simple fallback for when FluidAudio isn't available:

```swift
class SimpleVAD {
    var energyThreshold: Float = -50.0 // dB
    var silenceDuration: TimeInterval = 0.8
    
    func analyzeBuffer(_ buffer: AVAudioPCMBuffer) -> Bool {
        let energy = calculateRMSEnergy(buffer)
        return energy > energyThreshold
    }
}
```

---

## 🌐 Translation

### Apple Translation Framework

```swift
import Translation

// Using translationTask in SwiftUI
struct ContentView: View {
    @State private var sourceText = "Hola, ¿cómo estás?"
    @State private var targetText: String?
    @State private var configuration: TranslationSession.Configuration?
    
    var body: some View {
        Text(targetText ?? sourceText)
            .translationTask(configuration) { session in
                Task { @MainActor in
                    let response = try await session.translate(sourceText)
                    targetText = response.targetText
                }
            }
    }
}
```

**⚠️ Important**: Translation Framework has SwiftUI dependency. Use `translationTask` modifier or create a hosting view for background translation.

**Supported Language Pairs** (~17 languages):
- English ↔ Spanish, French, German, Italian, Portuguese
- English ↔ Chinese (Simplified), Japanese, Korean
- English ↔ Arabic, Russian, Polish, Dutch, Indonesian
- English ↔ Thai, Turkish, Ukrainian, Vietnamese

**Limitations**:
- ⚠️ Requires SwiftUI context
- ⚠️ Limited language pairs vs cloud services
- ⚠️ Quality varies by pair

### Future: Apple Foundation Models (macOS 15.4+)

For context-aware translation enhancement:

```swift
import FoundationModels

let model = SystemLanguageModel.default

// Improve translation with context
let prompt = """
Given the conversation context: \(conversationHistory)
Improve this translation for natural flow: \(rawTranslation)
"""

let response = try await model.generate(prompt, useCase: .general)
```

---

## 🎤 Speech Synthesis (TTS)

### Primary: AVSpeechSynthesizer (MVP)

```swift
import AVFoundation

class SpeechSynthesizer {
    private let synthesizer = AVSpeechSynthesizer()
    
    func speak(_ text: String, language: String, rate: Float = 0.5) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }
    
    func getVoices(for language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }
}
```

**Voice Quality Tiers**:
- Default: Basic system voices
- Enhanced: Better quality
- Premium: Siri-quality voices

### Alternative: MLX-Audio Kokoro (Phase 2)

**Repository**: https://github.com/blaizzy/mlx-audio

Superior TTS quality using MLX:

```python
from mlx_audio.tts.models.kokoro import KokoroPipeline
from mlx_audio.tts.utils import load_model
import soundfile as sf

model_id = 'prince-canuma/Kokoro-82M'
model = load_model(model_id)
pipeline = KokoroPipeline(lang_code='a', model=model, repo_id=model_id)

text = "Hello, this is a test."
for _, _, audio in pipeline(text, voice='af_heart', speed=1.0):
    sf.write('output.wav', audio[0], 24000)
```

**REST API** (for Swift integration):
```bash
# Start server
python -m mlx_audio.server

# API call
curl -X POST http://localhost:8000/tts \
  -F "text=Hello world" \
  -F "voice=af_heart" \
  -F "speed=1.0"
```

**Advantages**:
- ✅ Much better quality than AVSpeechSynthesizer
- ✅ Multiple voices
- ✅ Speed control
- ✅ REST API available

### TTS Comparison

| Feature | AVSpeechSynthesizer | MLX-Audio Kokoro |
|---------|--------------------|--------------------|
| Quality | ★★★ | ★★★★★ |
| Latency | ★★★★★ | ★★★★ |
| Swift Native | ✅ | ❌ (Python/REST) |
| Voices | Many | Growing |
| Setup | None | Medium |

---

## 🎨 Voice Cloning

### Phase 1: DSP Approach (MVP)

Using AVAudioUnit and Accelerate framework:

```swift
import AVFoundation
import Accelerate

class VoiceStyleTransfer {
    func apply(profile: VoiceProfile, to buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        var processed = buffer
        
        // 1. Pitch shifting
        processed = adjustPitch(processed, target: profile.fundamentalFrequency)
        
        // 2. Time stretching
        processed = adjustRate(processed, target: profile.speakingRate)
        
        // 3. Formant shaping
        processed = adjustFormants(processed, target: profile.formants)
        
        return processed
    }
    
    private func adjustPitch(_ buffer: AVAudioPCMBuffer, target: Float) -> AVAudioPCMBuffer {
        let timePitch = AVAudioUnitTimePitch()
        let currentPitch = extractPitch(buffer)
        timePitch.pitch = 1200 * log2(target / currentPitch) // cents
        return process(buffer, through: timePitch)
    }
}
```

**Expected Quality**: ★★☆☆☆ (Recognizable pitch/rate, limited timbre)

### Phase 2: MLX-Audio CSM-1B (Real Voice Cloning)

**This is the game-changer** - actual neural voice cloning:

```python
# Voice cloning with single reference audio
python -m mlx_audio.tts.generate \
    --model mlx-community/csm-1b \
    --text "Hello, this is my cloned voice." \
    --ref_audio ./my_voice_sample.wav \
    --play
```

```python
from mlx_audio.tts.generate import generate_audio

generate_audio(
    text="This will sound like me!",
    model_path="mlx-community/csm-1b",
    ref_audio="./my_voice_30sec.wav",
    file_prefix="cloned_output",
    audio_format="wav"
)
```

**Advantages**:
- ✅ Real voice cloning (not just DSP tricks)
- ✅ Single reference audio sample needed
- ✅ Preserves speaker characteristics
- ✅ Natural sounding output

**Requirements**:
- ~30 seconds of clean reference audio
- Apple Silicon Mac
- Python environment

**Expected Quality**: ★★★★☆ (Very recognizable, natural)

### Voice Cloning Comparison

| Approach | Quality | Latency | Complexity | Phase |
|----------|---------|---------|------------|-------|
| DSP (Accelerate) | ★★☆☆☆ | <100ms | Low | MVP |
| MLX-Audio CSM-1B | ★★★★☆ | ~500ms | Medium | v2.0 |

---

## 💾 Data Persistence

### SwiftData (macOS 14.0+)

```swift
import SwiftData

@Model
class VoiceProfile {
    var id: UUID
    var language: String
    var fundamentalFrequency: Float
    var speakingRate: Float
    var formants: [Float]
    var createdAt: Date
    
    init(language: String) {
        self.id = UUID()
        self.language = language
        self.createdAt = Date()
    }
}
```

### File Storage

```
~/Library/Application Support/TranslateCall/
├── VoiceProfiles/
│   └── {uuid}/
│       ├── profile.json (encrypted)
│       └── samples/ (training audio)
├── Logs/
└── Cache/
```

---

## 🧪 Testing Stack

### XCTest
```swift
import XCTest

class AudioManagerTests: XCTestCase {
    func testAudioCapture() async throws { }
    func testVirtualDeviceRouting() async throws { }
}

class SpeechRecognizerTests: XCTestCase {
    func testOnDeviceRecognition() async throws { }
}
```

---

## 📦 Dependencies Summary

### Required (MVP)
```yaml
Apple Frameworks:
  - AVFoundation
  - Speech
  - Translation
  - Accelerate
  - SwiftUI
  - SwiftData

External:
  - BlackHole (bundled installer)
```

### Optional (Phase 2)
```yaml
Swift Packages:
  - FluidAudio (VAD + ASR)
  - whisper.cpp XCFramework

Python (via subprocess/REST):
  - mlx-audio (TTS + Voice Cloning)
  - lightning-whisper-mlx (ASR)
```

---

## 🎯 Technology Decisions Summary

### MVP Stack (Month 1-6)
| Component | Technology | Reason |
|-----------|------------|--------|
| Audio I/O | AVFoundation | Native, stable |
| Virtual Audio | BlackHole | Free, works well |
| VAD | FluidAudio Silero | Best accuracy |
| STT | Apple Speech | Native, simple |
| Translation | Apple Translation | On-device, free |
| TTS | AVSpeechSynthesizer | Native, simple |
| Voice Styling | DSP (Accelerate) | Fast, no deps |

### Enhanced Stack (Month 7-12)
| Component | Technology | Reason |
|-----------|------------|--------|
| STT | FluidAudio Parakeet | Better accuracy |
| TTS | MLX-Audio Kokoro | Better quality |
| Voice Cloning | MLX-Audio CSM-1B | Real cloning |

---

## 📊 Performance Targets

```yaml
Latency Budget:
  VAD Detection: < 100ms
  Speech Recognition: < 800ms
  Translation: < 600ms
  Speech Synthesis: < 600ms
  Voice Transfer: < 400ms
  Total: < 2500ms

Resource Usage:
  CPU (active): < 40%
  Memory: < 400MB
  Disk: < 2GB (with models)
  Battery (1hr): < 15%
```

---

## 🔗 References

### Official Documentation
- [AVFoundation](https://developer.apple.com/av-foundation/)
- [Speech Framework](https://developer.apple.com/documentation/speech)
- [Translation Framework](https://developer.apple.com/documentation/translation)
- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)

### Third-Party
- [FluidAudio](https://github.com/fluidinference/fluidaudio)
- [MLX-Audio](https://github.com/blaizzy/mlx-audio)
- [Lightning Whisper MLX](https://github.com/mustafaaljadery/lightning-whisper-mlx)
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)

---

**Last Updated**: December 2025
**Version**: 2.0
**Status**: Ready for Development
