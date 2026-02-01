# TranslateCall - Voice Cloning System

## 🎤 Overview

The Voice Cloning System is what makes TranslateCall unique. Instead of robotic TTS voices, we apply the speaker's voice characteristics to the translated speech, making conversations feel more natural and personal.

---

## ⚠️ Limitations and Realistic Expectations

### Phase 1: DSP Approach (MVP)

#### What DSP Voice Cloning CAN Do
- ✅ Approximate the **pitch/tone** of your voice
- ✅ Maintain your **characteristic speaking rate**
- ✅ Capture **basic intonation patterns**
- ✅ Process in **real-time** (<400ms overhead)

#### What DSP Voice Cloning CANNOT Do
- ❌ Replicate your **exact timbre** (requires neural models)
- ❌ Capture the complete **"personality"** of your voice
- ❌ Preserve your **accent** in the target language
- ❌ Transfer **complex emotions** (irony, sarcasm)

#### Expected Quality (MVP)

| Aspect | Rating | Notes |
|--------|--------|-------|
| Pitch matching | ⭐⭐⭐⭐ | Works well |
| Speaking rate | ⭐⭐⭐⭐ | Works well |
| Timbre | ⭐⭐ | Limited without neural models |
| Naturalness | ⭐⭐⭐ | Depends on base TTS voice |
| Recognizability | ⭐⭐ | Partially recognizable |

### Phase 2: MLX-Audio CSM-1B (Real Voice Cloning)

**This is the game-changer.** MLX-Audio CSM-1B provides actual neural voice cloning:

#### What Neural Voice Cloning CAN Do
- ✅ Replicate your **actual voice timbre**
- ✅ Preserve **speaking style and personality**
- ✅ Sound **naturally like you** in another language
- ✅ Work with just **30 seconds of reference audio**

#### Expected Quality (Phase 2)

| Aspect | Rating | Notes |
|--------|--------|-------|
| Pitch matching | ⭐⭐⭐⭐⭐ | Excellent |
| Speaking rate | ⭐⭐⭐⭐⭐ | Excellent |
| Timbre | ⭐⭐⭐⭐ | Very good |
| Naturalness | ⭐⭐⭐⭐⭐ | Natural sounding |
| Recognizability | ⭐⭐⭐⭐ | Clearly recognizable |

### Message for Users

**MVP (Phase 1)**:
> *"The translated voice will have characteristics similar to yours (tone, speed), but won't be an exact replica. It sounds more natural than a generic TTS voice, but different from your real voice."*

**Enhanced (Phase 2)**:
> *"Your translated voice will sound remarkably like you speaking another language. People who know you will recognize your voice in the translation."*

### Alternative: Premium Voices Without Cloning

The system always offers a **"No Voice Cloning"** mode:
- Superior audio quality from Apple's Premium voices
- No training required
- Ideal for those prioritizing naturalness over vocal identity
- Zero additional latency

---

## 🎯 Technology Roadmap

### Phase 1 - MVP: DSP Approach (Month 1-6)

**Technology**: AVAudioUnit + Accelerate Framework

```swift
// Pitch shifting with AVAudioUnitTimePitch
let timePitch = AVAudioUnitTimePitch()
timePitch.pitch = shiftInCents  // 1200 cents = 1 octave

// Time stretching
timePitch.rate = targetRate / currentRate

// Formant shaping with parametric EQ
let eq = AVAudioUnitEQ(numberOfBands: 4)
eq.bands[0].frequency = profile.formants[0]  // F1
eq.bands[0].gain = 3.0
```

**Result**: Voice "similar" but not identical
**Latency**: <100ms additional
**Quality**: ⭐⭐☆☆☆

---

### Phase 2 - Enhanced: MLX-Audio CSM-1B (Month 7-9)

**Technology**: MLX-Audio with CSM-1B model

**Repository**: https://github.com/blaizzy/mlx-audio

```python
# Voice cloning with single reference audio
python -m mlx_audio.tts.generate \
    --model mlx-community/csm-1b \
    --text "Hello, this is my cloned voice speaking Spanish!" \
    --ref_audio ./my_voice_30sec.wav \
    --play
```

**Python API**:
```python
from mlx_audio.tts.generate import generate_audio

generate_audio(
    text="This will sound like me!",
    model_path="mlx-community/csm-1b",
    ref_audio="./reference_voice.wav",
    file_prefix="cloned_output",
    audio_format="wav",
    sample_rate=24000
)
```

