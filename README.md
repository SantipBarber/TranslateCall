# TranslateCall

**Real-time bidirectional voice translation for video calls - 100% on-device, privacy-first**

[![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## 🎯 Overview

TranslateCall is a macOS application that enables real-time voice translation during video calls (Zoom, Teams, Google Meet, FaceTime, etc.). It acts as an audio bridge between your microphone/speakers and video conferencing apps, translating conversations bidirectionally while preserving voice characteristics.

### Key Features

- ✅ **100% On-Device Processing** - No data leaves your Mac
- 🔄 **Bidirectional Translation** - Both parties hear each other translated
- 🚀 **Low Latency** - ~2-3 seconds (similar to professional interpreters)
- 🔒 **Privacy-First** - All processing happens locally using Apple frameworks
- 🌐 **Multi-Language** - 17+ languages via Apple Translation Framework
- 📱 **Universal Compatibility** - Works with Zoom, Teams, Meet, Discord, and any audio app
- 🎙️ **Voice Cloning** *(Beta)* - Maintains speaker characteristics using DSP

### Technology Stack

| Component | MVP | Enhanced (Phase 2) |
|-----------|-----|-------------------|
| VAD | FluidAudio Silero | FluidAudio Silero |
| STT | Apple Speech | FluidAudio Parakeet |
| Translation | Apple Translation | Apple Translation |
| TTS | AVSpeechSynthesizer | MLX-Audio Kokoro |
| Voice Cloning | DSP (Accelerate) | MLX-Audio CSM-1B |

> **Note**: Voice cloning in MVP uses DSP techniques for pitch/rate matching. Real neural voice cloning (MLX-Audio CSM-1B) is planned for Phase 2.

## 🏗️ Architecture

```
Your Voice (Spanish) → TranslateCall → Translated Voice (English) → Zoom
    ↓                                                                  ↓
Your AirPods ← Translated Voice (Spanish) ← TranslateCall ← Remote Voice (English)
```

All processing happens on-device using:
- **Apple Frameworks**: AVFoundation, Speech, Translation, Accelerate
- **Third-Party**: FluidAudio (VAD/ASR), MLX-Audio (TTS/Voice Cloning), BlackHole (virtual audio)

## 📚 Documentation

### Essential Reading
| Document | Description |
|----------|-------------|
| [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) | Complete project vision and goals |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Technical architecture and components |
| [ROADMAP.md](ROADMAP.md) | Development milestones (includes Milestone 0 PoCs) |
| [PRIVACY_SECURITY.md](PRIVACY_SECURITY.md) | Privacy model and security |

### Technical Deep Dives
| Document | Description |
|----------|-------------|
| [TECH_STACK.md](TECH_STACK.md) | Technologies, frameworks, and alternatives |
| [VOICE_CLONING.md](VOICE_CLONING.md) | Voice analysis and style transfer |
| [COMPATIBILITY_MATRIX.md](COMPATIBILITY_MATRIX.md) | Languages, apps, and hardware |
| [DEVELOPMENT_SETUP.md](DEVELOPMENT_SETUP.md) | Developer setup guide |

## 🚀 Quick Start

### Requirements
- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1/M2/M3/M4) recommended
- Xcode 15.0+
- ~2GB free disk space

### Installation (Coming Soon)
```bash
# Clone the repository
git clone https://github.com/[username]/TranslateCall.git
cd TranslateCall

# Open in Xcode
open TranslateCall.xcodeproj

# Build and run (Cmd + R)
```

## 🎯 Current Status

**Phase**: Pre-Development (Documentation Complete)
**Version**: 0.1.0-alpha

### Completed ✅
- Project architecture design
- Technical documentation (45,000+ words)
- Technology research and selection
- FluidAudio, MLX-Audio discovery and evaluation

### Next Steps
1. **Milestone 0**: Proof of Concepts (2-3 days)
   - Translation API without SwiftUI
   - FluidAudio VAD/ASR integration
   - Voice cloning DSP quality
   - BlackHole integration
   - Half-duplex echo management

2. **Milestone 1**: Foundation (Weeks 1-3)
3. **Milestone 2**: Speech Pipeline (Weeks 4-6)
4. **Milestone 3**: Translation Core (Weeks 7-9)

See [ROADMAP.md](ROADMAP.md) for complete timeline.

## 📊 Roadmap Summary

| Milestone | Duration | Status |
|-----------|----------|--------|
| M0: PoC Testing | 2-3 days | 📋 Planning |
| M1: Foundation | 3 weeks | ⏳ Pending |
| M2: Speech Pipeline | 3 weeks | ⏳ Pending |
| M3: Translation | 3 weeks | ⏳ Pending |
| M4: Voice Training | 3 weeks | ⏳ Pending |
| M5: Full Pipeline | 4 weeks | ⏳ Pending |
| M6: Beta Release | 4 weeks | ⏳ Pending |
| M7: Enhanced Features | 4 weeks | ⏳ Pending |
| M8: Neural Voice Cloning | 8 weeks | ⏳ Pending |
| M9: Public Launch | 2 weeks | ⏳ Pending |

**Estimated MVP**: 6 months
**Public Launch**: 9 months

## 🔒 Privacy

TranslateCall is built with privacy as the #1 priority:

- **No cloud APIs** - All processing on your Mac
- **No data collection** - Zero telemetry or analytics
- **No internet required** - Works offline after setup
- **End-to-end privacy** - Maintains encryption of video calls

Read more: [PRIVACY_SECURITY.md](PRIVACY_SECURITY.md)

## 🤝 Contributing

This project is in early development. Contributions welcome once MVP is complete.

### Areas for Contribution
- Translation quality improvements
- Voice cloning algorithms
- UI/UX enhancements
- Testing and bug reports
- Documentation and localization

## 📄 License

MIT License - See [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- **Apple** - Excellent on-device ML frameworks
- **FluidAudio** - Superior VAD and ASR for Swift
- **MLX-Audio** - High-quality TTS and voice cloning
- **BlackHole** - Virtual audio device capability
- **whisper.cpp** - Full language ASR support

## 📞 Contact

- **Issues**: [GitHub Issues](https://github.com/[username]/TranslateCall/issues)
- **Discussions**: [GitHub Discussions](https://github.com/[username]/TranslateCall/discussions)

---

**Note**: This project is in active development. Features and documentation are subject to change.

Made with ❤️ for privacy-conscious global communicators

---

**Last Updated**: December 2025 | **Version**: 2.0
