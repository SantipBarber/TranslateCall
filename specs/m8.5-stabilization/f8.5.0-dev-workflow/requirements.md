# F8.5.0 — Development Workflow & Verification Tooling

> Status: DRAFT — pending user review (2026-10-03)

## Overview

Establish a professional, reproducible development workflow for TranslateCall before any M8.5 stabilization fix lands. A single `just` entry point runs every check and every test tier on the developer's Mac mini; GitHub runs only cheap static checks on Linux and enforces that the full local suite passed on the exact commit being merged.

## Motivation

- The project was paused ~6 months (last commit 2026-04-11). A code audit on 2026-10-03 found critical bugs that the existing 378 tests did not catch (stream not recreated after Stop→Start, unbounded 48 kHz stream leak, Edge TTS playback poll that never ends, decorative mic selector, unused Silero VAD).
- The build currently fails on Xcode 27 (Metal Toolchain missing for mlx-swift); there is no shared scheme, no test plan, no linter installed, and no static analysis.
- The existing GitHub CI (`.github/workflows/ci.yml`) targets Xcode 16 on a macOS runner and would fail; a macOS runner is slow (~20–30 min with MLX) and never matches the local Xcode version.
- No end-to-end latency has ever been measured (`docs/m8-testing-status.md`, `ROADMAP.md` gates unchecked).
- Commits went straight to `main` (58 unpushed commits at resume time).

## Decisions taken (brainstorming 2026-10-03)

| ID | Decision |
|----|----------|
| D-1 | All work happens on a branch created from an up-to-date `main`; integration only via PR. |
| D-2 | `just` is the single entry point for building, checking and testing. |
| D-3 | Three test tiers: unit, integration (real Apple frameworks + audio fixtures), full PR gate. |
| D-4 | GitHub runs only Linux static checks (opengrep + SwiftLint). Heavy work runs on the Mac mini (the development machine). |
| D-5 | `just pr` publishes a commit status `local/just-pr` on the exact HEAD SHA; branch protection on `main` requires it. |
| D-6 | Simulated voice calls (container acting as remote participant) are out of scope; audio fixtures are its precursor. |

## Functional Requirements

### FR-8.5.0.1 — Branching & commit conventions

**REQ-W-01**: Branch names SHALL use one of the prefixes `feat/`, `fix/`, `chore/`, `docs/`, `spec/`, `test/`, `refactor/`, followed by a kebab-case slug.

**REQ-W-02**: Commit messages SHALL follow Conventional Commits (`<type>(<scope>): <summary>`), types matching the branch prefixes.

**REQ-W-03**: PRs SHALL be squash-merged and the branch deleted after merge.

**REQ-W-04**: A PR template SHALL include a checklist: linked spec/tasks, tests added or updated, `just pr` passed, docs updated if behavior changed.

### FR-8.5.0.2 — `just` recipes

**REQ-W-10**: A `justfile` at the repository root SHALL provide at minimum:

| Recipe | Purpose |
|--------|---------|
| `setup` | Install/verify tooling (opengrep, SwiftLint, xcbeautify, Metal Toolchain); report BlackHole presence and installed TTS voices |
| `build` | Debug build of the app |
| `test` | Unit tier |
| `test-integration` | Integration tier |
| `lint` | SwiftLint in strict mode |
| `scan` | opengrep with project rules |
| `check` | `lint` + `scan` (identical to what GitHub runs) |
| `fixtures` | Regenerate audio fixtures |
| `pr` | Full gate (see FR-8.5.0.5) |

**REQ-W-11**: Running `just` with no arguments SHALL list recipes with their descriptions.

**REQ-W-12**: Every recipe SHALL exit non-zero on any failure; no recipe SHALL silently skip a step. A step that cannot run (e.g. missing tool) SHALL fail with an actionable message, never pass.

**REQ-W-13**: Build/test recipes SHALL use a project-local DerivedData path (`build/DerivedData`) so results are reproducible and independent of Xcode's global state.

### FR-8.5.0.3 — Test tiers

**REQ-W-20**: Tests SHALL be classified with Swift Testing tags. Tests tagged `.integration` SHALL belong to the integration tier; all other tests belong to the unit tier.

**REQ-W-21**: The unit tier SHALL complete in under 3 minutes on the Mac mini (after the first build) and SHALL NOT require network, microphone, BlackHole, or model downloads.

**REQ-W-22**: The integration tier SHALL exercise real Apple frameworks (Speech, Translation, AVSpeechSynthesizer) and real on-device models already present, fed by audio fixtures through the production capture protocol — never the microphone.