**Swift Integration** (via REST API):
```swift
class MLXVoiceCloner {
    private let serverURL = URL(string: "http://localhost:8000")!
    
    func clone(text: String, referenceAudioURL: URL) async throws -> Data {
        var request = URLRequest(url: serverURL.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        var body = Data()
        
        // Add text
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"text\"\r\n\r\n")
        body.append("\(text)\r\n")
        
        // Add model
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.append("mlx-community/csm-1b\r\n")
        
        // Add reference audio
        let audioData = try Data(contentsOf: referenceAudioURL)
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"reference_audio\"; filename=\"ref.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")
        
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }
}
```

**Result**: Voice clearly recognizable as yours
**Latency**: ~500ms additional
**Quality**: ⭐⭐⭐⭐☆

---

### Phase 3 - Advanced: Fine-tuned Models (Month 10+)

**Technology**: Custom fine-tuned models or Apple Personal Voice API

**Potential approaches**:
1. Fine-tune CSM on more user samples
2. Integrate Apple Personal Voice (if API becomes available)
3. Custom CoreML voice conversion model

**Result**: Near-perfect voice clone
**Quality**: ⭐⭐⭐⭐⭐

---

## 🗂️ System Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│                  VOICE CLONING PIPELINE                           │
└───────────────────────────────────────────────────────────────────┘

TRAINING PHASE (one-time, ~2 minutes for DSP, ~30 seconds for CSM)
┌───────────────────────────────────────────────────────────────────┐
│                                                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ User speaks │ -> │ Audio       │ -> │ VoiceProfile        │  │
│  │ 15 phrases  │    │ recorded    │    │ created & saved     │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│                                                                   │
│  For CSM (Phase 2): Just need 30-sec clean reference audio       │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘

RUNTIME PHASE (real-time during calls)
┌───────────────────────────────────────────────────────────────────┐
│                                                                   │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │ TTS Output  │ -> │ Voice Style │ -> │ Cloned Audio        │  │
│  │ (synthetic) │    │ Transfer    │    │ (sounds like user)  │  │
│  └─────────────┘    └─────────────┘    └─────────────────────┘  │
│                           │                                       │
│                           ├── Phase 1: DSP (AVAudioUnit)         │
│                           └── Phase 2: Neural (MLX-Audio CSM)    │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

---

## 🔬 Voice Characteristics

### What Makes a Voice Unique?

#### 1. **Pitch (Fundamental Frequency - F0)**
```
Male typical: 85-180 Hz
Female typical: 165-255 Hz
Child typical: 250-400 Hz
```

#### 2. **Timbre (Vocal Color)**
- Vocal tract shape
- Formant frequencies (F1-F4)
- Harmonic structure
- Spectral envelope

#### 3. **Prosody (Speech Rhythm)**
- Speaking rate (syllables/second)
- Intonation patterns
- Pause durations
- Stress patterns

#### 4. **Energy (Volume Dynamics)**
- Average loudness
- Dynamic range
- Emphasis patterns

---

## 📊 Voice Profile Model

```swift
struct VoiceProfile: Codable, Identifiable {
    let id: UUID
    let language: Language
    let createdAt: Date
    var updatedAt: Date
    
    // === DSP Parameters (Phase 1) ===
    
    // Pitch Characteristics
    var fundamentalFrequency: Float        // Average F0 in Hz
    var pitchRange: ClosedRange<Float>     // Min-max F0
    var pitchVariability: Float            // Std deviation of F0
    
    // Timbre Characteristics
    var formants: [Float]                  // F1, F2, F3, F4 (Hz)
    var mfcc: [Float]                      // 13 MFCC coefficients
    var spectralCentroid: Float            // Brightness
    
    // Prosody Characteristics
    var speakingRate: Float                // Syllables per second
    var averagePauseDuration: Float        // Seconds
    
    // Energy Characteristics
    var averageEnergy: Float               // Mean RMS
    var dynamicRange: Float                // Max-min RMS in dB
    
    // === Neural Cloning (Phase 2) ===
    
    // Reference audio for CSM-1B
    var referenceAudioURL: URL?            // 30-sec clean audio
    var referenceAudioDuration: TimeInterval?
    
    // Training Metadata
    var numberOfSamples: Int               // Training phrases recorded
    var totalTrainingDuration: TimeInterval
    var qualityScore: Float                // 0-1, analysis confidence
    
    // === Computed Properties ===
    
    var isReadyForDSP: Bool {
        fundamentalFrequency > 0 && !formants.isEmpty
    }
    
    var isReadyForNeuralCloning: Bool {
        referenceAudioURL != nil && (referenceAudioDuration ?? 0) >= 25
    }
}
```

