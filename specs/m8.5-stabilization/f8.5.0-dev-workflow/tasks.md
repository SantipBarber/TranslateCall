# F8.5.0 Dev Workflow & Verification Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single `just` entry point that builds, lints, scans and runs unit + integration (audio-fixture) tests on the Mac mini, certifies the result on the commit SHA, with a minimal Linux `check` job on GitHub.

**Architecture:** Bash scripts under `tools/scripts/` driven by a root `justfile`; tool versions pinned in `tools/versions.env`. Swift Testing tags + two Xcode test plans split tiers. Integration tests inject committed WAV fixtures through the production `AudioCapture` protocol and record per-stage latency to `build/reports/latency.json`.

**Tech Stack:** just 1.58, Xcode 27 / Swift 6, Swift Testing, opengrep 1.30.0, SwiftLint 0.65.1, xcbeautify 3.2.1, gh 2.100, macOS `say` + `afconvert`.

**Spec:** `specs/m8.5-stabilization/f8.5.0-dev-workflow/requirements.md`, `specs/m8.5-stabilization/f8.5.0-dev-workflow/design.md`

## Global Constraints

- Work on branch `chore/dev-workflow` created from up-to-date `main` (after `spec/dev-workflow` is merged). Never commit to `main`.
- Commits: Conventional Commits; end every message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Every script: `#!/usr/bin/env bash` + `set -euo pipefail`; never `|| true` around a check; a missing tool fails with an actionable message (REQ-W-12).
- DerivedData: `build/DerivedData` (REQ-W-13). Logs: `build/logs/`. Reports: `build/reports/`.
- Tool versions only in `tools/versions.env` (NFR-W-03).
- Test target must match app: `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, same `DEVELOPMENT_TEAM` as the app (`8A6PXCGB7U`).
- New Swift files are picked up automatically (project uses `PBXFileSystemSynchronizedRootGroup`, objectVersion 77) — do not hand-edit pbxproj to add files.
- Integration tests are never silently skipped: missing prerequisite → `Issue.record` failure naming it (REQ-W-23). Disabling a test requires `.disabled("F8.5.1: <reason>")`.
- No changes to production behavior in this feature except what is strictly needed for build/tests to pass.

## Review Focus

- **Running `just pr` on `main` or with a dirty tree** → must refuse before doing any work (pinned in Task 8 tests).
- **A failing step inside a pipe** (`xcodebuild … | xcbeautify`) → recipe must still fail; `pipefail` in justfile shell (pinned in Task 1 Step 6).
- **Integration prerequisite missing (Speech permission, Translation language pack, Whisper model)** → explicit failure naming it, not a pass (pinned in Task 7 helper `requirePrerequisite`).
- **WAV fixture with a different sample rate / stereo** → `FileAudioSource` converts to 16 kHz mono or throws; never yields wrong-format buffers (pinned in Task 5 tests).
- **opengrep binary integrity / wrong platform** → checksum mismatch aborts setup (pinned in Task 1 Step 4).

---

### Task 1: Tool pinning, setup script, build recipe green

**Files:**
- Create: `tools/versions.env`, `tools/scripts/setup.sh`, `justfile`
- Modify: `.gitignore` (append `tools/bin/`)

**Interfaces:**
- Produces: `tools/bin/opengrep` binary; `just setup`, `just build`; env vars `OPENGREP_VERSION`, `OPENGREP_SHA256_OSX_ARM64`, `OPENGREP_SHA256_LINUX_X86`, `SWIFTLINT_VERSION`, `XCBEAUTIFY_VERSION`, `XCODE_VERSION`.

- [ ] **Step 1: Create branch**

```bash
git switch main && git pull --ff-only && git switch -c chore/dev-workflow
```

- [ ] **Step 2: Compute opengrep checksums**

```bash
for a in opengrep_osx_arm64 opengrep_manylinux_x86; do
  curl -fsSL -o "/tmp/$a" "https://github.com/opengrep/opengrep/releases/download/v1.30.0/$a"
  shasum -a 256 "/tmp/$a"
done
```
Record both hashes for Step 3.

- [ ] **Step 3: Write `tools/versions.env`**

```bash
# Single source of truth for tool versions (NFR-W-03). Sourced by justfile, scripts and CI.
OPENGREP_VERSION=1.30.0
OPENGREP_SHA256_OSX_ARM64=<hash from Step 2>
OPENGREP_SHA256_LINUX_X86=<hash from Step 2>
SWIFTLINT_VERSION=0.65.1
XCBEAUTIFY_VERSION=3.2.1
XCODE_VERSION=27.0
```
(The two `<hash>` values are literal outputs of Step 2 — paste them; nothing else is left open.)

- [ ] **Step 4: Write `tools/scripts/setup.sh`**

```bash
#!/usr/bin/env bash
# Install / verify development tooling. Usage: setup.sh [--ci]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source tools/versions.env

CI_MODE=false; [[ "${1:-}" == "--ci" ]] && CI_MODE=true
fail() { echo "✗ $*" >&2; exit 1; }
ok()   { echo "✓ $*"; }
info() { echo "• $*"; }

install_opengrep() {
  local asset sha
  case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) asset=opengrep_osx_arm64;      sha=$OPENGREP_SHA256_OSX_ARM64 ;;
    Linux-x86_64) asset=opengrep_manylinux_x86;  sha=$OPENGREP_SHA256_LINUX_X86 ;;
    *) fail "Unsupported platform $(uname -s)-$(uname -m) for opengrep" ;;
  esac
  sha=${OPENGREP_SHA_OVERRIDE:-$sha}   # test hook for the checksum guard
  mkdir -p tools/bin
  if [[ -x tools/bin/opengrep ]] && tools/bin/opengrep --version 2>/dev/null | grep -q "$OPENGREP_VERSION"; then
    ok "opengrep $OPENGREP_VERSION"; return
  fi
  curl -fsSL -o tools/bin/opengrep.tmp \
    "https://github.com/opengrep/opengrep/releases/download/v${OPENGREP_VERSION}/${asset}"
  echo "${sha}  tools/bin/opengrep.tmp" | shasum -a 256 -c - >/dev/null \
    || { rm -f tools/bin/opengrep.tmp; fail "opengrep checksum mismatch — refusing to install"; }
  mv tools/bin/opengrep.tmp tools/bin/opengrep && chmod +x tools/bin/opengrep
  ok "opengrep $OPENGREP_VERSION installed"
}

install_opengrep
$CI_MODE && exit 0

command -v brew >/dev/null || fail "Homebrew required: https://brew.sh"
for tool in swiftlint xcbeautify; do
  command -v "$tool" >/dev/null || brew install "$tool"
done
[[ "$(swiftlint version)" == "$SWIFTLINT_VERSION" ]] \
  || fail "swiftlint $(swiftlint version) ≠ pinned $SWIFTLINT_VERSION (brew upgrade swiftlint or update tools/versions.env in a PR)"
ok "swiftlint $SWIFTLINT_VERSION"
xcbeautify --version | grep -q "$XCBEAUTIFY_VERSION" \
  || fail "xcbeautify ≠ pinned $XCBEAUTIFY_VERSION"
ok "xcbeautify $XCBEAUTIFY_VERSION"

xcodebuild -version | head -1 | grep -q "Xcode $XCODE_VERSION" \
  || fail "Xcode $XCODE_VERSION required (found: $(xcodebuild -version | head -1))"
ok "Xcode $XCODE_VERSION"
if ! xcrun -f metal >/dev/null 2>&1; then
  info "Installing Metal Toolchain (needed by mlx-swift)…"
  xcodebuild -downloadComponent MetalToolchain
fi
ok "Metal Toolchain"

# Informational only (needed by `just fixtures` / manual call tests)
if system_profiler SPAudioDataType 2>/dev/null | grep -q "BlackHole 2ch"; then ok "BlackHole 2ch"; else info "BlackHole 2ch not found (brew install blackhole-2ch) — only needed for live calls"; fi
for v in "Mónica" "Samantha" "Lesya"; do
  if say -v '?' | grep -q "^$v "; then ok "voice $v"; else info "voice $v missing — install it from System Settings (search \"Voices\"); needed by just fixtures"; fi
