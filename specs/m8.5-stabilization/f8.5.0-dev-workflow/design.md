# F8.5.0 — Development Workflow & Verification Tooling — Technical Design

> Status: DRAFT — pending user review (2026-10-03)

## 1. Overview

```
             Mac mini (developer machine)                         GitHub
 ┌──────────────────────────────────────────────────┐   ┌──────────────────────────┐
 │ just pr                                          │   │ PR opened / updated      │
 │  ├─ guard: branch ≠ main, clean tree             │   │                          │
 │  ├─ build            (xcodebuild, Xcode 27)      │   │ job `check` (ubuntu)     │
 │  ├─ check = lint + scan                          │   │  ├─ swiftlint --strict   │
 │  ├─ test             (TestPlan Unit)             │   │  └─ opengrep .opengrep/  │
 │  ├─ test-integration (TestPlan Integration)      │   │                          │
 │  │     └─ build/reports/latency.json             │   │ branch protection (main) │
 │  ├─ gh api statuses/<sha> local/just-pr ─────────┼──►│  requires: check,        │
 │  └─ git push + gh pr create (if missing)         │   │            local/just-pr │
 └──────────────────────────────────────────────────┘   └──────────────────────────┘
```

GitHub never compiles Swift. The `local/just-pr` status is bound to a SHA, so any new commit invalidates it automatically and requires running `just pr` again.

## 2. Repository layout (new / changed files)

```
justfile                                   NEW  entry point
tools/versions.env                         NEW  pinned tool versions (single source)
tools/scripts/setup.sh                     NEW  install/verify tooling
tools/scripts/pr-status.sh                 NEW  publish commit status via gh
tools/scripts/fixtures.sh                  NEW  regenerate audio fixtures with `say`
tools/scripts/scan.sh                      NEW  opengrep test + WARNING report + ERROR gate
tools/scripts/pr.sh                        NEW  `just pr` implementation
tools/scripts/protect-main.sh              NEW  one-off branch protection
.opengrep/rules/*.yml                      NEW  project rules
.opengrep/README.md                        NEW  rule catalog + severity policy
.github/workflows/ci.yml                   REPLACED  ubuntu `check` job
.github/pull_request_template.md           NEW
CONTRIBUTING.md                            NEW  branch/commit/PR conventions
TranslateCall.xcodeproj/xcshareddata/xcschemes/TranslateCall.xcscheme   NEW (shared)
TranslateCallTests/TestPlans/Unit.xctestplan                             NEW
TranslateCallTests/TestPlans/Integration.xctestplan                      NEW
TranslateCallTests/Support/Tags.swift                                    NEW
TranslateCallTests/Support/FileAudioSource.swift                         NEW
TranslateCallTests/Support/WordErrorRate.swift                           NEW
TranslateCallTests/Support/LatencyReport.swift                           NEW
TranslateCallTests/Fixtures/Audio/manifest.json                          NEW
TranslateCallTests/Fixtures/Audio/*.wav                                  NEW (committed)
TranslateCallTests/Integration/*.swift                                   NEW
```

## 3. Tool pinning

`tools/versions.env` is sourced by `justfile`, `setup.sh` and the CI workflow:

```
# exact versions are chosen and pinned in task 1 (latest stable at that time)
OPENGREP_VERSION=x.y.z
SWIFTLINT_VERSION=x.y.z
XCBEAUTIFY_VERSION=x.y.z
XCODE_VERSION=27.0
```

- **opengrep**: no Homebrew formula exists. `setup.sh` downloads the pinned release binary from GitHub Releases into `tools/bin/` (git-ignored) and verifies its checksum; CI uses the same script on Linux.
- **SwiftLint**: macOS via Homebrew (version verified against the pin); CI uses the official `ghcr.io/realm/swiftlint:<version>` container.
- **xcbeautify**: Homebrew, used only for readable output; the raw `xcodebuild` log is always kept in `build/logs/`.
- **Metal Toolchain**: `setup.sh` checks `xcrun -f metal` and, if missing, runs `xcodebuild -downloadComponent MetalToolchain`.
- `setup.sh` also *reports* (does not fail on) BlackHole presence and installed `say` voices for es_ES, en_US, uk_UA, since only `fixtures` needs them.

## 4. `justfile`

```just
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

derived := "build/DerivedData"
xcb     := "xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS -derivedDataPath " + derived

# List recipes
default:
    @just --list

# Install / verify tooling
setup:
    tools/scripts/setup.sh

# Debug build
build:
    mkdir -p build/logs
    {{xcb}} build 2>&1 | tee build/logs/build.log | xcbeautify

# Unit tier
test:
    {{xcb}} test -testPlan Unit 2>&1 | tee build/logs/test-unit.log | xcbeautify

# Integration tier (real frameworks + fixtures)
test-integration:
    mkdir -p build/reports
    {{xcb}} test -testPlan Integration 2>&1 | tee build/logs/test-integration.log | xcbeautify

lint:
    swiftlint lint --strict

# ERROR findings fail; WARNING findings are listed only (REQ-W-51)
scan:
    tools/scripts/scan.sh   # opengrep test → WARNING report → ERROR gate

check: lint scan

fixtures:
    tools/scripts/fixtures.sh

# Full gate: build → check → tests → commit status → PR
pr:
    tools/scripts/pr.sh
```