---

## 🎓 Training Process

### Phase 1: DSP Training (15 phrases, ~2 minutes)

#### Step 1: Phrase Selection

**15 carefully designed phrases** covering:
- All phonemes in target language
- Different vowel/consonant sounds
- Questions, statements, exclamations
- Various emotional tones

**Example Phrases (English)**:
```
1. "Hello, my name is [your name]."
2. "How are you? I hope you're having a great day!"
3. "I work in technology and I'm passionate about innovation."
4. "Could you please repeat that? I didn't quite catch it."
5. "That's wonderful! I'm really excited to hear that."
6. "I understand what you mean. Let me think about it."
7. "The quick brown fox jumps over the lazy dog."
8. "What time would be convenient for you?"
9. "I completely agree with your perspective."
10. "Perhaps we could explore other options?"
11. "Thank you so much for your help and patience."
12. "I appreciate your understanding in this matter."
13. "Let's schedule a meeting for next week."
14. "It's been a pleasure talking with you today."
15. "Have a wonderful rest of your day!"
```

#### Step 2: Recording UI

```swift
struct TrainingWizardView: View {
    @StateObject var session: TrainingSession
    
    var body: some View {
        VStack(spacing: 20) {
            // Progress indicator
            ProgressView(value: Double(session.currentIndex), total: 15)
            
            Text("Phrase \(session.currentIndex + 1) of 15")
                .font(.headline)
            
            // Current phrase to read
            Text(session.currentPhrase)
                .font(.title2)
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(10)
            
            // Waveform visualization
            WaveformView(buffer: session.currentBuffer)
                .frame(height: 100)
            
            // Recording controls
            HStack(spacing: 20) {
                Button(action: { session.startRecording() }) {
                    Label("Record", systemImage: "mic.fill")
                }
                .disabled(session.isRecording)
                
                Button(action: { session.stopRecording() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!session.isRecording)
                
                Button(action: { session.playback() }) {
                    Label("Play", systemImage: "play.fill")
                }
                .disabled(session.currentBuffer == nil)
            }
            
            // Quality indicator
            if let quality = session.currentQuality {
                QualityIndicator(score: quality)
            }
            
            // Navigation
            HStack {
                Button("Re-record") {
                    session.rerecord()
                }
                
                Spacer()
                
                Button("Next") {
                    session.nextPhrase()
                }
                .disabled(session.currentBuffer == nil)
            }
        }
        .padding()
    }
}
```

#### Step 3: Feature Extraction

```swift
class VoiceAnalyzer {
    func analyze(samples: [AVAudioPCMBuffer]) async -> VoiceProfile {
        var profile = VoiceProfile(language: .english)
        
        // Extract pitch characteristics
        let pitchResults = samples.map { extractPitch($0) }
        profile.fundamentalFrequency = pitchResults.mean
        profile.pitchRange = pitchResults.min...pitchResults.max
        profile.pitchVariability = pitchResults.standardDeviation
        
        // Extract formants
        let formantResults = samples.map { extractFormants($0) }
        profile.formants = formantResults.averaged
        
        // Extract MFCCs
        let mfccResults = samples.map { extractMFCC($0) }
        profile.mfcc = mfccResults.averaged
        
        // Extract prosody
        profile.speakingRate = calculateSpeakingRate(samples)
        profile.averagePauseDuration = calculateAveragePause(samples)
        
        // Calculate quality score
        profile.qualityScore = calculateQualityScore(samples)
        
        return profile
    }
    
    private func extractPitch(_ buffer: AVAudioPCMBuffer) -> Float {
        // Autocorrelation-based pitch detection
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = Float(buffer.format.sampleRate)
        
        // ... autocorrelation algorithm ...
        
        return detectedPitch
    }
    
    private func extractFormants(_ buffer: AVAudioPCMBuffer) -> [Float] {
        // LPC-based formant extraction
        // Returns F1, F2, F3, F4
        return [500, 1500, 2500, 3500] // placeholder
    }
    
    private func extractMFCC(_ buffer: AVAudioPCMBuffer, numCoeffs: Int = 13) -> [Float] {
        // Mel-frequency cepstral coefficients
        // ... FFT → Mel filterbank → Log → DCT ...
        return Array(repeating: 0, count: numCoeffs)
    }
}
```