done
```

- [ ] **Step 5: Write `justfile` (first recipes)**

```just
set shell := ["bash", "-euo", "pipefail", "-c"]

derived := "build/DerivedData"
xcb := "xcodebuild -project TranslateCall.xcodeproj -scheme TranslateCall -destination platform=macOS -derivedDataPath " + derived

# List recipes
default:
    @just --list

# Install / verify tooling (opengrep, swiftlint, xcbeautify, Metal Toolchain)
setup:
    tools/scripts/setup.sh

# Debug build of the app
build:
    mkdir -p build/logs
    {{xcb}} build 2>&1 | tee build/logs/build.log | xcbeautify
```

Append `tools/bin/` to `.gitignore` (`build/` is already ignored).

- [ ] **Step 6: Verify pipefail actually fails a recipe**

Run: `just --evaluate xcb && bash -euo pipefail -c 'false | cat'; echo "exit=$?"`
Expected: `exit=1` (confirms the shell setting the justfile uses propagates pipe failures).

- [ ] **Step 7: Run setup and build**

Run: `chmod +x tools/scripts/setup.sh && just setup && just build`
Expected: all `✓` lines (voices may be `•`), then `** BUILD SUCCEEDED **`. If the build fails for reasons other than the Metal Toolchain, fix the minimal cause and note it in the commit body.

- [ ] **Step 8: Verify checksum guard**

Run: `rm tools/bin/opengrep && OPENGREP_SHA_OVERRIDE=0000 tools/scripts/setup.sh --ci; echo "exit=$?"; just setup`
Expected: first command prints `✗ opengrep checksum mismatch` and `exit=1`; then `just setup` reinstalls cleanly.

- [ ] **Step 9: Commit**

```bash
git add tools/versions.env tools/scripts/setup.sh justfile .gitignore
git commit -m "chore(tooling): add just entry point, pinned tool versions and setup script"
```

---

### Task 2: Shared scheme, unified test target, tiers, `just test` green

**Files:**
- Create: `TranslateCall.xcodeproj/xcshareddata/xcschemes/TranslateCall.xcscheme`, `TranslateCallTests/TestPlans/Unit.xctestplan`, `TranslateCallTests/TestPlans/Integration.xctestplan`, `TranslateCallTests/Support/Tags.swift`, `TranslateCallTests/Support/TestTier.swift`, `TranslateCallTests/Integration/IntegrationTests.swift`
- Modify: `TranslateCall.xcodeproj/project.pbxproj` (test target build settings only: lines ~250-300), `justfile`

**Interfaces:**
- Produces: `Tag.integration`; `TestTier.current: TestTier` (`.unit` / `.integration`, from env `TC_TEST_TIER`); top-level suite `IntegrationTests` (all integration suites are nested in `extension IntegrationTests`); the parent suite is `.serialized` and gated by `.enabled(if: TestTier.current == .integration)` (nested suites inherit both); `just test`, `just test-integration`.

- [ ] **Step 1: Unify test target settings**

In Xcode: TranslateCallTests target → Build Settings: `SWIFT_VERSION = 6.0`, `MACOSX_DEPLOYMENT_TARGET = 15.0`, `DEVELOPMENT_TEAM = 8A6PXCGB7U` (both Debug and Release). Verify:

Run: `grep -nE "SWIFT_VERSION|MACOSX_DEPLOYMENT_TARGET|DEVELOPMENT_TEAM" TranslateCall.xcodeproj/project.pbxproj`
Expected: every occurrence is `6.0`, `15.0`, `8A6PXCGB7U`.

- [ ] **Step 2: Share the scheme**

In Xcode: Product → Scheme → Manage Schemes → tick **Shared** for `TranslateCall`. Confirm file exists:
Run: `ls TranslateCall.xcodeproj/xcshareddata/xcschemes/TranslateCall.xcscheme`

- [ ] **Step 3: Add tier support code**

`TranslateCallTests/Support/Tags.swift`:
```swift
import Testing

extension Tag {
    /// Tests that use real Apple frameworks, real models and audio fixtures (F8.5.0 REQ-W-20).
    @Tag static var integration: Self
}
```

`TranslateCallTests/Support/TestTier.swift`:
```swift
import Foundation

/// Which tier the current test plan runs. Set by the test plan's `TC_TEST_TIER` env var.
enum TestTier: String {
    case unit, integration

    static var current: TestTier {
        TestTier(rawValue: ProcessInfo.processInfo.environment["TC_TEST_TIER"] ?? "") ?? .unit
    }
}
```

`TranslateCallTests/Integration/IntegrationTests.swift`:
```swift
import Testing

/// Root of the integration tier. Every integration suite is declared as
/// `extension IntegrationTests { @Suite(...) struct X { ... } }` so the
/// Integration test plan can select it with a single identifier.
@Suite("Integration", .tags(.integration), .serialized,
       .enabled(if: TestTier.current == .integration, "Integration tier only — run `just test-integration`"))
struct IntegrationTests {}
```

- [ ] **Step 4: Create test plans**

`TranslateCallTests/TestPlans/Unit.xctestplan`:
```json
{
  "configurations" : [ { "id" : "8F5A0C1E-0000-4000-8000-000000000001", "name" : "Default", "options" : {} } ],
  "defaultOptions" : {
    "environmentVariableEntries" : [ { "key" : "TC_TEST_TIER", "value" : "unit" } ]
  },
  "testTargets" : [
    { "skippedTests" : [ "IntegrationTests" ],
      "target" : { "containerPath" : "container:TranslateCall.xcodeproj", "identifier" : "TESTS_TARGET_ID", "name" : "TranslateCallTests" } }
  ],
  "version" : 1
}
```

`TranslateCallTests/TestPlans/Integration.xctestplan`:
```json
{
  "configurations" : [ { "id" : "8F5A0C1E-0000-4000-8000-000000000002", "name" : "Default", "options" : {} } ],
  "defaultOptions" : {
    "environmentVariableEntries" : [ { "key" : "TC_TEST_TIER", "value" : "integration" } ],
    "executionTimeAllowance" : 300
  },
  "testTargets" : [
    { "selectedTests" : [ "IntegrationTests" ],
      "target" : { "containerPath" : "container:TranslateCall.xcodeproj", "identifier" : "TESTS_TARGET_ID", "name" : "TranslateCallTests" } }
  ],
  "version" : 1
}
```
Replace `TESTS_TARGET_ID` with the test target's object ID:
Run: `grep -n "/\* TranslateCallTests \*/ = {" TranslateCall.xcodeproj/project.pbxproj | head -1` — the 24-hex ID at the start of the `PBXNativeTarget` line.

Then in Xcode: Edit Scheme → Test → "Convert to use Test Plans" → add both existing plans, mark **Unit** as default. Commit the updated `.xcscheme`.

- [ ] **Step 5: Add test recipes to `justfile`**

```just
# Unit tier (fast, no network/mic/models)
test:
    mkdir -p build/logs
    {{xcb}} test -testPlan Unit -resultBundlePath build/logs/unit.xcresult 2>&1 | tee build/logs/test-unit.log | xcbeautify

# Integration tier (real frameworks + audio fixtures)
test-integration:
    mkdir -p build/logs build/reports
    {{xcb}} test -testPlan Integration -resultBundlePath build/logs/integration.xcresult 2>&1 | tee build/logs/test-integration.log | xcbeautify
```
Each recipe first deletes its previous bundle: prepend `rm -rf build/logs/unit.xcresult` / `rm -rf build/logs/integration.xcresult` (xcodebuild refuses to overwrite).

- [ ] **Step 6: Run unit tier**

Run: `just test`
Expected: `** TEST SUCCEEDED **` with ~378 tests. For each failing pre-existing test: if the failure is caused by tooling/config (e.g. Swift 6 strictness in the test target), fix it; if it reveals an audited production bug, mark it `.disabled("F8.5.1: <bug> — see audit 2026-10-03")` and list it in the commit body. Tests that need network/models/mic violate REQ-W-21: move them into `extension IntegrationTests`.

- [ ] **Step 7: Run integration tier (empty)**

Run: `just test-integration`
Expected: `** TEST SUCCEEDED **`, 0 tests executed in suites other than `IntegrationTests`.

- [ ] **Step 8: Commit**

```bash
git add TranslateCall.xcodeproj TranslateCallTests/TestPlans TranslateCallTests/Support TranslateCallTests/Integration justfile TranslateCallTests
git commit -m "test: add shared scheme, unit/integration test plans and tier gating"
```

---

### Task 3: SwiftLint gate

**Files:**
- Modify: `.swiftlint.yml` (only if a rule needs justified tuning), Swift files with violations, `justfile`

**Interfaces:**
- Produces: `just lint` (exit 0 = clean in strict mode).

- [ ] **Step 1: Add recipe**

```just
# SwiftLint, strict (warnings fail)
lint:
    swiftlint lint --strict --quiet
