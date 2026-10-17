# M9 — UI Redesign — Implementation Roadmap

> Status: AGREED (2026-10-17, brainstorm D-1). Source of truth for what each screen must look like: `design-brief.md` and `design/translatecall.pen` (read only through the pencil MCP).

The SwiftUI implementation of the prototype is split into four sequential SDD features. Each one has its own spec folder under `specs/m9-product/`, its own `spec/<feat>` → `feat/<feat>` branches and its own PR. Each one leaves the app shippable.

| # | Feature | Spec folder | Prototype frames (light; each has a dark twin) | Replaces |
|---|---------|-------------|-----------------------------------------------|----------|
| 1 | **UI core**: setup window, automatic model choice, status panel (compact + expanded), menu bar popover, pre-call and in-call states, Settings scene with General + a temporary "Advanced (legacy)" tab | `ui-core/` | Main Window — Setup; Status Panel — Compact / Expanded; In Context; Menu Bar — Idle / Translating; State — Language not downloaded / Call app not open / Permission missing / Panel: incoming audio lost / Panel: speaker mode & skipped; Settings — General | `ContentView` long stack, `MenuBarPopoverView` |
| 2 | **Settings + "Advanced…" models sheet**: Settings Voices + Advanced (definitive), per-pair model overrides, cloud consent, model downloads | `ui-settings/` (to write) | Advanced — Models for ES ↔ DE; Settings — Voices / Advanced | the "Advanced (legacy)" tab |
| 3 | **First-run setup assistant**: permissions, audio driver, call-app microphone (per-app copy), test | `ui-first-run/` (to write) | Setup — 1…4 | `SetupWizardView` and its steps |
| 4 | **Voice clone flow**: intro, teleprompter recording with live checks, listen & save | `ui-voice-clone/` (to write) | Voice Clone — 1…3 | `VoiceProfileListView` recording path |

Until a feature lands, the screens it replaces stay reachable from the new entry points (feature 1 design §6).

Cross-thread dependency: the status panel's per-direction latency label is fed by the latency thread's `TraceSink` (`spec/m9-benchmark`). Feature 1 ships the slot behind a `LatencyProvider` that returns nothing; a short follow-up task wires the trace once it is on `main` (feature 1 D-3).
