# TranslateCall - Development Roadmap

## 🎯 Project Timeline Overview

**Total Estimated Duration**: 6-9 months (full-time development)
**Start Date**: TBD
**Target MVP**: Month 6
**Public Launch**: Month 9

```
Days 1-3:   Milestone 0 - PoC Testing (CRITICAL)
Month 1-2:  Foundation + Audio Infrastructure
Month 3:    Speech Pipeline (VAD + STT + TTS)
Month 4:    Translation Core
Month 5:    Voice Training System
Month 6:    Integration & Polish → MVP Release
Month 7-9:  Enhanced Features + Public Launch
```

---

## 🧪 MILESTONE 0: Proof of Concepts (2-3 days)

**Objective**: Validate critical technical assumptions BEFORE starting main development.

> ⚠️ **CRITICAL**: Do NOT skip this milestone. These PoCs will prevent wasted development time.

### PoC 1: Translation API without SwiftUI (4 hours)

**Goal**: Verify Apple's Translation Framework works independently of SwiftUI.

```swift
// Test 1: Pure Swift context
func testTranslationWithoutUI() async throws {
    let config = TranslationSession.Configuration(
        source: Locale.Language(identifier: "es"),
        target: Locale.Language(identifier: "en")
    )
    
    // Does this work without a View?
    let session = TranslationSession(configuration: config)
    let result = try await session.translate("Hola mundo")
    
    XCTAssertEqual(result.targetText, "Hello world")
}

// Test 2: Background context
func testTranslationInBackground() async throws {
    Task.detached {
        // Can we translate from a background task?
        let result = try await translate("Hola")
    }
}
```

**Expected Results**:
- ✅ Works → Current architecture valid
- ❌ Fails → Implement TranslationBridge with hidden SwiftUI host

**Success Criteria**:
- Translation callable from pure Swift code
- Works in background Task context
- No visible UI required

### PoC 2: FluidAudio Integration (4 hours)

**Goal**: Verify FluidAudio VAD and ASR work as expected.

```swift
import FluidAudio

// Test VAD streaming
func testSileroVAD() async throws {
    let vadManager = try await VadManager()
    var state = await vadManager.makeStreamState()
    
    // Feed audio samples
    let testAudio = loadTestAudio("speech_sample.wav")
    let result = try await vadManager.processStreamingChunk(
        testAudio,
        state: state,
        config: .default
    )
    
    // Should detect speech
    XCTAssertGreaterThan(result.probability, 0.5)
}

// Test ASR
func testParakeetASR() async throws {
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let asrManager = AsrManager(config: .default)
    try await asrManager.initialize(models: models)
    
    let audio = loadTestAudio("hola_como_estas.wav")
    let result = try await asrManager.transcribe(audio)
    
    XCTAssertTrue(result.text.lowercased().contains("hola"))
}
```

**Expected Results**:
- ✅ Works → Use FluidAudio for VAD (primary) and ASR (European languages)
- ⚠️ Partially works → Use FluidAudio VAD only, Apple Speech for STT
- ❌ Fails → Fall back to energy-based VAD + Apple Speech

**Success Criteria**:
- VAD detects speech with >90% accuracy
- ASR WER <15% for clear speech
- Latency <200ms for VAD detection

### PoC 3: Voice Cloning DSP Quality (4 hours)

**Goal**: Evaluate if basic DSP produces acceptable voice styling.

```swift
// Record 3 phrases with real voice
// Synthesize same phrases with TTS
// Apply DSP pipeline (pitch + rate + EQ)
// Subjectively evaluate

func evaluateDSPQuality() async {
    // 1. Record original
    let original = await recordVoice("Hola, soy yo")
    
    // 2. Extract profile
    let profile = await VoiceAnalyzer().analyze([original])
    
    // 3. Generate TTS
    let tts = await synthesize("Hola, soy yo", language: .spanish)
    
    // 4. Apply DSP
    let styled = await DSPVoiceStyleTransfer().apply(profile: profile, to: tts)
    
    // 5. Play all three for comparison
    await playForComparison(original: original, tts: tts, styled: styled)
    
    // Subjective rating:
    // 1 = Robotic/Unacceptable
    // 2 = Different but tolerable
    // 3 = Similar, acceptable for MVP
    // 4 = Very similar
    // 5 = Indistinguishable
}
```

**Expected Results**:
- Score ≥ 2 → Voice cloning as beta feature in MVP
- Score < 2 → Voice cloning deferred, MVP uses Premium TTS only

**Success Criteria**:
- Pitch shifting accurate within ±10%
- Time stretching maintains quality
- Subjective score ≥ 2/5

### PoC 4: BlackHole Integration (2 hours)

**Goal**: Verify BlackHole can be installed and configured programmatically.

