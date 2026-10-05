# TranslateCall - Compatibility Matrix

> **Last Updated**: December 2025
> **Version**: 2.0

This document provides compatibility information for languages, applications, hardware, and technologies.

---

## 🌐 Language Support

### Speech Recognition (STT)

#### Apple Speech Framework (MVP)
**50+ languages supported**

| Language | Code | On-Device | Quality |
|----------|------|-----------|---------|
| English (US) | en-US | ✅ | ⭐⭐⭐⭐⭐ |
| English (UK) | en-GB | ✅ | ⭐⭐⭐⭐⭐ |
| Spanish (Spain) | es-ES | ✅ | ⭐⭐⭐⭐⭐ |
| Spanish (Mexico) | es-MX | ✅ | ⭐⭐⭐⭐⭐ |
| French | fr-FR | ✅ | ⭐⭐⭐⭐⭐ |
| German | de-DE | ✅ | ⭐⭐⭐⭐⭐ |
| Italian | it-IT | ✅ | ⭐⭐⭐⭐ |
| Portuguese (Brazil) | pt-BR | ✅ | ⭐⭐⭐⭐ |
| Chinese (Mandarin) | zh-CN | ✅ | ⭐⭐⭐⭐ |
| Japanese | ja-JP | ✅ | ⭐⭐⭐⭐ |
| Korean | ko-KR | ✅ | ⭐⭐⭐⭐ |
| Russian | ru-RU | ✅ | ⭐⭐⭐⭐ |
| Arabic | ar-SA | ✅ | ⭐⭐⭐ |

#### FluidAudio Parakeet (Phase 2)
**25 European languages - Higher accuracy**

| Language | Supported | Notes |
|----------|-----------|-------|
| English | ✅ | Excellent accuracy |
| Spanish | ✅ | Excellent accuracy |
| French | ✅ | Excellent accuracy |
| German | ✅ | Excellent accuracy |
| Italian | ✅ | Excellent accuracy |
| Portuguese | ✅ | Excellent accuracy |
| Dutch | ✅ | Very good |
| Polish | ✅ | Very good |
| Russian | ✅ | Very good |
| Ukrainian | ✅ | Very good |
| Czech | ✅ | Good |
| Romanian | ✅ | Good |
| Hungarian | ✅ | Good |
| Greek | ✅ | Good |
| Finnish | ✅ | Good |
| Swedish | ✅ | Good |
| Norwegian | ✅ | Good |
| Danish | ✅ | Good |
| Chinese | ❌ | Not supported |
| Japanese | ❌ | Not supported |
| Korean | ❌ | Not supported |
| Arabic | ❌ | Not supported |

#### whisper.cpp / Lightning Whisper MLX (Phase 2+)
**99+ languages - Best coverage**

All Whisper-supported languages available with excellent accuracy.

---

### Translation (Apple Translation Framework)

| From → To | Supported | Quality | Notes |
|-----------|-----------|---------|-------|
| EN ↔ ES | ✅ Direct | ⭐⭐⭐⭐⭐ | Best quality |
| EN ↔ FR | ✅ Direct | ⭐⭐⭐⭐⭐ | Best quality |
| EN ↔ DE | ✅ Direct | ⭐⭐⭐⭐⭐ | Best quality |
| EN ↔ IT | ✅ Direct | ⭐⭐⭐⭐ | Very good |
| EN ↔ PT | ✅ Direct | ⭐⭐⭐⭐ | Very good |
| EN ↔ ZH | ✅ Direct | ⭐⭐⭐⭐ | Very good |
| EN ↔ JA | ✅ Direct | ⭐⭐⭐⭐ | Very good |
| EN ↔ KO | ✅ Direct | ⭐⭐⭐⭐ | Very good |
| EN ↔ RU | ✅ Direct | ⭐⭐⭐ | Good |
| EN ↔ AR | ✅ Direct | ⭐⭐⭐ | Good |
| EN ↔ NL | ✅ Direct | ⭐⭐⭐⭐ | Very good |
| EN ↔ PL | ✅ Direct | ⭐⭐⭐ | Good |
| EN ↔ TH | ✅ Direct | ⭐⭐⭐ | Good |
| EN ↔ TR | ✅ Direct | ⭐⭐⭐ | Good |
| EN ↔ UK | ✅ Direct | ⭐⭐⭐ | Good |
| EN ↔ VI | ✅ Direct | ⭐⭐⭐ | Good |
| ES ↔ FR | ⚠️ Via EN | ⭐⭐⭐ | +300ms latency |
| ES ↔ DE | ⚠️ Via EN | ⭐⭐⭐ | +300ms latency |
| FR ↔ DE | ⚠️ Via EN | ⭐⭐⭐ | +300ms latency |
| ZH ↔ JA | ⚠️ Via EN | ⭐⭐⭐ | +300ms latency |

**Note**: Non-English pairs route through English, adding ~300ms latency.