```

- [ ] **Step 2: Measure**

Run: `swiftlint lint --quiet | tee build/logs/swiftlint-baseline.txt | wc -l`
Record the count in the commit body.

- [ ] **Step 3: Fix violations**

Fix mechanically fixable ones first: `swiftlint lint --fix`, then review the diff (`git diff --stat`) — revert any change that alters behavior. For remaining violations: fix by hand; where a fix would change production behavior (e.g. a `force_unwrapping` on `cont!` targeted by F8.5.1), add an inline `// swiftlint:disable:next force_unwrapping — F8.5.1 replaces with AsyncStream.makeStream()`.

- [ ] **Step 4: Verify**

Run: `just lint && just build && just test`
Expected: lint exits 0; build and unit tier still green.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "style: make SwiftLint strict-clean and add lint recipe"
```

---

### Task 4: opengrep rules, rule tests, `just scan` / `just check`

**Files:**
- Create: `.opengrep/rules/swift-concurrency.yml`, `.opengrep/rules/swift-audio.yml`, `.opengrep/rules/hygiene.yml`, `.opengrep/tests/` (one `.swift` per rule file, same basename), `.opengrep/README.md`, `tools/scripts/scan.sh`
- Modify: `justfile`

**Interfaces:**
- Consumes: `tools/bin/opengrep` (Task 1).
- Produces: `tools/scripts/scan.sh` (used by `just scan` and CI, Task 9); `just check`.

- [ ] **Step 1: Write failing rule tests first**

`.opengrep/tests/swift-concurrency.swift`:
```swift
func streams() {
    var cont: AsyncStream<Int>.Continuation?
    // ruleid: asyncstream-unbounded
    let a = AsyncStream<Int> { cont = $0 }
    // ok: asyncstream-unbounded
    let b = AsyncStream<Int>(bufferingPolicy: .bufferingNewest(8)) { cont = $0 }
    // ruleid: asyncstream-force-unwrap
    let c = cont!
    // ok: asyncstream-force-unwrap
    let (s, k) = AsyncStream.makeStream(of: Int.self)
}

final class Box {
    // ruleid: nonisolated-unsafe-justified
    nonisolated(unsafe) var x = 0
    // SAFETY: only touched on the audio render thread
    // ok: nonisolated-unsafe-justified
    nonisolated(unsafe) var y = 0
}
```

`.opengrep/tests/swift-audio.swift`:
```swift
func wait(player: AVAudioPlayerNode) async {
    // ruleid: playernode-isplaying-poll
    while player.isPlaying {
        try? await Task.sleep(for: .milliseconds(50))
    }
}

func extract(fmt: AVAudioFormat, list: UnsafePointer<AudioBufferList>) {
    // ruleid: buffer-nocopy-escape
    let b = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: list)
}
```

`.opengrep/tests/hygiene.swift`:
```swift
func log() {
    // ruleid: no-print
    print("hello")
    // ok: no-print
    logger.info("hello")
    // ruleid: hardcoded-secret
    let apiKey = "sk_live_0123456789abcdefABCDEF"
}
```

Run: `tools/bin/opengrep test .opengrep/`
Expected: FAIL (rules not defined).

- [ ] **Step 2: Write rules**

`.opengrep/rules/swift-concurrency.yml`:
```yaml
rules:
  - id: asyncstream-unbounded
    languages: [swift]
    severity: WARNING
    message: AsyncStream without bufferingPolicy buffers without limit (audit 2026-10-03: 48 kHz stream leak). Pass bufferingPolicy explicitly.
    metadata: { audit_ref: "F8.5.1 / AudioManager.swift:148" }
    pattern-regex: 'AsyncStream(<[^>]*>)?\s*\{'
    paths: { include: ["TranslateCall/Core/Audio/", "TranslateCall/Core/TTS/", ".opengrep/tests/"] }
  - id: asyncstream-force-unwrap
    languages: [swift]
    severity: WARNING
    message: Force-unwrapping an AsyncStream continuation. Use AsyncStream.makeStream(of:bufferingPolicy:).
    metadata: { audit_ref: "F8.5.1 / 7 occurrences" }
    pattern-regex: '\bcont!'
  - id: nonisolated-unsafe-justified
    languages: [swift]
    severity: WARNING
    message: nonisolated(unsafe) needs a `// SAFETY:` comment on the preceding line explaining why it is race-free.
    pattern-regex: '(?m)^(?![^\n]*// SAFETY:)[^\n]*\n[^\n]*\bnonisolated\(unsafe\)'
```

`.opengrep/rules/swift-audio.yml`:
```yaml
rules:
  - id: playernode-isplaying-poll
    languages: [swift]
    severity: WARNING
    message: AVAudioPlayerNode.isPlaying stays true until stop(); polling it never ends. Use scheduleBuffer(completionCallbackType: .dataPlayedBack).
    metadata: { audit_ref: "F8.5.1 / EdgeTTSService.swift:167" }
    pattern-regex: 'while\s+\w+(\.\w+)*\.isPlaying\s*\{'
  - id: buffer-nocopy-escape
    languages: [swift]
    severity: WARNING
    message: bufferListNoCopy aliases memory owned by the caller; copy before the buffer escapes the scope (audit 2026-10-03).
    metadata: { audit_ref: "F8.5.1 / SystemAudioCaptureService.swift:236" }
    pattern-regex: 'bufferListNoCopy\s*:'
```

`.opengrep/rules/hygiene.yml`:
```yaml
rules:
  - id: no-print
    languages: [swift]
    severity: ERROR
    message: Use os.Logger instead of print().
    pattern-regex: '(?<![\w.])print\('
  - id: hardcoded-secret
    languages: [swift]
    severity: ERROR
    message: Possible hard-coded secret.
    pattern-regex: '(?i)(api[_-]?key|secret|token|password)\s*[:=]\s*"[A-Za-z0-9_\-]{16,}"'
```

Note on `nonisolated-unsafe-justified`: the first-line edge case (declaration on line 1 of a file) is not matched; acceptable (OQ-2). If opengrep's Swift support rejects `languages: [swift]` with `pattern-regex`, use `languages: [regex]` with the same IDs.

- [ ] **Step 3: Run rule tests**

Run: `tools/bin/opengrep test .opengrep/`
Expected: all rules PASS.

- [ ] **Step 4: Write `tools/scripts/scan.sh`**

```bash
#!/usr/bin/env bash
# opengrep: rule self-tests → WARNING report → ERROR gate (REQ-W-51). Used by `just scan` and CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
OG=tools/bin/opengrep
[[ -x $OG ]] || { echo "✗ opengrep missing — run: just setup" >&2; exit 1; }

$OG test .opengrep/
echo "── warnings (tracked debt, not blocking) ──"
$OG scan --quiet --config .opengrep/rules --severity WARNING --exclude .opengrep TranslateCall
echo "── errors (blocking) ──"
$OG scan --quiet --config .opengrep/rules --severity ERROR --error --exclude .opengrep TranslateCall
```

Add to `justfile`:
```just
# opengrep static analysis (ERROR fails, WARNING reported)
scan:
    tools/scripts/scan.sh

# Everything GitHub runs: lint + scan
check: lint scan
```

- [ ] **Step 5: Verify gate behavior**

Run: `just check; echo "exit=$?"`
Expected: warnings listed for the known audit findings (stream leak, `cont!`, isPlaying poll, nocopy, nonisolated(unsafe)); `exit=0`.

Then prove ERROR blocks: `echo 'func f() { print("x") }' > TranslateCall/_ScanProbe.swift && just scan; echo "exit=$?"; rm TranslateCall/_ScanProbe.swift`
Expected: `no-print` finding and `exit` ≠ 0.

- [ ] **Step 6: Write `.opengrep/README.md`**

Table of rule ID → severity → why → audit reference → promotion policy ("promote WARNING→ERROR in the PR that removes the last occurrence; suppress a proven-safe line with `// nosemgrep: <rule-id> — <reason>`").