**REQ-W-23**: Integration tests whose prerequisite is missing (model not downloaded, language pack not installed) SHALL fail with an explicit message naming the prerequisite and the `just setup` hint. They SHALL NOT be reported as passed.

**REQ-W-24**: The integration tier SHALL write per-stage latency (VAD, STT, translation, TTS first-audio, total) for each fixture to `build/reports/latency.json`.

### FR-8.5.0.4 — Audio fixtures

**REQ-W-30**: Audio fixtures SHALL be short WAV files (16 kHz mono, ≤ 8 s) in Spanish, English and Ukrainian, each with a sidecar expected transcript, stored under `TranslateCallTests/Fixtures/Audio/` and committed to git.

**REQ-W-31**: `just fixtures` SHALL regenerate fixtures deterministically from a manifest using macOS `say`; if a required voice is not installed it SHALL fail naming the missing voice.

**REQ-W-32**: Integration assertions SHALL check: word error rate of the transcript against the expected text ≤ a per-language threshold defined in the manifest; translation non-empty; synthesized audio non-empty.

### FR-8.5.0.5 — PR gate (`just pr`)

**REQ-W-40**: `just pr` SHALL refuse to run when the current branch is `main` or the working tree has uncommitted changes.

**REQ-W-41**: `just pr` SHALL run, in order and stopping at the first failure: `build`, `check`, `test`, `test-integration`.

**REQ-W-42**: On success, `just pr` SHALL publish a GitHub commit status with context `local/just-pr`, state `success`, on the HEAD SHA, with a description including the test counts and total duration. On failure it SHALL publish state `failure`.

**REQ-W-43**: `just pr` SHALL push the branch and create the PR if none exists (using the PR template), or leave the existing PR untouched otherwise.

### FR-8.5.0.6 — Static analysis

**REQ-W-50**: opengrep SHALL run with project rules stored in `.opengrep/` covering at least: `asyncstream-force-unwrap`, `asyncstream-unbounded`, `playernode-isplaying-poll`, `buffer-nocopy-escape`, `no-print`, `nonisolated-unsafe-justified`, plus hard-coded secret detection.

**REQ-W-51**: Rules targeting defects that M8.5 will fix SHALL start at severity `WARNING` and be promoted to `ERROR` in the PR that fixes the last occurrence. `ERROR` findings SHALL fail `just scan`; `WARNING` findings SHALL be printed but not fail.

**REQ-W-52**: SwiftLint SHALL run with the existing project configuration in strict mode; pre-existing violations SHALL be fixed or explicitly disabled with justification before the gate is enabled.

### FR-8.5.0.7 — GitHub CI & protection

**REQ-W-60**: `.github/workflows/ci.yml` SHALL be replaced by a single Ubuntu job named `check` running the same opengrep rules and SwiftLint as `just check`, completing in under 3 minutes.

**REQ-W-61**: Branch protection on `main` SHALL require status checks `check` and `local/just-pr`, require a PR, forbid force-push and direct push. Applying it SHALL require explicit user confirmation at the time it is applied.

**REQ-W-62**: A shared Xcode scheme and test plans SHALL be committed so CLI and Xcode run the same configuration.

## Non-Functional Requirements

**NFR-W-01**: `just check` SHALL produce identical findings locally and on GitHub (same tool versions, pinned).

**NFR-W-02**: No secrets or tokens SHALL be stored in the repository; `gh` uses the user's existing authentication.

**NFR-W-03**: The tooling SHALL work on macOS with Xcode 27 and Homebrew; tool versions SHALL be pinned in a single place.

## Out of Scope

- Simulated voice calls / container acting as a remote participant (future).
- Self-hosted GitHub runner (rejected: public repo security risk, D-4/D-5 cover the need).
- Fixing the audited bugs themselves (F8.5.1+), except what is strictly needed to make the build and existing tests pass.
- Performance budgets as failing gates (latency is recorded, not enforced, in this feature).

## Open Questions

- **OQ-1**: Ukrainian `say` voice is not installed on the Mac mini today. Resolution: `just setup` reports it; user installs it once via System Settings → Accessibility → Spoken Content.
- **OQ-2**: Swift support in opengrep is pattern-level; if a rule cannot be expressed reliably it MAY be implemented as a `just scan` grep step with the same rule ID, documented in `.opengrep/README.md`.

## Acceptance Criteria

1. On a fresh clone, `just setup && just pr` on a feature branch either passes and sets `local/just-pr` = success, or fails at a clearly named step.
2. `just test` passes on `main` after this feature merges.
3. A PR to `main` cannot be merged without both `check` and `local/just-pr` green for its HEAD SHA.
4. `build/reports/latency.json` exists after `just test-integration` with entries for ES, EN and UK fixtures.