---

### Text-to-Speech (TTS)

#### AVSpeechSynthesizer (MVP)

| Language | Premium Voice | Enhanced Voice | Standard |
|----------|--------------|----------------|----------|
| English (US) | ✅ Samantha, Alex | ✅ Multiple | ✅ |
| English (UK) | ✅ Daniel | ✅ Multiple | ✅ |
| Spanish (ES) | ✅ Mónica, Jorge | ✅ Multiple | ✅ |
| Spanish (MX) | ✅ Paulina | ✅ Multiple | ✅ |
| French | ✅ Thomas, Amélie | ✅ Multiple | ✅ |
| German | ✅ Anna | ✅ Multiple | ✅ |
| Italian | ✅ Alice, Luca | ✅ Multiple | ✅ |
| Portuguese | ✅ Luciana | ✅ Multiple | ✅ |
| Chinese | ✅ Ting-Ting | ✅ Multiple | ✅ |
| Japanese | ✅ Kyoko, Otoya | ✅ Multiple | ✅ |
| Korean | ✅ Yuna | ✅ Multiple | ✅ |

#### MLX-Audio Kokoro (Phase 2)

| Feature | Status |
|---------|--------|
| Quality | ⭐⭐⭐⭐⭐ Superior |
| Languages | Growing (English primary) |
| Voice Selection | Multiple voices |
| Speed Control | ✅ 0.5x - 2.0x |
| Integration | REST API |

---

## 💻 Video Calling Apps

### Verification Status

| App | Status | Platform | Configuration |
|-----|--------|----------|---------------|
| **Zoom** | 🟢 Verified | Desktop | Settings → Audio → Mic: "BlackHole 2ch" |
| **Microsoft Teams** | 🟢 Verified | Desktop | Settings → Devices → Mic: "BlackHole 2ch" |
| **Google Meet** | 🟢 Verified | Chrome | Settings ⚙️ → Audio → Mic: "BlackHole 2ch" |
| **FaceTime** | 🟢 Verified | macOS | System audio routing via BlackHole |
| **Discord** | 🟢 Verified | Desktop | Voice Settings → Input: "BlackHole 2ch" |
| **Slack Huddles** | 🟢 Verified | Desktop | Preferences → Audio → Mic: "BlackHole 2ch" |
| **WebEx** | 🟡 Expected | Desktop | Audio settings → Mic: "BlackHole 2ch" |
| **Skype** | 🟡 Expected | Desktop | Audio settings → Mic: "BlackHole 2ch" |
| **Jitsi Meet** | 🟡 Expected | Web | Browser audio permissions |

### Configuration Guide

**Zoom**:
```
1. Open Zoom Settings
2. Go to Audio tab
3. Microphone: Select "BlackHole 2ch"
4. Speaker: Your normal speakers (or "BlackHole 2ch" for full loop)
5. Uncheck "Automatically adjust microphone volume"
```

**Microsoft Teams**:
```
1. Click profile icon → Settings
2. Go to Devices
3. Microphone: Select "BlackHole 2ch"
4. Speaker: Your normal speakers
```

**Google Meet**:
```
1. In a meeting, click ⋮ → Settings
2. Audio tab
3. Microphone: Select "BlackHole 2ch"
4. Speakers: Your normal speakers
```

---

## 🖥️ System Requirements

### Minimum Requirements

| Component | Requirement |
|-----------|-------------|
| **macOS** | 14.0 (Sonoma) |
| **Processor** | Apple Silicon M1 or Intel Core i5 (2018+) |
| **RAM** | 8 GB |
| **Storage** | 2 GB free |
| **Audio** | Built-in mic + speakers |

### Recommended Requirements

| Component | Requirement |
|-----------|-------------|
| **macOS** | 15.0 (Sequoia) or later |
| **Processor** | Apple Silicon M2 or newer |
| **RAM** | 16 GB |
| **Storage** | 5 GB free |
| **Audio** | External mic + headphones |

### Performance by Hardware

| Hardware | Expected Latency | CPU Usage | Battery Impact |
|----------|------------------|-----------|----------------|
| M1 | ~2.5s | 25-35% | Moderate |
| M1 Pro/Max | ~2.3s | 20-30% | Low |
| M2 | ~2.2s | 20-30% | Low |
| M2 Pro/Max | ~2.0s | 15-25% | Low |
| M3 | ~2.0s | 15-25% | Very Low |
| M3 Pro/Max | ~1.8s | 10-20% | Very Low |
| M4 | ~1.8s | 10-20% | Very Low |
| Intel i5 | ~3.0s | 40-50% | High |
| Intel i7+ | ~2.7s | 35-45% | Moderate-High |

### Neural Engine Usage

| Feature | Uses ANE | Benefit |
|---------|----------|---------|
| FluidAudio VAD | ✅ | Low power, fast |
| FluidAudio ASR | ✅ | 209x RTF |
| Apple Speech | ✅ | Efficient |
| Apple Translation | ✅ | Fast |
| MLX-Audio TTS | ✅ | Quality + speed |
| MLX-Audio CSM | ✅ | Real-time cloning |