- [ ] **Step 7: Commit**

```bash
git add .opengrep tools/scripts/scan.sh justfile
git commit -m "chore(scan): add opengrep project rules with self-tests and check recipe"
```

---

### Task 5: Test support — WordErrorRate, FileAudioSource, LatencyReport

**Files:**
- Create: `TranslateCallTests/Support/WordErrorRate.swift`, `TranslateCallTests/Support/FileAudioSource.swift`, `TranslateCallTests/Support/LatencyReport.swift`
- Test: `TranslateCallTests/Support/WordErrorRateTests.swift`, `TranslateCallTests/Support/FileAudioSourceTests.swift`, `TranslateCallTests/Support/LatencyReportTests.swift`

**Interfaces:**
- Consumes: `AudioCapture` protocol (`TranslateCall/Core/Audio/AudioManager.swift:16`: `audioStream16kHz`, `startCapture() async throws`, `stopCapture()`).
- Produces:
  - `enum WordErrorRate { static func compute(reference: String, hypothesis: String) -> Double }`
  - `@MainActor final class FileAudioSource: AudioCapture` — `init(url: URL, realtime: Bool = true, trailingSilence: TimeInterval = 1.5) throws`, `var audioStream16kHz`, `func startCapture() async throws`, `func stopCapture()`; throws `FileAudioSourceError.unreadable(URL)`.
  - `actor LatencyReport` — `init(autoWritePath: URL? = nil, commit: String = "unknown")`, `static let shared` (configured from env `TC_LATENCY_REPORT` / `TC_COMMIT`), `func record(fixture: String, stage: LatencyStage, ms: Double)` (rewrites the file after each record when `autoWritePath` is set), `func write(to url: URL, commit: String) throws`; `enum LatencyStage: String, Codable { case vad, stt, translate, ttsFirstAudio = "tts_first_audio", total }`.

- [ ] **Step 1: Failing WER tests**

```swift
import Testing
@testable import TranslateCall

@Suite("WordErrorRate")
struct WordErrorRateTests {
    @Test func identicalIsZero() {
        #expect(WordErrorRate.compute(reference: "hola qué tal", hypothesis: "hola qué tal") == 0)
    }
    @Test func ignoresCaseAndPunctuation() {
        #expect(WordErrorRate.compute(reference: "Hola, ¿qué tal?", hypothesis: "hola que tal") == 0)
    }
    @Test func oneSubstitutionOfFour() {
        #expect(WordErrorRate.compute(reference: "can you hear me", hypothesis: "can you see me") == 0.25)
    }
    @Test func deletionAndInsertion() {
        // ref 3 words; hyp drops one and adds one → 2 edits / 3
        #expect(abs(WordErrorRate.compute(reference: "добрий день друже", hypothesis: "добрий друже привіт") - 2.0 / 3.0) < 1e-9)
    }
    @Test func emptyHypothesisIsOne() {
        #expect(WordErrorRate.compute(reference: "a b", hypothesis: "") == 1)
    }
}
```
Run: `just test` → Expected: compile FAIL (`WordErrorRate` undefined).

- [ ] **Step 2: Implement WER**

```swift
import Foundation

/// Word error rate = (substitutions + deletions + insertions) / reference word count.
/// Case-, diacritic- and punctuation-insensitive so "qué" == "que".
enum WordErrorRate {
    static func compute(reference: String, hypothesis: String) -> Double {
        let ref = words(reference), hyp = words(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        var prev = Array(0...hyp.count)
        for i in 1...ref.count {
            var cur = [i] + Array(repeating: 0, count: hyp.count)
            for j in stride(from: 1, through: hyp.count, by: 1) {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }

    private static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}
```
Note: diacritic folding maps Ukrainian "й" → "и"; acceptable because it is applied to both sides.

Run: `just test` → Expected: WER tests PASS.

- [ ] **Step 3: Failing FileAudioSource tests**

```swift
import AVFoundation
import Testing
@testable import TranslateCall

@Suite("FileAudioSource") @MainActor
struct FileAudioSourceTests {
    /// Writes a 0.5 s sine WAV at the given format to a temp file.
    private func makeWAV(sampleRate: Double, channels: AVAudioChannelCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sampleRate / 2)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(channels) {
            for i in 0..<Int(frames) { buf.floatChannelData![ch][i] = sin(Float(i) * 0.05) * 0.3 }
        }
        try file.write(from: buf)
        return url
    }

    private func collect(_ src: FileAudioSource) async throws -> [AVAudioPCMBuffer] {
        try await src.startCapture()
        var out: [AVAudioPCMBuffer] = []
        for await b in src.audioStream16kHz { out.append(b) }
        return out
    }

    @Test func yields16kMonoWithTrailingSilence() async throws {
        let src = try FileAudioSource(url: makeWAV(sampleRate: 16_000, channels: 1), realtime: false, trailingSilence: 1.0)
        let bufs = try await collect(src)
        #expect(bufs.allSatisfy { $0.format.sampleRate == 16_000 && $0.format.channelCount == 1 })
        let total = bufs.reduce(0) { $0 + Int($1.frameLength) }
        #expect(abs(total - 24_000) <= 1024) // 0.5 s audio + 1.0 s silence
    }

    @Test func convertsStereo48k() async throws {
        let src = try FileAudioSource(url: makeWAV(sampleRate: 48_000, channels: 2), realtime: false, trailingSilence: 0)
        let bufs = try await collect(src)
        #expect(bufs.allSatisfy { $0.format.sampleRate == 16_000 && $0.format.channelCount == 1 })
        let total = bufs.reduce(0) { $0 + Int($1.frameLength) }
        #expect(abs(total - 8_000) <= 1024)
    }

    @Test func unreadableFileThrows() {
        #expect(throws: FileAudioSourceError.self) {
            try FileAudioSource(url: URL(fileURLWithPath: "/nonexistent.wav"))
        }
    }

    @Test func realtimePacing() async throws {
        let src = try FileAudioSource(url: makeWAV(sampleRate: 16_000, channels: 1), realtime: true, trailingSilence: 0)
        let start = ContinuousClock.now
        _ = try await collect(src)
        #expect(start.duration(to: .now) >= .milliseconds(400)) // ~0.5 s of audio
    }
}
```
Run: `just test` → Expected: compile FAIL.

- [ ] **Step 4: Implement FileAudioSource**

```swift
import AVFoundation

enum FileAudioSourceError: Error { case unreadable(URL) }

/// Feeds a WAV file into the pipeline through the production `AudioCapture` protocol,
/// exactly where the microphone would (F8.5.0 design §5.2).
@MainActor
final class FileAudioSource: AudioCapture {
    let audioStream16kHz: AsyncStream<AVAudioPCMBuffer>
    private let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    private let samples: [Float]
    private let realtime: Bool
    private var task: Task<Void, Never>?

    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    static let chunk = 1024

    init(url: URL, realtime: Bool = true, trailingSilence: TimeInterval = 1.5) throws {
        guard let file = try? AVAudioFile(forReading: url) else { throw FileAudioSourceError.unreadable(url) }
        let decoded = try Self.decode16kMono(file)
        samples = decoded + Array(repeating: 0, count: Int(trailingSilence * 16_000))
        self.realtime = realtime
        (audioStream16kHz, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .unbounded)
    }

    func startCapture() async throws {
        let samples = samples, realtime = realtime, cont = continuation
        task = Task.detached {
            var clock = ContinuousClock.now
            for offset in stride(from: 0, to: samples.count, by: Self.chunk) {
                if Task.isCancelled { break }
                let n = min(Self.chunk, samples.count - offset)
                let buf = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(n))!
                buf.frameLength = AVAudioFrameCount(n)
                samples.withUnsafeBufferPointer { src in
                    buf.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
                }
                cont.yield(buf)
                if realtime {
                    clock = clock.advanced(by: .seconds(Double(n) / 16_000))
                    try? await Task.sleep(until: clock)
                }
            }
            cont.finish()
        }
    }

    func stopCapture() {
        task?.cancel()
        continuation.finish()
    }

    private static func decode16kMono(_ file: AVAudioFile) throws -> [Float] {
        let inFmt = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: inFmt, to: format) else { throw FileAudioSourceError.unreadable(file.url) }
        try file.read(into: inBuf)
        let ratio = 16_000 / inFmt.sampleRate
        let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024)!
        var consumed = false
        var error: NSError?
        converter.convert(to: outBuf, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return inBuf
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
    }
}
```
(Test support code: force unwraps on fixed-format buffer creation are acceptable; `TranslateCallTests` is excluded from SwiftLint.)