`pr.sh` (called by `just pr`) implements REQ-W-40..43:

1. Abort if `git branch --show-current` is `main` or `git status --porcelain` is non-empty.
2. Set status `local/just-pr` = `pending` on HEAD.
3. Run `just build check test test-integration`, timing the whole run. On failure trap: set status `failure` with the failing step name, exit non-zero.
4. Parse test counts from the `.xcresult` bundles (`xcrun xcresulttool get test-results summary`).
5. `git push -u origin HEAD`; set status `success` with description `"<n> unit, <m> integration · <mm:ss>"`.
6. If `gh pr view` finds no PR for the branch, `gh pr create --fill --base main` (template applied automatically).

`scan` runs opengrep twice: a reporting pass for `WARNING` and a failing pass (`--error`) for `ERROR` only (REQ-W-51). Both `just scan` and CI call `tools/scripts/scan.sh`, so both sides stay identical (NFR-W-01).

## 5. Test tiers

### 5.1 Tags and test plans

```swift
// TranslateCallTests/Support/Tags.swift
import Testing
extension Tag {
    @Tag static var integration: Self
}
```

- `Unit.xctestplan`: all tests, **excluding** tag `integration`.
- `Integration.xctestplan`: **only** tag `integration`; `executionTimeAllowance` raised (model warm-up).
- Both plans attached to the shared scheme; Unit is the default plan, so ⌘U in Xcode runs the unit tier.
- Test target settings unified with the app: `SWIFT_VERSION = 6.0`, same development team, deployment target 15.0 (today the test target has 5.0 / 26.2 / a different team — `project.pbxproj:262,270`).

### 5.2 FileAudioSource

Conforms to the production `AudioCapture` protocol (`TranslateCall/Core/Audio/AudioManager.swift:16`), so fixtures enter the pipeline exactly where the microphone does:

```swift
final class FileAudioSource: AudioCapture {
    let audioStream16kHz: AsyncStream<AVAudioPCMBuffer>
    // startCapture(): reads the WAV, yields 1024-frame 16 kHz buffers paced at
    //   real time (or ×N speed-up when `realtime == false`), then appends 1.5 s
    //   of silence so the VAD closes the last segment, then finishes the stream.
    // stopCapture(): cancels the reader task.
}
```

Paced real-time mode is the default for latency measurement; accelerated mode is used for pure correctness tests.

### 5.3 Integration tests (initial set)

