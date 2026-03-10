# TranslateCall v0.5.0 Beta

Real-time bidirectional translation for video calls on macOS. Speak in your language — your caller hears theirs, automatically.

## What's New in 0.5.0 Beta

### Full Bidirectional Pipeline (M4)
- **Simultaneous translation** in both directions — outgoing voice (you) and incoming audio (caller) translated independently
- **Half-duplex management** — automatic suppression prevents echo feedback loops between mic and speakers
- **Video call integration** — works with Zoom, Teams, Meet, FaceTime, and more via BlackHole virtual audio routing
- **Setup wizard** — four-step guided setup: BlackHole check → video app instructions → capture source selection → route test

### Stability & Bug Fixes (F5.1)
- Fixed language selection not persisting between app launches (pt-BR vs pt-PT now correctly distinguished)
- Fixed Screen Recording permission dialog appearing multiple times (session cache added)
- Audited session cleanup — no memory leaks on pipeline stop/restart

### UX Polish (F5.2)
- **Menu bar status item** — always visible; left-click opens popover, right-click shows context menu
- **Icon reflects pipeline state**: mic.slash (stopped) → mic (listening) → waveform (speaking)
- **Device persistence** — selected microphone and output device remembered across launches
- **Keyboard shortcuts**: ⌘⇧T to start/stop translation, ⌘⇧M to mute next outgoing turn
- **Mute Turn** — silently skip the next outgoing utterance (press ⌘⇧M before you speak)

## Requirements

- macOS 15.0 or later
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) virtual audio driver (free)
- Compatible video call app (Zoom, Teams, Meet, FaceTime, etc.)
- Internet connection not required — all processing is on-device via Apple frameworks

## Installation

1. Download `TranslateCall-0.5.0-beta.dmg`
2. Open the DMG and drag **TranslateCall.app** to your Applications folder
3. Launch TranslateCall — the setup wizard will guide you through initial configuration
4. Grant Microphone and Screen Recording permissions when prompted

## Known Limitations (Beta)

- Voice cloning / matching caller's voice deferred to M7
- Translation language pairs limited to Apple Translation framework support
- BlackHole 2ch must be installed separately (free from [existential.audio](https://existential.audio/blackhole/))
- Simultaneous translation works best with clear speech and minimal background noise

## Feedback

Found a bug or have a suggestion? Use **Help → Send Feedback…** in the app, or open an issue at:
https://github.com/spbarber/TranslateCall/issues

---

*TranslateCall is in active beta development. Expect rough edges.*