Run: `just test` → Expected: FileAudioSource tests PASS.

- [ ] **Step 5: Failing LatencyReport tests**

```swift
import Foundation
import Testing
@testable import TranslateCall

@Suite("LatencyReport")
struct LatencyReportTests {
    @Test func writesFixturesGroupedById() async throws {
        let report = LatencyReport()
        await report.record(fixture: "es-a", stage: .stt, ms: 410)
        await report.record(fixture: "es-a", stage: .total, ms: 1400)
        await report.record(fixture: "en-b", stage: .vad, ms: 700)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        try await report.write(to: url, commit: "abc1234")

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["commit"] as? String == "abc1234")
        let fixtures = try #require(json["fixtures"] as? [[String: Any]])
        let esA = try #require(fixtures.first { $0["id"] as? String == "es-a" })
        #expect(esA["stt_ms"] as? Double == 410)
        #expect(esA["total_ms"] as? Double == 1400)
        #expect(fixtures.count == 2)
    }

    @Test func autoWritesAfterEachRecord() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        let report = LatencyReport(autoWritePath: url, commit: "c0ffee")
        await report.record(fixture: "x", stage: .vad, ms: 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
```
Run: `just test` → Expected: compile FAIL.

- [ ] **Step 6: Implement LatencyReport**

The integration suites run in an unspecified order, so there is no reliable "last test" to write the file; instead the report rewrites the file after every `record` (cheap: a few rows).

```swift
import Foundation

enum LatencyStage: String, Codable, Sendable { case vad, stt, translate, ttsFirstAudio = "tts_first_audio", total }

/// Collects per-stage latency during the integration tier and writes build/reports/latency.json (REQ-W-24).
actor LatencyReport {
    static let shared: LatencyReport = {
        let env = ProcessInfo.processInfo.environment
        return LatencyReport(autoWritePath: env["TC_LATENCY_REPORT"].map { URL(fileURLWithPath: $0) },
                             commit: env["TC_COMMIT"] ?? "unknown")
    }()

    private let autoWritePath: URL?
    private let commit: String
    private var rows: [String: [String: Double]] = [:]
    private var order: [String] = []

    init(autoWritePath: URL? = nil, commit: String = "unknown") {
        self.autoWritePath = autoWritePath
        self.commit = commit
    }

    func record(fixture: String, stage: LatencyStage, ms: Double) {
        if rows[fixture] == nil { order.append(fixture) }
        rows[fixture, default: [:]]["\(stage.rawValue)_ms"] = ms
        if let autoWritePath { try? write(to: autoWritePath, commit: commit) }
    }

    func write(to url: URL, commit: String) throws {
        let fixtures: [[String: Any]] = order.map { id in
            var row: [String: Any] = rows[id] ?? [:]
            row["id"] = id
            return row
        }
        let doc: [String: Any] = [
            "commit": commit,
            "date": ISO8601DateFormatter().string(from: .now),
            "machine": Host.current().localizedName ?? "unknown",
            "fixtures": fixtures,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
```

Run: `just test` → Expected: all Support tests PASS.

- [ ] **Step 7: Commit**

```bash
git add TranslateCallTests/Support
git commit -m "test: add WordErrorRate, FileAudioSource and LatencyReport test support"
```

---

### Task 6: Audio fixtures

**Files:**
- Create: `TranslateCallTests/Fixtures/Audio/manifest.json`, `tools/scripts/fixtures.sh`, generated `TranslateCallTests/Fixtures/Audio/*.wav` + `*.txt`, `TranslateCallTests/Support/Fixtures.swift`
- Modify: `justfile`

**Interfaces:**
- Produces: `struct AudioFixture: Decodable, Sendable { id, lang, voice, text, maxWer }` and `enum Fixtures { static func all() throws -> [AudioFixture]; static func url(for: AudioFixture) -> URL; static func lang(_ prefix: String) throws -> [AudioFixture] }`.

**Prerequisite:** voices Lesya (uk_UA), Mónica (es_ES), Samantha (en_US) — verified installed on the Mac mini 2026-10-03.

- [ ] **Step 1: Manifest**

```json
[
  { "id": "es-greeting", "lang": "es-ES", "voice": "Mónica",   "text": "Hola, ¿qué tal? Hoy vamos a revisar el proyecto.", "maxWer": 0.25 },
  { "id": "es-meeting",  "lang": "es-ES", "voice": "Mónica",   "text": "La reunión empieza a las diez de la mañana.", "maxWer": 0.25 },
  { "id": "en-hear",     "lang": "en-US", "voice": "Samantha", "text": "Can you hear me clearly? Let's start the meeting.", "maxWer": 0.20 },
  { "id": "en-budget",   "lang": "en-US", "voice": "Samantha", "text": "We need to review the budget before Friday.", "maxWer": 0.20 },
  { "id": "uk-greeting", "lang": "uk-UA", "voice": "Lesya",    "text": "Добрий день, як справи?", "maxWer": 0.35 },
  { "id": "uk-thanks",   "lang": "uk-UA", "voice": "Lesya",    "text": "Дякую, мені дуже приємно вас чути.", "maxWer": 0.35 }
]
```

- [ ] **Step 2: `tools/scripts/fixtures.sh`**

```bash
#!/usr/bin/env bash
# Regenerate audio fixtures from manifest.json with macOS `say` (REQ-W-31).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
DIR=TranslateCallTests/Fixtures/Audio
MANIFEST=$DIR/manifest.json
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

count=$(python3 -c "import json;print(len(json.load(open('$MANIFEST'))))")
for i in $(seq 0 $((count - 1))); do
  id=$(python3 -c "import json;print(json.load(open('$MANIFEST'))[$i]['id'])")
  voice=$(python3 -c "import json;print(json.load(open('$MANIFEST'))[$i]['voice'])")
  text=$(python3 -c "import json;print(json.load(open('$MANIFEST'))[$i]['text'])")
  say -v '?' | grep -q "^$voice " || { echo "✗ voice '$voice' not installed (System Settings → Accessibility → Spoken Content → Manage Voices)" >&2; exit 1; }
  say -v "$voice" -o "$TMP/$id.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/$id.aiff" "$DIR/$id.wav"
  printf '%s\n' "$text" > "$DIR/$id.txt"
  echo "✓ $id ($(afinfo "$DIR/$id.wav" | awk '/estimated duration/ {print $3}') s)"
done
```
`justfile`:
```just
# Regenerate audio fixtures (needs voices Mónica, Samantha, Lesya)
fixtures:
    tools/scripts/fixtures.sh
```

- [ ] **Step 3: Generate and check**

Run: `just fixtures && ls -la TranslateCallTests/Fixtures/Audio/`
Expected: 6 `.wav` (each ≤ 8 s, REQ-W-30) + 6 `.txt`; total < 1 MB.

- [ ] **Step 4: Fixture loader**

```swift
import Foundation

struct AudioFixture: Decodable, Sendable {
    let id: String, lang: String, voice: String, text: String, maxWer: Double
    var locale: Locale { Locale(identifier: lang) }
}

/// Locates fixtures in the source tree (not the bundle) so they need no resource wiring.
enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Audio")

    static func all() throws -> [AudioFixture] {
        try JSONDecoder().decode([AudioFixture].self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    }
    static func lang(_ prefix: String) throws -> [AudioFixture] { try all().filter { $0.lang.hasPrefix(prefix) } }
    static func url(for f: AudioFixture) -> URL { directory.appendingPathComponent("\(f.id).wav") }
}
```