---

## 🎤 Audio Devices

### Verified Microphones

| Type | Status | Quality | Notes |
|------|--------|---------|-------|
| Mac built-in mic | ✅ | ⭐⭐⭐ | OK in quiet environments |
| AirPods Pro | ✅ | ⭐⭐⭐⭐ | Good noise cancellation |
| AirPods Max | ✅ | ⭐⭐⭐⭐⭐ | Excellent quality |
| USB Condenser (Blue Yeti) | ✅ | ⭐⭐⭐⭐⭐ | Best for clear capture |
| USB Headset | ✅ | ⭐⭐⭐⭐ | Good for calls |
| Generic Bluetooth | ⚠️ | ⭐⭐⭐ | May add latency |
| Webcam mic | ⚠️ | ⭐⭐ | Lower quality |

### Recommendations

**Best Setup**:
- Input: USB condenser microphone or AirPods Pro
- Output: Headphones (prevents echo/feedback)

**Minimum Setup**:
- Input: Built-in Mac microphone
- Output: Built-in speakers (may need echo management)

---

## 🔧 Technology Compatibility

### Framework Versions

| Technology | Minimum Version | Recommended |
|------------|-----------------|-------------|
| macOS | 14.0 | 15.0+ |
| Xcode | 15.0 | 16.0+ |
| Swift | 5.9 | 6.0 |
| SwiftUI | 5.0 | 6.0 |

### Third-Party Dependencies

| Package | Version | License | Required |
|---------|---------|---------|----------|
| BlackHole | 2.0+ | GPL-3.0 | ✅ Yes |
| FluidAudio | Latest | MIT/Apache 2.0 | 🟡 Phase 2 |
| MLX-Audio | Latest | Apache 2.0 | 🟡 Phase 2 |
| whisper.cpp | 1.7+ | MIT | 🟡 Phase 2 |

### Python Requirements (Phase 2)

For MLX-Audio integration:
```
Python 3.10+
mlx >= 0.5.0
mlx-audio >= 0.1.0
soundfile
numpy
```

---

## ⚠️ Known Limitations

### Voice Cloning (Phase 1 - DSP)

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Very high voices (F0 > 300Hz) | Pitch may be incorrect | Manual adjustment |
| Very deep voices (F0 < 100Hz) | Pitch may be incorrect | Manual adjustment |
| Strong accents | Not preserved | By design |
| Complex emotions | Not transferred | Use Phase 2 CSM |

### Voice Cloning (Phase 2 - Neural)

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Requires 30s reference | Setup time | One-time training |
| Higher latency (~500ms) | Slightly slower | Accept trade-off |
| Python dependency | Complexity | REST API bridge |

### Translation

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Non-English pairs | +300ms latency | Use English as bridge |
| Slang/colloquialisms | Literal translation | Speak more formally |
| Proper nouns | May translate incorrectly | Spell out if critical |
| Technical jargon | Variable quality | Add context |

### Audio

| Limitation | Impact | Workaround |
|------------|--------|------------|
| Speakers mode ("I use speakers") | Your speech is not sent while the remote translation plays | Use headphones |
| Background noise | Lower STT accuracy | Use quiet environment |
| Echo (no headphones) | Feedback unless "I use speakers" is on | Use headphones, or turn on "I use speakers" |

---

## 📊 Feature Availability by Phase

| Feature | MVP (M1-6) | v1.1 (M7-9) | v2.0 (M10-12) |
|---------|------------|-------------|---------------|
| Basic translation | ✅ | ✅ | ✅ |
| Apple Speech STT | ✅ | ✅ | ✅ |
| FluidAudio VAD | ✅ | ✅ | ✅ |
| FluidAudio STT | ❌ | ✅ | ✅ |
| whisper.cpp STT | ❌ | ❌ | ✅ |
| AVSpeech TTS | ✅ | ✅ | ✅ |
| MLX-Audio Kokoro TTS | ❌ | ✅ | ✅ |
| DSP Voice Styling | ✅ | ✅ | ✅ |
| Neural Voice Cloning | ❌ | ❌ | ✅ |
| Bidirectional | ✅ | ✅ | ✅ |
| 50+ STT languages | ✅ | ✅ | ✅ |
| 99+ STT languages | ❌ | ❌ | ✅ |

---

## 🔄 Upgrade Path

### From MVP to v1.1
- Install FluidAudio Swift package
- Enable Parakeet for European languages
- Add MLX-Audio TTS server
- No breaking changes

### From v1.1 to v2.0
- Add whisper.cpp for full language support
- Enable MLX-Audio CSM voice cloning
- Collect 30s reference audio from users
- No breaking changes

---

**Last Updated**: December 2025
**Version**: 2.0