### Phase 2: Neural Training (30-sec reference, instant)

Much simpler - just need clean reference audio:

```swift
class NeuralVoiceTrainer {
    func prepareReferenceAudio(from recordings: [AVAudioPCMBuffer]) async throws -> URL {
        // Combine best quality segments into 30-sec reference
        let combined = combineBuffers(recordings, targetDuration: 30)
        
        // Apply noise reduction
        let cleaned = await applyNoiseReduction(combined)
        
        // Normalize volume
        let normalized = normalizeVolume(cleaned)
        
        // Save to file
        let url = getDocumentsDirectory().appendingPathComponent("reference_voice.wav")
        try saveBuffer(normalized, to: url)
        
        return url
    }
}
```

---

## 🎨 Style Transfer Implementation

### Phase 1: DSP Pipeline

```swift
class DSPVoiceStyleTransfer {
    private let engine = AVAudioEngine()
    private var timePitchNode: AVAudioUnitTimePitch!
    private var eqNode: AVAudioUnitEQ!
    
    init() {
        timePitchNode = AVAudioUnitTimePitch()
        eqNode = AVAudioUnitEQ(numberOfBands: 4)
        
        engine.attach(timePitchNode)
        engine.attach(eqNode)
    }
    
    func apply(profile: VoiceProfile, to inputBuffer: AVAudioPCMBuffer) async -> AVAudioPCMBuffer {
        // 1. Analyze input pitch
        let inputPitch = await analyzePitch(inputBuffer)
        
        // 2. Calculate pitch shift
        let pitchShiftCents = 1200 * log2(profile.fundamentalFrequency / inputPitch)
        timePitchNode.pitch = pitchShiftCents
        
        // 3. Calculate rate adjustment
        let inputRate = await analyzeRate(inputBuffer)
        timePitchNode.rate = profile.speakingRate / inputRate
        
        // 4. Configure formant EQ
        for (index, formant) in profile.formants.enumerated() where index < 4 {
            eqNode.bands[index].filterType = .parametric
            eqNode.bands[index].frequency = formant
            eqNode.bands[index].bandwidth = 0.5
            eqNode.bands[index].gain = 3.0
            eqNode.bands[index].bypass = false
        }
        
        // 5. Process through audio units
        return await processBuffer(inputBuffer)
    }
    
    private func processBuffer(_ buffer: AVAudioPCMBuffer) async -> AVAudioPCMBuffer {
        // Create offline render context
        // Process buffer through timePitch → EQ
        // Return processed buffer
    }
}
```

### Phase 2: Neural Cloning Pipeline

```swift
class NeuralVoiceCloner {
    private var serverProcess: Process?
    private let serverURL = URL(string: "http://localhost:8765")!
    
    func startServer() async throws {
        // Start MLX-Audio server
        serverProcess = Process()
        serverProcess?.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        serverProcess?.arguments = ["-m", "mlx_audio.server", "--port", "8765"]
        try serverProcess?.run()
        
        // Wait for server to be ready
        try await waitForServer()
    }
    
    func clone(text: String, using profile: VoiceProfile) async throws -> AVAudioPCMBuffer {
        guard let referenceURL = profile.referenceAudioURL else {
            throw VoiceCloningError.noReferenceAudio
        }
        
        // Call MLX-Audio API
        var request = URLRequest(url: serverURL.appendingPathComponent("tts"))
        request.httpMethod = "POST"
        
        let boundary = UUID().uuidString
        var body = Data()
        
        // Text to synthesize
        body.appendFormField(name: "text", value: text, boundary: boundary)
        
        // Model selection
        body.appendFormField(name: "model", value: "mlx-community/csm-1b", boundary: boundary)
        
        // Reference audio for cloning
        let audioData = try Data(contentsOf: referenceURL)
        body.appendFileField(name: "reference_audio", filename: "ref.wav", 
                            data: audioData, mimeType: "audio/wav", boundary: boundary)
        
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", 
                        forHTTPHeaderField: "Content-Type")
        
        let (responseData, _) = try await URLSession.shared.data(for: request)
        
        // Decode response to audio buffer
        return try decodeWAV(responseData)
    }
    
    func stopServer() {
        serverProcess?.terminate()
    }
}
```