Ensure the synchronized test folder does not try to compile/bundle-copy the `.json`/`.txt` in a way that breaks the build: run `just build && just test`. If Xcode copies them as resources, that is harmless.

- [ ] **Step 5: Unit test for manifest integrity**

```swift
import Foundation
import Testing

@Suite("Fixtures manifest")
struct FixturesManifestTests {
    @Test func everyEntryHasWavAndCoversThreeLanguages() throws {
        let all = try Fixtures.all()
        #expect(Set(all.map { String($0.lang.prefix(2)) }) == ["es", "en", "uk"])
        for f in all { #expect(FileManager.default.fileExists(atPath: Fixtures.url(for: f).path), "missing \(f.id).wav — run just fixtures") }
    }
}
```
Run: `just test` → Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add TranslateCallTests/Fixtures tools/scripts/fixtures.sh TranslateCallTests/Support/Fixtures.swift TranslateCallTests/Support/FixturesManifestTests.swift justfile
git commit -m "test: add ES/EN/UK audio fixtures generated from manifest"
```

---

### Task 7: Integration tier — STT, translation, TTS, outgoing pipeline latency

**Files:**
- Create: `TranslateCallTests/Integration/Prerequisites.swift`, `TranslateCallTests/Integration/STTFixtureTests.swift`, `TranslateCallTests/Integration/TranslationFixtureTests.swift`, `TranslateCallTests/Integration/TTSFixtureTests.swift`, `TranslateCallTests/Integration/OutgoingPipelineFixtureTests.swift`
- Modify: `TranslateCallTests/Support/Fixtures.swift`, `TranslateCallTests/TestPlans/Integration.xctestplan`, `justfile`

**Interfaces:**
- Consumes: Task 2 `IntegrationTests`; Task 5 `FileAudioSource`, `WordErrorRate`, `LatencyReport`; Task 6 `Fixtures`, `AudioFixture`. Production: `EnergyVADService(config:)` + `VADService.activate(stream:)`/`speechSegments`; `AppleSpeechService(locale:config:)`, `WhisperSpeechService(locale:config:)` + `activate(stream:)`/`transcriptionStream`; `AppleTranslationService(model:)` + `translate(text:from:to:)`; `TranslationBridge(model:)` view; `AVSpeechService(config:outputDeviceID:)` + `speak(text:locale:)`/`isSpeakingStream`.
- Produces: `func requirePrerequisite(_ ok: Bool, _ what: String) throws`; `@MainActor func hostTranslationBridge() -> (TranslationBridgeModel, NSWindow)`; `struct TranscriptRun { result, vadMs, sttMs }`; `func firstTranscript(of: AudioFixture, using: any SpeechRecognizerService, timeout: Duration) async throws -> TranscriptRun`; `Duration.milliseconds`; `AudioFixture.durationSeconds`.

- [ ] **Step 1: Prerequisites & helpers**

Add to `TranslateCallTests/Support/Fixtures.swift`:
```swift
import AVFoundation

extension AudioFixture {
    /// Speech duration of the WAV (without the trailing silence FileAudioSource appends).
    var durationSeconds: Double {
        guard let f = try? AVAudioFile(forReading: Fixtures.url(for: self)) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15 }
}
```

`TranslateCallTests/Integration/Prerequisites.swift`:
```swift
import AVFoundation
import SwiftUI
import Testing
@testable import TranslateCall

struct MissingPrerequisite: Error, CustomStringConvertible { let description: String }

/// Fails (never skips) when a prerequisite is missing (REQ-W-23).
func requirePrerequisite(_ ok: Bool, _ what: String) throws {
    guard ok else {
        Issue.record("Missing prerequisite: \(what) — run `just setup`; see specs/m8.5-stabilization/f8.5.0-dev-workflow")
        throw MissingPrerequisite(description: what)
    }
}

/// Hosts a TranslationBridge in an offscreen window so `.translationTask` runs inside the test host.
/// Keep the returned window alive for the duration of the test.
@MainActor
func hostTranslationBridge() -> (TranslationBridgeModel, NSWindow) {
    let model = TranslationBridgeModel()
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 10, height: 10),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TranslationBridge(model: model))
    window.orderBack(nil)
    return (model, window)
}

struct TranscriptRun {
    let result: TranscriptionResult
    /// End of speech in the fixture → VAD closed the segment.
    let vadMs: Double
    /// Segment closed → first transcript emitted.
    let sttMs: Double
}