| Test | Pipeline under test | Assertions |
|------|--------------------|-----------|
| `SpeechToTextFixtureTests` | FileAudioSource → EnergyVAD → STT (Apple Speech es/en; WhisperKit uk) | WER ≤ manifest threshold |
| `TranslationFixtureTests` | expected transcript → AppleTranslationService (host app's TranslationBridge) | non-empty, `NLLanguageRecognizer` detects target language |
| `OutgoingPipelineFixtureTests` | FileAudioSource → full outgoing pipeline via `AudioCoordinator` with a capturing TTS output | non-empty synthesized audio; per-stage latency recorded |
| `TTSFixtureTests` | AVSpeech (+ Kokoro if model present) | first audio buffer arrives; duration > 0 |

Tests run inside the app host (`TEST_HOST` is already the app), so the hidden `TranslationBridge` view is available. If a language pack or model is missing, the test fails via `Issue.record("Missing prerequisite: … — run just setup")` (REQ-W-23).

### 5.4 Latency report

`LatencyReport` is an actor collecting `(fixture, stage, ms)` and writing `build/reports/latency.json` at the end of the integration run:

```json
{ "commit": "abc1234", "date": "2026-10-03T12:00:00Z", "machine": "Mac mini M-series",
  "fixtures": [ { "id": "es-greeting", "vad_ms": 760, "stt_ms": 410, "translate_ms": 18,
                  "tts_first_audio_ms": 220, "total_ms": 1408 } ] }
```

Stage timestamps are taken from existing pipeline events where available (segment `capturedAt`, transcription result, translation return, first TTS buffer). Where the pipeline does not expose a hook, a minimal internal observer protocol is added to `AudioCoordinator` (no behavior change).

## 6. Audio fixtures

`manifest.json`:

```json
[ { "id": "es-greeting", "lang": "es-ES", "voice": "Mónica", "text": "Hola, ¿qué tal? Hoy vamos a revisar el proyecto.", "max_wer": 0.25 },
  { "id": "en-meeting",  "lang": "en-US", "voice": "Samantha", "text": "Can you hear me clearly? Let's start the meeting.", "max_wer": 0.20 },
  { "id": "uk-greeting", "lang": "uk-UA", "voice": "Lesya",   "text": "Добрий день, як справи?", "max_wer": 0.35 } ]
```

`fixtures.sh`: for each entry, `say -v <voice> -o tmp.aiff "<text>"` → `afconvert -f WAVE -d LEI16@16000 -c 1` → `<id>.wav`, plus `<id>.txt`. Fails naming the voice if `say -v '?'` lacks it. Initial set: 2 ES, 2 EN, 2 UK (6 files, ~300 KB total).

Synthetic voices are a deliberate starting point: deterministic and license-free. Real recordings (noise, accents) are a later addition through the same manifest.

## 7. opengrep rules

| Rule ID | Initial severity | Pattern idea | Fixed in |
|---------|------------------|--------------|----------|
| `asyncstream-force-unwrap` | WARNING | `$C!` where `$C` was assigned inside `AsyncStream { $C = $0 }` | F8.5.1 |
| `asyncstream-unbounded` | WARNING | `AsyncStream { ... }` / `AsyncStream<...> { ... }` without `bufferingPolicy:` under `Core/Audio`, `Core/TTS` | F8.5.1 |
| `playernode-isplaying-poll` | WARNING | `while $P.isPlaying { ... Task.sleep(...) ... }` | F8.5.1 |
| `buffer-nocopy-escape` | WARNING | `AVAudioPCMBuffer(pcmFormat: ..., bufferListNoCopy: ...)` (always flagged; suppress with `// nosemgrep` + reason when copying is proven) | F8.5.1 |
| `no-print` | ERROR | `print(...)` in `TranslateCall/` | already clean |
| `nonisolated-unsafe-justified` | WARNING | `nonisolated(unsafe)` not preceded by a `// SAFETY:` comment | F8.5.x (progressive) |
| `hardcoded-secret` | ERROR | generic token/key regexes | already clean |

Each rule file carries `message`, `metadata.audit_ref` (link to the audit finding) and a test file (`.opengrep/tests/<rule>.swift`) with positive and negative examples, run via `opengrep test` inside `just scan`. If Swift pattern support proves unreliable for a rule, it is implemented as a regex rule (`pattern-regex`) with the same ID (OQ-2).

## 8. GitHub side

### 8.1 CI (`.github/workflows/ci.yml`)

```yaml
name: check
on: { pull_request: { branches: [main] } }
jobs:
  check:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - run: tools/scripts/setup.sh --ci          # opengrep only, pinned
      - run: tools/scripts/scan.sh                # same script as `just scan`
      - run: docker run --rm -v "$PWD:/src" -w /src ghcr.io/realm/swiftlint:$SWIFTLINT_VERSION swiftlint lint --strict
```

No push-to-main trigger: main only changes through PRs.

### 8.2 Branch protection

Applied once by `tools/scripts/protect-main.sh` (run manually after user confirmation, REQ-W-61) using `gh api -X PUT repos/SantipBarber/TranslateCall/branches/main/protection` with:
- `required_status_checks.contexts = ["check", "local/just-pr"]`, `strict = true` (branch must be up to date)
- `required_pull_request_reviews = null` (solo developer; no review count required)
- `enforce_admins = true`, `allow_force_pushes = false`, `allow_deletions = false`

Repo settings: squash merge only, auto-delete head branches.

## 9. Bootstrapping order (chicken-and-egg)

The build is broken today (Metal Toolchain) and SwiftLint may report existing violations, so the gate cannot be enabled before it can pass:

1. Branch `chore/dev-workflow`: tooling, justfile, shared scheme, test plans, tags; make `just build` and `just test` pass (fix only what blocks them).
2. Fix or justify existing SwiftLint violations; add opengrep rules (WARNING where defects exist).
3. Fixtures + integration tier + latency report. Integration tests that reveal audited bugs are allowed to be marked `.disabled("F8.5.1: <bug>")` **only** with a reference to the fixing task — never silently.
4. Replace CI; open the PR with `just pr` (status published).
5. After merge, with user confirmation, apply branch protection.

## 10. Risks

| Risk | Mitigation |
|------|-----------|
| Translation framework in tests prompts for language download / needs UI | Prerequisite check fails explicitly; `just setup` lists required packs |
| Real-time paced fixtures make the integration tier slow | Keep fixtures ≤ 8 s; accelerated mode for correctness-only tests; target < 5 min |
| `local/just-pr` can be forged by anyone with repo write access | Acceptable: solo developer; the status certifies the developer's own run |
| `say` voices change between macOS versions → WER drift | Fixtures are committed; regeneration is explicit (`just fixtures`) and reviewed in a PR |
| opengrep Swift parser gaps | Regex fallback with same rule ID (OQ-2) |