```swift
func testBlackHoleIntegration() async throws {
    let manager = VirtualDeviceManager()
    
    // Check if already installed
    let isInstalled = manager.isBlackHoleInstalled()
    
    if !isInstalled {
        // Test installation
        try await manager.installBlackHole()
    }
    
    // Verify devices appear
    let devices = manager.findBlackHoleDevices()
    XCTAssertFalse(devices.isEmpty)
    
    // Test audio routing
    let success = try await manager.testAudioRouting()
    XCTAssertTrue(success)
}
```

**Expected Results**:
- ✅ Works → Proceed with BlackHole integration
- ❌ Fails → Investigate alternative virtual audio solutions

### PoC 5: Half-Duplex Echo Management (2 hours)

**Goal**: Verify half-duplex approach prevents audio feedback.

```swift
func testHalfDuplexPreventsEcho() async {
    let halfDuplex = HalfDuplexManager()
    
    // Simulate TTS playback
    halfDuplex.switchToSpeaking()
    
    // Verify mic is muted
    XCTAssertTrue(audioManager.isMicrophoneMuted)
    
    // Play TTS
    await playTTS("Hello world")
    
    // Wait transition
    try await Task.sleep(nanoseconds: 300_000_000) // 300ms
    
    // Switch back to listening
    halfDuplex.switchToListening()
    
    // Verify mic is active
    XCTAssertFalse(audioManager.isMicrophoneMuted)
    
    // Verify no feedback detected
    XCTAssertFalse(audioManager.detectsFeedback())
}
```

**Success Criteria**:
- Microphone properly mutes during TTS
- 300ms transition buffer works
- No audio feedback detected

### Go/No-Go Decision

| PoC | Minimum Acceptable | Action if Fails |
|-----|-------------------|-----------------|
| Translation API | Works in any form | Implement SwiftUI bridge |
| FluidAudio | VAD works | Fall back to energy VAD |
| Voice Cloning | Score ≥ 2 | Remove from MVP, add later |
| BlackHole | Installs + routes | Find alternative |
| Half-Duplex | Prevents echo | Investigate AEC library |

**Decision Point After Milestone 0**:
- ✅ **GO**: All PoCs pass minimum → Proceed to Milestone 1
- ⚠️ **CONDITIONAL**: Some need workarounds → Document and proceed
- ❌ **NO-GO**: Major blockers → Pivot approach or reassess

---

## 📋 MILESTONE 1: Foundation (Weeks 1-3)

**Goal**: Build audio infrastructure and basic UI.

### Week 1: Project Setup

- [ ] Create Xcode project (macOS app, SwiftUI, Swift 6.0)
- [ ] Setup folder structure per ARCHITECTURE.md
- [ ] Configure build settings and code signing
- [ ] Create Git repository with CI/CD (GitHub Actions)
- [ ] Setup SwiftLint and SwiftFormat
- [ ] Create initial documentation

**Deliverable**: Empty project builds and passes CI.

### Week 2: Audio Infrastructure

- [ ] Implement `AudioManager` class
  - [ ] AVAudioEngine setup
  - [ ] Microphone capture with async stream
  - [ ] Speaker output
  - [ ] Device enumeration
  - [ ] Format conversion (48kHz ↔ 16kHz)
- [ ] Implement `VirtualDeviceManager`
  - [ ] BlackHole detection
  - [ ] Bundled installer
  - [ ] Device configuration
- [ ] Create audio monitoring utilities
  - [ ] Level meters
  - [ ] Latency measurement

**Deliverable**: App captures mic audio and routes through BlackHole.

### Week 3: Basic UI

- [ ] Create SwiftUI app structure
  - [ ] Main window layout
  - [ ] Menu bar integration (optional)
  - [ ] Settings window
- [ ] Implement device selectors
  - [ ] Input device dropdown
  - [ ] Output device dropdown
  - [ ] Virtual device status indicator
- [ ] Create audio level indicators
  - [ ] Input level meter (VU)
  - [ ] Output level meter
- [ ] Add start/stop controls
  - [ ] Main toggle button
  - [ ] Status indicator (idle/active/error)

**Deliverable**: Functional UI with audio device selection.

---

## 📋 MILESTONE 2: Speech Pipeline (Weeks 4-6)

**Goal**: Implement VAD, STT, and TTS with basic pipeline.

### Week 4: Voice Activity Detection

- [ ] Implement `VADService` protocol
- [ ] Implement `FluidAudioVAD` (primary)
  - [ ] Silero VAD integration
  - [ ] Streaming API
  - [ ] Speech start/end events
- [ ] Implement `SimpleEnergyVAD` (fallback)
- [ ] Create `VADFactory` for selection
- [ ] Add VAD status to UI

**Deliverable**: App detects when user starts/stops speaking.