---

## 📈 Quality Metrics

### Objective Metrics

```swift
struct VoiceQualityMetrics {
    let pitchAccuracy: Float        // 0-1, RMSE normalized
    let formantAccuracy: Float      // 0-1, distance normalized
    let mfccSimilarity: Float       // Cosine similarity
    let speakingRateAccuracy: Float // Ratio closeness
    let overallScore: Float         // Weighted average
    
    static func evaluate(
        original: VoiceProfile,
        cloned: AVAudioPCMBuffer
    ) async -> VoiceQualityMetrics {
        let analyzer = VoiceAnalyzer()
        let clonedProfile = await analyzer.analyze(samples: [cloned])
        
        let pitchError = abs(original.fundamentalFrequency - clonedProfile.fundamentalFrequency) 
                        / original.fundamentalFrequency
        let pitchAccuracy = 1.0 - min(pitchError, 1.0)
        
        // Similar calculations for other metrics...
        
        return VoiceQualityMetrics(
            pitchAccuracy: pitchAccuracy,
            formantAccuracy: formantAccuracy,
            mfccSimilarity: mfccSimilarity,
            speakingRateAccuracy: rateAccuracy,
            overallScore: (pitchAccuracy + formantAccuracy + mfccSimilarity + rateAccuracy) / 4
        )
    }
}
```

### Subjective Evaluation

For user testing:
```
1. Play original voice sample
2. Play cloned voice sample
3. Ask:
   - "Does this sound like the same person?" (1-5 scale)
   - "How natural does the cloned speech sound?" (1-5 scale)
   - "Would this be acceptable for a professional call?" (Yes/No)

Target Metrics:
- Similarity: > 3.5/5 (DSP), > 4.0/5 (Neural)
- Naturalness: > 3.5/5 (DSP), > 4.5/5 (Neural)
- Acceptability: > 70% (DSP), > 90% (Neural)
```

---

## ⚡ Performance

### Latency Budget

```yaml
Phase 1 (DSP):
  Feature Extraction: 20ms
  Pitch Shifting: 30ms
  Time Stretching: 30ms
  EQ Processing: 10ms
  Buffer Overhead: 10ms
  Total: ~100ms

Phase 2 (Neural):
  Model Loading: 0ms (pre-loaded)
  Inference: 400ms
  Audio Decoding: 50ms
  Buffer Overhead: 50ms
  Total: ~500ms
```

### Resource Usage

```yaml
Phase 1 (DSP):
  CPU: 5-10%
  Memory: 50MB
  GPU: None

Phase 2 (Neural):
  CPU: 10-20%
  Memory: 500MB (model loaded)
  GPU/ANE: Active during inference
```

---

## 🔮 Future: Apple Personal Voice Integration

Apple introduced **Personal Voice** in iOS 17/macOS 14 for accessibility. If Apple expands the API:

```swift
// Hypothetical future API
func usePersonalVoiceIfAvailable() async -> AVSpeechSynthesisVoice? {
    if #available(macOS 15.0, *) {
        let personalVoices = await AVSpeechSynthesisVoice.personalVoices()
        
        if let voice = personalVoices.first {
            // User already has Personal Voice trained!
            // Skip our training entirely
            return voice
        }
    }
    return nil
}
```

**Benefits if available**:
- ✅ Higher quality than our solution
- ✅ No redundant training
- ✅ Apple's optimization
- ✅ Privacy-first (Apple ecosystem)

**Status**: Monitoring Apple's accessibility API announcements

---

## 📚 References

### Technologies
- [MLX-Audio GitHub](https://github.com/blaizzy/mlx-audio)
- [CSM-1B Model](https://huggingface.co/mlx-community/csm-1b)
- [AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch)
- [Accelerate Framework](https://developer.apple.com/documentation/accelerate)

### Research
- "Neural Voice Cloning with a Few Samples" (Jia et al., 2018)
- "Voice Conversion Using Sequence-to-Sequence Learning" (Nachmani et al., 2018)
- "Real-Time Voice Clone" - Various implementations

---

**Last Updated**: December 2025
**Version**: 2.0
**Status**: Ready for Development
