# M9 — UI Redesign — Design Brief

> Status: DRAFT (2026-10-17), from the brainstorm with the user. Input for the pen.dev prototype (`design/translatecall.pen`) and, later, the SwiftUI SDD feature.
> Platform: **macOS app** (macOS 15+, SwiftUI + AppKit). Native Mac conventions, not a web or mobile layout.

## Intent

TranslateCall must be as easy to use as the live interpreter built into Microsoft Teams, but work with any video-call app. Today the main window exposes the machinery (STT/TTS engine pickers, VAD engine, pause slider, metrics) in one long 480×760 pt stack. The user wants a product that a non-technical person can start in a few clicks and then forget about during the call.

User's words (2026-10-17): "uso sencillo… algo como lo que hace Teams, pero para varias aplicaciones"; during the call, "poder ver que la traducción está en marcha sin molestar demasiado en la videollamada".

## The user's flow (decided by the user)

1. **Pick the call app.** The user chooses which application translation applies to (Teams, Zoom, Google Meet in a browser, FaceTime, …). TranslateCall detects whether it is running and, if not, launches it.
2. **Pick two languages:** "my language" and "their language".
3. **TranslateCall picks the best models by itself** for that pair (STT, translation, TTS). No engine choice in the normal flow.
4. **Optional voice-clone test before starting:** the user records a sample so the other side hears the translation in the user's own voice.
5. **During the call: a small status window** shows that translation is running and working, without getting in the way of the video call.

## Goals

- Start a translated call in at most three choices (app, my language, their language) plus Start.
- The in-call status window is small and unobtrusive, yet makes it obvious at a glance that translation is alive and in which direction it is working.
- Engine selection is automatic and invisible by default.
- Voice cloning is an optional, guided step, offered before a call.

## Non-goals

- Changing the speech pipeline or latency (separate M9 thread, see the latency research).
- Translating text chat, subtitles inside the call app, or meeting summaries.
- Windows/iOS versions.

## Anti-goals (a failure even if it works)

- The status window covers faces or the call app's controls, or steals focus/keystrokes from the call app.
- The user has to understand STT/TTS/VAD/engines to start a call.
- Modal alerts appear during a call (consistent with F8.5.4: no modal alerts mid-call).

## Privacy (decided by the user, 2026-10-17)

Privacy is one of the product's core ideas. Everything runs on the device. Automatic model selection only picks on-device engines. A cloud engine (e.g. Edge TTS) is used only when the user explicitly chooses it, with consent at that moment. The UI should make "on-device" visible as a reassurance (e.g. a small "On-device" mark on the setup screen and status panel), and show clearly when a cloud engine is active.

## Advanced model choice per language pair (decided by the user, 2026-10-17)

From the setup screen, an "Advanced…" entry next to the language pair opens a sheet that lists, for each stage (speech recognition, translation, voice), the models tested for that pair. The recommended one is preselected. The user can pick another, including a cloud model; cloud models are clearly marked and ask for consent when chosen.

## Voice clone recording (decided by the user, 2026-10-17)

The user reads a script shown on screen, so the sample covers the intonation the model needs. The UI must mark the pauses the user has to respect and guide the reading speed. Claude's proposals on top: one sentence at a time (teleprompter), the script mixes statements, questions, exclamations and lists; live checks for background noise, volume and pace; re-record a single sentence; a final preview of the cloned voice speaking the other language. The exact script also serves as the reference transcript for Qwen3-TTS.

## Constraints

- macOS 15+, SwiftUI + AppKit, no app sandbox (BlackHole routing).
- Audio routing still needs BlackHole 2ch and the call app's mic set to BlackHole; the first-run setup cannot disappear, only get simpler.
- Translation must keep running with every window closed (menu-bar operation, F8.5.4).
- Headphones are the default; "I use speakers" stays opt-in.
- Priority pairs ES↔EN, DE↔EN, ES↔DE; the language picker must still allow the other supported languages.
- Language packs must be downloaded before Start (F8.5.4 refuses to start otherwise); the UI must make that a step, not an error.
- UI strings in English (app language).
- Leave room for future states: streaming partial transcripts, speculative "translating…", latency indicator.

## Screens to design (in this order, each validated with the user)

1. **Main window — call setup:** app picker (with running/not-running state and "Open" action), my language / their language, voice option (my cloned voice / standard voice), Start.
2. **In-call status window:** compact floating panel.
3. **Menu bar popover:** quick Start/Stop, current state, open main window.
4. **Voice clone flow:** record sample → preview → save.
5. **First-run setup:** BlackHole check, call-app mic routing, permissions (mic, screen recording).
6. **Settings, with an Advanced section.**
7. **States and errors:** language download, call app not found, incoming audio failed, permissions missing.

## Claude's calls (not confirmed by the user — check while reading)

- **Native macOS look:** system materials (vibrancy), SF Symbols, system font, automatic light/dark mode, standard macOS controls. No custom brand palette beyond an accent color.
- **Status window:** an always-on-top floating panel (`NSPanel`, non-activating, so it never takes focus from the call), roughly 320×~120 pt, draggable, remembers its position, default top-right corner. Content:
  - a live indicator per direction ("You → DE" and "Them → ES") showing listening / translating / speaking;
  - the last translated line of each direction, one line each, truncated;
  - Pause/Stop control;
  - expandable to a full transcript timeline on demand (collapsed by default).
- **Main window** becomes a short setup screen (~420 pt wide) instead of the long stack; transcripts move to the status window's expanded view.
- **Advanced settings** hold: STT/TTS/translation engine overrides, VAD engine, STT/TTS metrics, Edge TTS consent (the opt-in to use a cloud engine lives here).
- **The "Pause to translate" slider** stays reachable in normal Settings (not Advanced), reworded for non-technical users (e.g. "Faster replies ↔ Wait for full sentences"). The user flagged the slider in the brainstorm; this is Claude's reading of that comment.
- **"I use speakers"** stays in normal Settings.
- **Voice clone:** recorded once, saved as a profile, then a simple on/off ("Use my voice") on the setup screen. Multiple profiles stay supported but tucked away.
- **Supported call apps list:** Teams, Zoom, Google Meet (browser), FaceTime, Webex, Slack, plus "Other app…".
- **Menu bar** stays: TranslateCall is usable from the menu bar alone.
- **What the app picker drives:** the ScreenCaptureKit source for incoming audio (as today) and the per-app text of the "set BlackHole as your microphone" instructions in first-run setup. One generic setup flow with per-app copy, not a separate flow per app. A browser-based call (Meet) captures the whole browser, as today. "Outgoing only" (no capture app) stays available under "Other app…".
- **"Use my voice" availability:** Qwen3-TTS covers the priority languages (ES/EN/DE). For a target language it can't voice, the toggle is shown disabled with a one-line reason. The clone flow includes the model download step when the model isn't on disk yet.
- **Prototype scope:** static high-fidelity frames in pen.dev, light mode first; dark-mode variants only for the main window and the status panel. Future states (partial transcripts, latency indicator) get reserved space in the status panel, not full designs.
- **Status panel over full-screen call apps:** shown (auxiliary panel). The app keeps its Dock icon while the main window is open. After Start, the main window hides and the status panel appears.

## Left to the builder (the prototype)

- Exact sizes, spacing, icons and copy, within macOS Human Interface Guidelines.
- Visual treatment of the per-direction states and of the level meter (if kept).
- How the language download step is shown inside the setup screen.