### Week 5: Speech Recognition

- [ ] Implement `SpeechRecognizerService` protocol
- [ ] Implement `AppleSpeechRecognizer`
  - [ ] On-device recognition
  - [ ] Multi-language support
  - [ ] Partial results streaming
- [ ] Implement `FluidAudioRecognizer` (optional Phase 2 prep)
- [ ] Create `RecognizerFactory`
- [ ] Add transcription display to UI

**Deliverable**: App transcribes speech in real-time.

### Week 6: Speech Synthesis

- [ ] Implement `SynthesisService` protocol
- [ ] Implement `AppleSynthesizer`
  - [ ] AVSpeechSynthesizer wrapper
  - [ ] Voice catalog per language
  - [ ] Rate/pitch control
  - [ ] Audio buffer capture
- [ ] Create voice selector UI
- [ ] Implement basic pipeline test
  - [ ] Mic → VAD → STT → TTS → Speaker

**Deliverable**: Complete speech echo pipeline (same language).

---

## 📋 MILESTONE 3: Translation Core (Weeks 7-9)

**Goal**: Add on-device translation capability.

### Week 7: Translation Service

- [ ] Implement `TranslationService`
- [ ] Implement `TranslationBridge` (SwiftUI workaround)
  - [ ] Hidden hosting view
  - [ ] Async translation API
- [ ] Handle language pack downloads
  - [ ] Progress UI
  - [ ] Offline detection
- [ ] Create language pair validation

**Deliverable**: Translation works in background context.

### Week 8: Pipeline Integration

- [ ] Integrate translation into pipeline
  - [ ] VAD → STT → Translation → TTS
  - [ ] Bidirectional support preparation
- [ ] Add language selectors to UI
  - [ ] Source language picker
  - [ ] Target language picker
  - [ ] Swap button
- [ ] Implement translation cache
  - [ ] LRU cache for common phrases
  - [ ] Persistence

**Deliverable**: Full translation pipeline (one direction).

### Week 9: Optimization

- [ ] Measure and optimize latency
  - [ ] Per-stage timing
  - [ ] Bottleneck identification
- [ ] Implement `DelayManager`
  - [ ] Configurable buffer
  - [ ] Auto-calibration
- [ ] Test all language pairs
- [ ] Performance profiling

**Deliverable**: Translation with <3s latency.

---

## 📋 MILESTONE 4: Voice Training System (Weeks 10-12)

**Goal**: Implement voice profile training and DSP styling.

### Week 10: Voice Profile Infrastructure

- [ ] Implement `VoiceProfile` model
- [ ] Implement `VoiceProfileManager`
  - [ ] Create/save/load/delete
  - [ ] Encrypted storage
- [ ] Implement `VoiceAnalyzer`
  - [ ] Pitch extraction (autocorrelation)
  - [ ] Formant analysis (LPC)
  - [ ] MFCC calculation
  - [ ] Speaking rate estimation
- [ ] Create training phrase database

**Deliverable**: Voice analysis extracts characteristics.

### Week 11: Training UI

- [ ] Create training wizard
  - [ ] Welcome/instructions
  - [ ] Language selection
  - [ ] Phrase display
  - [ ] Recording controls
  - [ ] Waveform visualization
  - [ ] Quality indicator
  - [ ] Progress tracking
- [ ] Implement recording quality checks
  - [ ] Volume validation
  - [ ] Noise detection
  - [ ] Completeness check

**Deliverable**: User can complete voice training.

### Week 12: Voice Style Transfer

- [ ] Implement `DSPVoiceStyleTransfer`
  - [ ] Pitch shifting (AVAudioUnitTimePitch)
  - [ ] Time stretching
  - [ ] Formant EQ shaping
  - [ ] Energy normalization
- [ ] Integrate into pipeline
- [ ] Add enable/disable toggle
- [ ] Quality testing and tuning

**Deliverable**: TTS output styled to match user voice.

---

## 📋 MILESTONE 5: Full Pipeline (Weeks 13-16)

**Goal**: Complete bidirectional translation with polish.

### Week 13: Bidirectional Pipeline

- [ ] Implement dual pipelines
  - [ ] Outgoing: You → Remote (virtual mic)
  - [ ] Incoming: Remote → You (speakers)
- [ ] Implement `TranslationCoordinator`
  - [ ] Pipeline state management
  - [ ] Resource coordination
- [ ] Handle conflicts (both speaking)

**Deliverable**: Both directions working.

### Week 14: Echo Cancellation

- [ ] Implement `HalfDuplexManager`
  - [ ] State machine (listening/speaking/transition)
  - [ ] Automatic switching
  - [ ] 300ms transition buffer
- [ ] Add visual state indicator
  - [ ] Green mic = listening
  - [ ] Red mic = speaking (TTS playing)
