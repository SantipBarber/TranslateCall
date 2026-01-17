# TranslateCall - Project Overview

## 🎯 Vision

TranslateCall aims to break language barriers in real-time video communication while maintaining complete privacy and natural conversation flow through voice cloning technology.

---

## 🌟 The Problem

Current real-time translation solutions for video calls have significant limitations:

1. **Privacy Concerns**: Most solutions send audio to cloud services (Google, Microsoft, etc.)
2. **Robotic Voices**: Traditional TTS sounds unnatural and impersonal
3. **Latency**: Some solutions have 5-10 second delays
4. **Platform Lock-in**: Limited to specific platforms (e.g., AirPods only with iPhone)
5. **Internet Dependency**: Require constant internet connection
6. **Cost**: Subscription-based cloud APIs add recurring costs

---

## 💡 Our Solution

TranslateCall is a macOS application that:

### Core Functionality
- Acts as an **audio bridge** between your microphone/speakers and video calling apps
- Translates conversations **bidirectionally** in real-time
- Applies **voice cloning** to maintain speaker characteristics
- Processes everything **on-device** for complete privacy

### How It Works

```
┌──────────────────────────────────────────────────────────────┐
│                  VIDEO CALL FLOW                             │
└──────────────────────────────────────────────────────────────┘

YOU (Spanish Speaker)              REMOTE PERSON (English Speaker)
       │                                     │
       │ "Hola, ¿cómo estás?"              │
       ↓                                     │
   [Microphone]                             │
       │                                     │
       ↓                                     │
┌───────────────────────┐                   │
│   TranslateCall App   │                   │
│                       │                   │
│  1. VAD Detection     │  ← FluidAudio     │
│  2. STT: "Hola..."    │  ← Apple Speech   │
│  3. Translate         │  ← Apple Trans.   │
│  4. TTS: "Hello..."   │  ← AVSpeech       │
│  5. Apply your voice  │  ← DSP/Neural     │
└───────────────────────┘                   │
       │                                     │
       ↓                                     │
[Virtual Microphone] ───────────────────────→ [Zoom/Teams]
                                             │
                                             ↓
                                    "Hello, how are you?"
                                    (in YOUR voice characteristics)
```

### Key Differentiators

#### 1. 100% On-Device Processing
- Uses Apple's native frameworks (Speech, Translation, AVFoundation)
- Enhanced with FluidAudio for VAD and ASR
- No data leaves your Mac
- Works offline (after language pack downloads)
- No subscription fees

#### 2. Voice Cloning Technology
**Phase 1 (MVP)**: DSP-based voice styling
- Captures pitch, rate, formants
- Applies to synthesized speech
- Recognizable but not identical

**Phase 2 (Enhanced)**: Neural voice cloning with MLX-Audio CSM-1B
- Real voice cloning from 30-second sample
- Sounds remarkably like you
- Still 100% on-device

#### 3. Universal Compatibility
- Works with ANY video calling app
- No special integrations needed
- Acts as standard audio devices (via BlackHole)
- Compatible with: Zoom, Teams, Meet, FaceTime, Discord, etc.

#### 4. Low Latency Design
- Target: 2-3 seconds total delay
- Comparable to professional simultaneous interpreters
- FluidAudio Silero VAD for fast speech detection
- Optimized pipeline with Apple Neural Engine

---

## 🎯 Target Users

### Primary Audience
1. **International Business Professionals**
   - Regular calls with international clients/partners
   - Need professional, natural-sounding translations
   - Privacy-sensitive conversations

2. **Remote Teams**
   - Distributed teams across language barriers
   - Daily standups and meetings
   - Need low-latency, natural communication

3. **Healthcare Professionals**
   - Telemedicine with international patients
   - HIPAA/privacy compliance critical
   - Need accurate, professional communication

4. **Language Learners**
   - Want to practice with native speakers
   - Benefit from hearing translations
   - Need support for understanding

### Secondary Audience
- Family video calls across languages
- Online education/tutoring
- Content creators doing international interviews
- Gaming communities

---

## 🏗️ Technology Stack

### Core Apple Frameworks
- **AVFoundation**: Audio capture and playback
- **Speech Framework**: On-device speech recognition
- **Translation Framework**: On-device translation
- **Accelerate**: DSP for voice processing
- **SwiftUI**: Modern UI

### Enhanced Third-Party (Phase 2+)
- **FluidAudio**: Superior VAD (Silero) and ASR (Parakeet)
- **MLX-Audio**: High-quality TTS (Kokoro) and voice cloning (CSM-1B)
- **whisper.cpp**: Full language support (99+ languages)
- **BlackHole**: Virtual audio devices

### Why This Stack?
| Requirement | Solution | Why |
|-------------|----------|-----|
| Privacy | All on-device | No cloud APIs |
| Speed | Apple Neural Engine | Hardware acceleration |
| Quality | FluidAudio + MLX | State-of-the-art models |
| Compatibility | BlackHole | Works with any app |
| Maintainability | Native Swift | First-class Apple support |

---

## 🔒 Privacy & Security Model

### Principles
1. **Data Minimization**: Only process what's necessary
2. **Local Processing**: Never send data to external servers
3. **Transparency**: Clear about what data is processed
4. **User Control**: Users own their voice profiles

### Technical Implementation
- All audio processing in memory (not saved)
- Voice profiles stored locally, encrypted
- No analytics, telemetry, or tracking
- No network requests except language pack downloads
- Maintains E2E encryption of underlying video call