/// fixture → FileAudioSource (real-time) → EnergyVAD → STT; returns the first transcript and stage timings.
@MainActor
func firstTranscript(of fixture: AudioFixture, using stt: any SpeechRecognizerService,
                     timeout: Duration = .seconds(30)) async throws -> TranscriptRun {
    let source = try FileAudioSource(url: Fixtures.url(for: fixture), realtime: true)
    let vad = EnergyVADService()
    try await vad.activate(stream: source.audioStream16kHz)

    // Tee VAD segments so we can timestamp when the segment closed.
    let (segments, segCont) = AsyncStream.makeStream(of: SpeechSegment.self, bufferingPolicy: .unbounded)
    var segmentClosedAt: ContinuousClock.Instant?
    let tee = Task { @MainActor in
        for await segment in vad.speechSegments {
            if segmentClosedAt == nil { segmentClosedAt = .now }
            segCont.yield(segment)
        }
        segCont.finish()
    }
    try await stt.activate(stream: segments)

    let started = ContinuousClock.now
    try await source.startCapture()
    let speechEnd = started + .seconds(fixture.durationSeconds)

    let result = try await withThrowingTaskGroup(of: TranscriptionResult?.self) { group in
        group.addTask { for await r in stt.transcriptionStream { return r }; return nil }
        group.addTask { try await Task.sleep(for: timeout); return nil }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
    let gotAt = ContinuousClock.now
    source.stopCapture()
    await vad.deactivate()
    await stt.deactivate()
    tee.cancel()

    guard let result else {
        Issue.record("No transcript for \(fixture.id) within \(timeout)")
        throw MissingPrerequisite(description: "transcript for \(fixture.id)")
    }
    let closed = segmentClosedAt ?? gotAt
    return TranscriptRun(result: result,
                         vadMs: speechEnd.duration(to: closed).milliseconds,
                         sttMs: closed.duration(to: gotAt).milliseconds)
}
```

- [ ] **Step 2: STT fixture tests (Apple Speech es/en, Whisper uk)**

```swift
import Speech
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("STT with fixtures", .serialized) @MainActor
    struct STTFixtureTests {
        @Test("Apple Speech", arguments: try Fixtures.all().filter { !$0.lang.hasPrefix("uk") })
        func appleSpeech(_ fixture: AudioFixture) async throws {
            try requirePrerequisite(SFSpeechRecognizer.authorizationStatus() == .authorized,
                                    "Speech Recognition permission for TranslateCall")
            try requirePrerequisite(SFSpeechRecognizer(locale: fixture.locale)?.supportsOnDeviceRecognition == true,
                                    "on-device Speech model for \(fixture.lang)")
            var config = STTConfiguration.default; config.minimumConfidence = 0
            let stt = AppleSpeechService(locale: fixture.locale, config: config)
            let run = try await firstTranscript(of: fixture, using: stt)
            let wer = WordErrorRate.compute(reference: fixture.text, hypothesis: run.result.text)
            await LatencyReport.shared.record(fixture: fixture.id, stage: .vad, ms: run.vadMs)
            await LatencyReport.shared.record(fixture: fixture.id, stage: .stt, ms: run.sttMs)
            #expect(wer <= fixture.maxWer, "WER \(wer) > \(fixture.maxWer): got “\(run.result.text)”")
        }

        @Test("WhisperKit (uk)", arguments: try Fixtures.lang("uk"))
        func whisper(_ fixture: AudioFixture) async throws {
            // First run downloads the Whisper `base` model (~150 MB) via WhisperModelManager.
            var config = STTConfiguration.default; config.minimumConfidence = 0
            let stt = WhisperSpeechService(locale: fixture.locale, config: config)
            let run = try await firstTranscript(of: fixture, using: stt, timeout: .seconds(180))
            let wer = WordErrorRate.compute(reference: fixture.text, hypothesis: run.result.text)
            await LatencyReport.shared.record(fixture: fixture.id, stage: .vad, ms: run.vadMs)
            await LatencyReport.shared.record(fixture: fixture.id, stage: .stt, ms: run.sttMs)
            #expect(wer <= fixture.maxWer, "WER \(wer) > \(fixture.maxWer): got “\(run.result.text)”")
        }
    }
}
```
`minimumConfidence: 0` isolates STT accuracy from the confidence filter (the filter's Whisper bug is F8.5.1 scope).

Run: `just test-integration`
Expected: 4 Apple + 2 Whisper cases PASS, or FAIL with an explicit prerequisite / WER message. A WER failure is a real finding: record it in the commit body; if it is caused by an audited bug, mark that case `.disabled("F8.5.1: …")`.

- [ ] **Step 3: Translation fixture tests**

```swift
import NaturalLanguage
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("Translation", .serialized) @MainActor
    struct TranslationFixtureTests {
        static let pairs: [(String, Locale.Language, Locale.Language, NLLanguage)] = [
            ("es-greeting", .init(identifier: "es"), .init(identifier: "en"), .english),
            ("en-hear",     .init(identifier: "en"), .init(identifier: "es"), .spanish),
            ("es-meeting",  .init(identifier: "es"), .init(identifier: "uk"), .ukrainian),
            ("uk-greeting", .init(identifier: "uk"), .init(identifier: "en"), .english),
        ]

        @Test("Apple Translation", arguments: 0..<4)
        func translate(_ i: Int) async throws {
            let (id, src, dst, expected) = Self.pairs[i]
            let fixture = try #require(try Fixtures.all().first { $0.id == id })
            let (model, window) = hostTranslationBridge()
            defer { window.close() }
            let service = AppleTranslationService(model: model)
            try requirePrerequisite(await service.supports(source: src, target: dst),
                                    "Translation language pack \(src.minimalIdentifier)→\(dst.minimalIdentifier)")
            let clock = ContinuousClock.now
            let out = try await service.translate(text: fixture.text, from: src, to: dst)
            await LatencyReport.shared.record(fixture: id, stage: .translate, ms: clock.duration(to: .now).milliseconds)
            #expect(!out.isEmpty)
            #expect(NLLanguageRecognizer.dominantLanguage(for: out) == expected, "“\(out)”")
        }
    }
}
```
Run: `just test-integration` → Expected: 4 PASS or explicit prerequisite failure. If `.translationTask` never fires in the offscreen window (translate hangs), change `window.orderBack(nil)` to `window.orderFrontRegardless()` with `alphaValue = 0` and rerun; document the outcome in `design.md` §10.

- [ ] **Step 4: TTS fixture test**

```swift
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("TTS", .serialized) @MainActor
    struct TTSFixtureTests {
        @Test("AVSpeech produces audio", arguments: ["es-ES", "en-US", "uk-UA"])
        func avSpeech(_ lang: String) async throws {
            let tts = try AVSpeechService(outputDeviceID: nil) // default output: audible during the run
            let monitor = try TTSAudioMonitor()
            monitor.isEnabled = true
            let file = try monitor.startRecording()
            await tts.setAudioMonitor(monitor)

            var events = tts.isSpeakingStream.makeAsyncIterator()
            await tts.speak(text: lang.hasPrefix("uk") ? "Добрий день" : lang.hasPrefix("es") ? "Hola" : "Hello",
                            locale: Locale(identifier: lang))
            var sawStart = false, sawEnd = false
            let deadline = ContinuousClock.now + .seconds(15)
            while ContinuousClock.now < deadline, !sawEnd, let speaking = await events.next() {
                if speaking { sawStart = true } else if sawStart { sawEnd = true }
            }
            _ = monitor.stopRecording()
            await tts.deactivate()
            #expect(sawStart && sawEnd, "isSpeakingStream did not report start→end")
            let frames = (try? AVAudioFile(forReading: file).length) ?? 0
            #expect(frames > 0, "no audio recorded for \(lang)")
        }
    }
}
```
Run: `just test-integration` → Expected: 3 PASS (uk requires an installed Ukrainian voice; a failure names it).

- [ ] **Step 5: Outgoing pipeline latency test**

Composes the same stages `AudioCoordinator+Pipeline.swift` wires (VAD → STT → translate → TTS) without modifying production code, measuring end-to-end:

```swift
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("Outgoing pipeline latency", .serialized) @MainActor
    struct OutgoingPipelineFixtureTests {
        @Test("ES→EN end to end", arguments: try Fixtures.lang("es"))
        func esToEn(_ fixture: AudioFixture) async throws {
            let (model, window) = hostTranslationBridge(); defer { window.close() }
            let translator = AppleTranslationService(model: model)
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")
            try requirePrerequisite(await translator.supports(source: src, target: dst), "Translation pack es→en")
            try await translator.prepare(source: src, target: dst)

            var config = STTConfiguration.default; config.minimumConfidence = 0
            let run = try await firstTranscript(of: fixture, using: AppleSpeechService(locale: fixture.locale, config: config))
            let t0 = ContinuousClock.now
            let text = try await translator.translate(text: run.result.text, from: src, to: dst)
            let translateMs = t0.duration(to: .now).milliseconds

            let tts = try AVSpeechService(outputDeviceID: nil)
            var events = tts.isSpeakingStream.makeAsyncIterator()
            let t1 = ContinuousClock.now
            await tts.speak(text: text, locale: Locale(identifier: "en-US"))
            while let speaking = await events.next(), !speaking {}
            let ttsMs = t1.duration(to: .now).milliseconds
            await tts.deactivate()

            let total = run.vadMs + run.sttMs + translateMs + ttsMs
            for (stage, ms) in [(LatencyStage.vad, run.vadMs), (.stt, run.sttMs), (.translate, translateMs), (.ttsFirstAudio, ttsMs), (.total, total)] {
                await LatencyReport.shared.record(fixture: "\(fixture.id)→en", stage: stage, ms: ms)
            }
            #expect(!text.isEmpty)
            // Latency is recorded, not enforced, in F8.5.0 (spec: Out of Scope).
        }
    }
}
```
Note: `total` is measured from end of speech → first TTS audio, which is the latency a listener perceives.

- [ ] **Step 6: Wire the latency report path**

`LatencyReport.shared` (Task 5) rewrites the file after each record when `TC_LATENCY_REPORT` is set. Pass it from `just`:

```just
# Integration tier (real frameworks + audio fixtures); writes build/reports/latency.json
test-integration:
    rm -rf build/logs/integration.xcresult
    mkdir -p build/logs build/reports
    TC_LATENCY_REPORT="$PWD/build/reports/latency.json" TC_COMMIT="$(git rev-parse --short HEAD)" \
      {{xcb}} test -testPlan Integration -resultBundlePath build/logs/integration.xcresult 2>&1 | tee build/logs/test-integration.log | xcbeautify
```

In `Integration.xctestplan` → `defaultOptions.environmentVariableEntries` add:
```json
{ "key" : "TC_LATENCY_REPORT", "value" : "$(TC_LATENCY_REPORT)" },
{ "key" : "TC_COMMIT", "value" : "$(TC_COMMIT)" }
```
Verification in Step 7: if `latency.json` is not produced, the variables did not expand in the test host; then pass them as build settings instead (`{{xcb}} test … TC_LATENCY_REPORT=… TC_COMMIT=…`) and keep the plan entries.

- [ ] **Step 7: Run the full integration tier**

Run: `just test-integration && cat build/reports/latency.json`
Expected: suite results (pass, or explicit prerequisite/WER failures to triage), and `latency.json` with entries for ES, EN and UK fixtures (acceptance criterion 4). Paste the latency table into the PR description — first real measurement of the project.

- [ ] **Step 8: Commit**

```bash
git add TranslateCallTests justfile
git commit -m "test(integration): STT, translation, TTS and outgoing latency tests over audio fixtures"
```

---

### Task 8: `just pr`, commit status, PR template, CONTRIBUTING

**Files:**
- Create: `tools/scripts/pr.sh`, `tools/scripts/pr-status.sh`, `tools/scripts/test-pr-guards.sh`, `.github/pull_request_template.md`, `CONTRIBUTING.md`
- Modify: `justfile`

**Interfaces:**
- Consumes: `just build|check|test|test-integration`.
- Produces: `pr-status.sh <state> <description>` (state ∈ pending|success|failure|error) publishing context `local/just-pr` on HEAD; `just pr`.

- [ ] **Step 1: Failing guard tests**

`tools/scripts/test-pr-guards.sh`:
```bash
#!/usr/bin/env bash
# Verifies `just pr` refuses on main and on a dirty tree (REQ-W-40). Runs in a throwaway clone.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git clone -q "$ROOT" "$TMP/repo" && cd "$TMP/repo"
export TC_PR_DRY_RUN=1   # pr.sh exits right after the guards