- [ ] Test with real calls

**Deliverable**: No echo/feedback in calls.

### Week 15: Real-World Testing

- [ ] Test with video call apps
  - [ ] Zoom
  - [ ] Microsoft Teams
  - [ ] Google Meet
  - [ ] Discord
- [ ] Test language pairs
  - [ ] EN ↔ ES (primary)
  - [ ] EN ↔ FR
  - [ ] EN ↔ DE
- [ ] Long conversation testing (30+ minutes)
- [ ] Bug fixing sprint

**Deliverable**: Works reliably with major apps.

### Week 16: Polish

- [ ] UI refinement
  - [ ] Animations
  - [ ] Error states
  - [ ] Loading indicators
- [ ] Performance optimization
  - [ ] Memory usage
  - [ ] CPU usage
  - [ ] Battery impact
- [ ] Documentation updates

**Deliverable**: MVP ready for beta.

---

## 📋 MILESTONE 6: Beta Release (Weeks 17-20)

**Goal**: Testing and stabilization.

### Week 17-18: Beta Testing

- [ ] Recruit 50+ beta testers
- [ ] Create feedback collection system
- [ ] Monitor crash reports
- [ ] Collect usage analytics (opt-in)
- [ ] Weekly bug fixing sprints

### Week 19-20: Stabilization

- [ ] Address critical bugs
- [ ] Performance improvements
- [ ] UX refinements based on feedback
- [ ] Final testing pass
- [ ] Prepare for release

**Deliverable**: Stable MVP ready for launch.

---

## 📋 MILESTONE 7: Enhanced Features (Weeks 21-24)

**Goal**: Add Phase 2 technologies.

### Week 21-22: FluidAudio STT Integration

- [ ] Integrate FluidAudio Parakeet for European languages
- [ ] A/B testing vs Apple Speech
- [ ] Language-based automatic selection
- [ ] Performance comparison

### Week 23-24: MLX-Audio TTS

- [ ] Setup MLX-Audio server
- [ ] Integrate Kokoro TTS
- [ ] Quality comparison with AVSpeech
- [ ] User preference toggle

**Deliverable**: Enhanced STT and TTS quality.

---

## 📋 MILESTONE 8: Neural Voice Cloning (Months 7-9)

**Goal**: Real voice cloning with MLX-Audio CSM.

### Implementation

- [ ] MLX-Audio CSM-1B integration
- [ ] Reference audio collection (30s)
- [ ] Swift ↔ Python bridge (REST API)
- [ ] Quality evaluation
- [ ] Performance optimization

**Deliverable**: Voice cloning that actually sounds like the user.

---

## 📋 MILESTONE 9: Public Launch (Month 9)

### Distribution

- [ ] Code signing and notarization
- [ ] DMG installer creation
- [ ] Website/landing page
- [ ] GitHub release
- [ ] Product Hunt launch
- [ ] Press outreach

### Post-Launch

- [ ] Monitor user feedback
- [ ] Quick bug fixes
- [ ] Community building
- [ ] Roadmap for v2.0

---

## 📊 Success Metrics

### MVP (Month 6)
| Metric | Target |
|--------|--------|
| Latency | < 3 seconds |
| STT Accuracy | > 90% (clear speech) |
| Translation Quality | > 85% BLEU |
| Voice Similarity | > 60% subjective |
| Beta Testers | 50+ |
| Satisfaction | > 4/5 |

### Launch (Month 9)
| Metric | Target |
|--------|--------|
| Active Users | 500+ |
| Daily Active | 100+ |
| App Store Rating | > 4.0 |
| Crash Rate | < 0.1% |

### v2.0 (Month 12)
| Metric | Target |
|--------|--------|
| Active Users | 2,000+ |
| Languages | 10+ pairs |
| Neural Voice Cloning | > 80% similarity |

---

## 🔧 Resource Requirements

### Solo Developer
- Multiply all timelines by 1.5-2x
- MVP: 9-12 months
- Focus on core features only

### Small Team (2-3)
- Timeline as documented
- MVP: 6 months
- One dev on audio/ML, one on UI/integration

### Part-Time (20 hrs/week)
- Multiply by 2x
- MVP: 12 months

---

## 📌 Critical Path

```
M0 (PoC) → M1 (Audio) → M2 (Speech) → M3 (Translation) → M5 (Full Pipeline) → M6 (Beta)
                                            ↓
                                    M4 (Voice Training) - can parallel with M3
```

**Blockers to Watch**:
1. Translation API SwiftUI dependency
2. FluidAudio integration complexity
3. Voice cloning quality threshold
4. BlackHole installation reliability

---

**Last Updated**: December 2025
**Version**: 2.0
**Status**: Ready for Development