### Compliance
- **GDPR**: Compliant (no data collection)
- **HIPAA**: Friendly (on-device processing)
- **CCPA**: Compliant (no data sale/sharing)

---

## 📊 Technology Discovery (December 2025)

Recent research uncovered powerful new technologies that enhance our architecture:

### FluidAudio Framework
**Repository**: https://github.com/fluidinference/fluidaudio

Native Swift framework with CoreML models optimized for Apple Neural Engine:
- **Silero VAD**: State-of-the-art voice activity detection
- **Parakeet ASR**: ~209x real-time factor, 25 European languages
- **Speaker Diarization**: Who is speaking detection

**Impact**: Replaces custom VAD, optionally enhances STT accuracy.

### MLX-Audio
**Repository**: https://github.com/blaizzy/mlx-audio

MLX-based audio AI optimized for Apple Silicon:
- **Kokoro TTS**: Superior quality synthesis
- **CSM-1B**: Real voice cloning from single sample

**Impact**: Phase 2 voice cloning becomes actually useful (not just "similar").

### Lightning Whisper MLX
**Repository**: https://github.com/mustafaaljadery/lightning-whisper-mlx

Ultra-fast Whisper implementation:
- 99+ languages
- Distilled models available
- 4-bit/8-bit quantization

**Impact**: Future full language support without cloud.

---

## 🔮 Future Enhancements

### Integration with Apple's Personal Voice

Apple introduced **Personal Voice** in iOS 17/macOS 14 as an accessibility feature.

**Opportunity for TranslateCall:**
- If user already trained Personal Voice, we could use it
- Eliminates need for our own training
- Potentially higher quality

**Current Limitations:**
- API designed for accessibility
- Not all users will have it configured
- Limited availability by language

**Status**: Monitoring Apple's API announcements for broader access.

```swift
// Hypothetical future implementation
func usePersonalVoiceIfAvailable() async -> AVSpeechSynthesisVoice? {
    if #available(macOS 15.4, *) {
        let personalVoices = await AVSpeechSynthesisVoice.personalVoices()
        if let voice = personalVoices.first {
            return voice  // Use their existing Personal Voice!
        }
    }
    return nil
}
```

### Apple Foundation Models

macOS 15.4+ includes on-device LLM capabilities:
- Could improve translation context
- Summarize conversations
- Detect tone/intent
- Still 100% on-device

### Platform Expansion
- **iOS Companion App**: Control from iPhone
- **watchOS**: Quick controls from Apple Watch
- **visionOS**: Spatial computing support

---

## 🎯 Success Criteria

### MVP Success (6 months)
- [ ] Working prototype with major language pairs
- [ ] < 3 second latency
- [ ] Acceptable voice styling quality
- [ ] 50+ beta testers
- [ ] Positive user feedback (>4/5)

### Launch Success (9 months)
- [ ] 500+ active users
- [ ] 5+ verified language pairs
- [ ] < 2.5 second latency
- [ ] Mac App Store presence
- [ ] Active community

### Long-term Success (12+ months)
- [ ] 2,000+ active users
- [ ] Neural voice cloning (CSM-1B)
- [ ] Full language support (whisper.cpp)
- [ ] iOS companion app
- [ ] Industry recognition

---

## 💰 Business Model (Future Consideration)

### Free Tier
- Basic translation (Apple Translation)
- Standard TTS voices
- DSP voice styling
- Core features

### Pro Tier ($9.99/month or $99/year)
- Neural voice cloning (MLX-Audio CSM)
- Enhanced TTS (MLX-Audio Kokoro)
- Full language support (whisper.cpp)
- Priority support

### Enterprise
- Team deployment
- Custom integration support
- SLA guarantees

**Note**: Initial release will be free/open-source to build community.

---

## 🛠️ Technical Challenges

### Solved ✅
- Privacy-first architecture
- On-device processing feasibility
- Technology stack selection
- VAD with FluidAudio Silero
- Voice cloning approach (DSP + future Neural)

### In Progress 🔄
- Translation API SwiftUI dependency workaround
- Half-duplex echo management
- Optimal latency tuning

### To Solve ⏳
- Neural voice cloning integration (MLX-Audio)
- Full language support (whisper.cpp)
- Multi-party call handling
- Apple Intelligence integration

---

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Technical architecture and components |
| [TECH_STACK.md](TECH_STACK.md) | Technologies and frameworks |
| [ROADMAP.md](ROADMAP.md) | Development milestones |
| [VOICE_CLONING.md](VOICE_CLONING.md) | Voice cloning system details |
| [PRIVACY_SECURITY.md](PRIVACY_SECURITY.md) | Privacy and security model |
| [COMPATIBILITY_MATRIX.md](COMPATIBILITY_MATRIX.md) | Languages, apps, hardware |
| [DEVELOPMENT_SETUP.md](DEVELOPMENT_SETUP.md) | Developer setup guide |

---

## 🤝 Community & Open Source

### Philosophy
- Open development process
- Community-driven features
- Transparent roadmap
- Documentation-first

### Contribution Areas
- Translation quality improvements
- Voice cloning algorithms
- UI/UX enhancements
- Documentation
- Testing and bug reports
- Localization

---

**Last Updated**: December 2025
**Version**: 2.0
**Status**: Ready for Development