git switch -q main 2>/dev/null || git switch -q -c main
if tools/scripts/pr.sh >/dev/null 2>&1; then echo "✗ ran on main"; exit 1; fi
git switch -q -c test/guard
echo dirty > dirty.txt
if tools/scripts/pr.sh >/dev/null 2>&1; then echo "✗ ran with dirty tree"; exit 1; fi
rm dirty.txt
tools/scripts/pr.sh >/dev/null || { echo "✗ refused a clean feature branch"; exit 1; }
echo "✓ pr guards"
```
Run: `bash tools/scripts/test-pr-guards.sh` → Expected: FAIL (`pr.sh` missing).

- [ ] **Step 2: `tools/scripts/pr-status.sh`**

```bash
#!/usr/bin/env bash
# Publish commit status `local/just-pr` on HEAD (REQ-W-42). Usage: pr-status.sh <state> <description>
set -euo pipefail
state=$1; desc=$2
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
sha=$(git rev-parse HEAD)
gh api -X POST "repos/$repo/statuses/$sha" \
  -f state="$state" -f context="local/just-pr" -f description="${desc:0:140}" >/dev/null
echo "• status local/just-pr=$state on ${sha:0:7}"
```

- [ ] **Step 3: `tools/scripts/pr.sh`**

```bash
#!/usr/bin/env bash
# Full PR gate (REQ-W-40..43): guards → build → check → test → test-integration → status → push → PR.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

branch=$(git branch --show-current)
[[ "$branch" != "main" ]] || { echo "✗ just pr must run on a feature branch, not main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ working tree not clean — commit or stash first" >&2; exit 1; }
[[ "${TC_PR_DRY_RUN:-}" == "1" ]] && { echo "✓ guards passed (dry run)"; exit 0; }

git push -u origin HEAD          # status needs the commit on GitHub
tools/scripts/pr-status.sh pending "just pr running…"
step="setup"
trap 'tools/scripts/pr-status.sh failure "failed at: $step" || true' ERR
start=$SECONDS
for step in build check test test-integration; do
  echo "━━ just $step ━━"
  just "$step"
done
trap - ERR

count() { xcrun xcresulttool get test-results summary --path "$1" --format json | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["passedTests"])'; }
unit=$(count build/logs/unit.xcresult); integ=$(count build/logs/integration.xcresult)
dur=$((SECONDS - start))
tools/scripts/pr-status.sh success "$unit unit, $integ integration · $((dur/60))m$((dur%60))s"

if ! gh pr view --json number >/dev/null 2>&1; then
  gh pr create --base main --fill
else
  echo "• PR already exists: $(gh pr view --json url -q .url)"
fi
```
Note: `|| true` on the trap's status call is the one allowed exception — the step has already failed and the script exits non-zero via `set -e`; a network error publishing the failure must not mask the original exit code.

`justfile`:
```just
# Full PR gate: build → check → test → test-integration → status on SHA → push → PR
pr:
    tools/scripts/pr.sh
```

- [ ] **Step 4: Run guard tests**

Run: `chmod +x tools/scripts/*.sh && bash tools/scripts/test-pr-guards.sh`
Expected: `✓ pr guards`.

- [ ] **Step 5: PR template & CONTRIBUTING**

`.github/pull_request_template.md`:
```markdown
## What & why
<!-- Link the spec/tasks: specs/mX/fX.Y-…/tasks.md (Task N) -->

## Verification
- [ ] `just pr` passed (status `local/just-pr` green on the latest commit)
- [ ] Tests added/updated for the change
- [ ] Integration tests not disabled, or each `.disabled` references its fixing task
- [ ] Docs/specs updated if behavior changed

## Latency (if pipeline touched)
<!-- paste build/reports/latency.json summary -->
```

`CONTRIBUTING.md`: sections **Branches** (prefixes `feat/ fix/ chore/ docs/ spec/ test/ refactor/`, always from fresh `main`), **Commits** (Conventional Commits, examples `fix(audio): recreate system stream on activate`), **Workflow** (`just setup` once → work → `just test` often → `just pr`), **Merging** (squash, branch auto-deleted, `main` protected: `check` + `local/just-pr`), **Specs** (SDD: requirements → design → tasks under `specs/`).

- [ ] **Step 6: Commit**

```bash
git add tools/scripts .github/pull_request_template.md CONTRIBUTING.md justfile
git commit -m "chore(workflow): add just pr gate with commit status, PR template and contributing guide"
```

---

### Task 9: Replace GitHub CI, branch-protection script, open the PR

**Files:**
- Replace: `.github/workflows/ci.yml`
- Create: `tools/scripts/protect-main.sh`
- Modify: `README.md` (add "Development" section pointing to CONTRIBUTING and `just`), `docs/m8-testing-status.md` (mark Edge TTS Starscream migration done 2026-04-11, link F8.5)

**Interfaces:**
- Consumes: `tools/scripts/setup.sh --ci`, `tools/scripts/scan.sh`, `tools/versions.env`.

- [ ] **Step 1: New `ci.yml`**

```yaml
name: check
on:
  pull_request:
    branches: [main]
permissions:
  contents: read
jobs:
  check:
    name: check
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@v4
      - name: Install pinned opengrep
        run: tools/scripts/setup.sh --ci
      - name: opengrep
        run: tools/scripts/scan.sh
      - name: SwiftLint
        run: |
          source tools/versions.env
          docker run --rm -v "$PWD:/src" -w /src "ghcr.io/realm/swiftlint:${SWIFTLINT_VERSION}" swiftlint lint --strict --quiet
```

- [ ] **Step 2: `tools/scripts/protect-main.sh`**

```bash
#!/usr/bin/env bash
# One-off: protect main (REQ-W-61). Run ONLY after explicit user confirmation.
set -euo pipefail
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
read -r -p "Apply branch protection to $repo:main (requires check + local/just-pr)? [y/N] " ans
[[ "$ans" == "y" ]] || { echo "aborted"; exit 1; }
gh api -X PUT "repos/$repo/branches/main/protection" --input - <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["check", "local/just-pr"] },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
gh api -X PATCH "repos/$repo" -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F delete_branch_on_merge=true >/dev/null
echo "✓ main protected; squash-only; branches auto-deleted"
```

- [ ] **Step 3: Docs touch-ups**

README "Development" section:
```markdown
## Development

Requirements: macOS 15+, Xcode 27, Homebrew, [just](https://github.com/casey/just).

    just setup            # once
    just test             # unit tier
    just test-integration # real frameworks + audio fixtures
    just pr               # full gate before opening a PR

See [CONTRIBUTING.md](CONTRIBUTING.md).
```
In `docs/m8-testing-status.md` under Blocker 1 add: "**Update 2026-10-03:** migrated to Starscream 4.0.8 in d685654 (2026-04-11); end-to-end verification tracked in F8.5.1."

- [ ] **Step 4: Full local gate + PR**

Run: `chmod +x tools/scripts/protect-main.sh && git add -A && git commit -m "ci: replace macOS CI with Linux check job; add main protection script" && just pr`
Expected: all steps green; status `local/just-pr = success`; PR opened. Then `gh pr checks --watch` → Expected: `check` and `local/just-pr` both pass.

- [ ] **Step 5: After merge — branch protection (user confirmation required)**

Ask the user explicitly; only on "yes": `tools/scripts/protect-main.sh`. Verify:
Run: `gh api repos/SantipBarber/TranslateCall/branches/main/protection --jq '.required_status_checks.contexts'`
Expected: `["check","local/just-pr"]`.
