# F1.1 - Project Setup & Build Configuration
## Implementation Tasks

**Feature**: F1.1
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-06
**Last Updated**: 2026-03-06

---

## Task List

Tasks are ordered by dependency. Each task is independently testable and maps to one or more requirements.

---

### T1 — Reorganize source folder structure

**Maps to**: AD file structure design
**Owner**: Claude
**Effort**: Small

Create the folder structure defined in `design.md`:

```
TranslateCall/
├── App/
│   └── TranslateCallApp.swift    ← move existing file here
├── Features/                     ← empty, ready for F1.3
├── Core/                         ← empty, ready for F1.2
└── Resources/
    └── Assets.xcassets           ← move existing assets here
```

**Acceptance**: Project builds after reorganization. No files missing in Xcode navigator.

---

### T2 — Configure build settings

**Maps to**: FR-1 (build target), AD-1 (strict concurrency)
**Owner**: Claude (via project.pbxproj or Xcode)
**Effort**: Small

Set in Xcode → Build Settings:
- `MACOSX_DEPLOYMENT_TARGET = 14.0`
- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = complete`
- `ONLY_ACTIVE_ARCH = NO` (build both arm64 + x86_64 in Release)

**Acceptance**: `Cmd+B` succeeds with zero warnings. Strict concurrency is shown as "Complete" in Build Settings.

---

### T3 — Configure entitlements

**Maps to**: FR-3 (entitlements), AD-3 (sandbox)
**Owner**: Claude
**Effort**: Small

Create/update `TranslateCall/TranslateCall.entitlements`:
- `com.apple.security.app-sandbox = true`
- `com.apple.security.device.audio-input = true`

Verify the entitlements file is linked in Build Settings → `CODE_SIGN_ENTITLEMENTS`.

**Acceptance**: Build succeeds. Entitlements visible in Xcode → Signing & Capabilities tab.

---

### T4 — Add microphone usage description to Info.plist

**Maps to**: FR-2 (microphone permission), FR-3
**Owner**: Claude
**Effort**: Small

Add to `Info.plist`:
```xml
<key>NSMicrophoneUsageDescription</key>
<string>TranslateCall needs microphone access to capture your voice for translation.</string>
<key>LSMinimumSystemVersion</key>
<string>14.0</string>
```

**Acceptance**: App launches and triggers microphone permission dialog on first run.

---

### T5 — Add PrivacyInfo.xcprivacy

**Maps to**: NFR-3 (privacy manifest)
**Owner**: Claude
**Effort**: Small

Create `TranslateCall/Resources/PrivacyInfo.xcprivacy` with content from `design.md`.
Add the file to the Xcode target (Copy Bundle Resources build phase).

**Acceptance**: File present in app bundle after build (`ls *.app/Contents/Resources/PrivacyInfo.xcprivacy`).

---

### T6 — Add FluidAudio via SPM

**Maps to**: FR-4 (dependency management)
**Owner**: You (Xcode GUI) + Claude (verify)
**Effort**: Small

In Xcode → File → Add Package Dependencies:
- URL: `https://github.com/fluidaudio/fluidaudio`
- Version: Up to Next Major from latest stable

Add `FluidAudio` to the TranslateCall target's frameworks.

**Acceptance**: SPM resolves without errors. `import FluidAudio` compiles in a test file (then remove the import).

---

### T7 — Install and configure SwiftLint

**Maps to**: FR-5 (code quality)
**Owner**: Claude (config file) + You (install via Homebrew)
**Effort**: Small

Steps:
1. `brew install swiftlint` (you run this)
2. Create `.swiftlint.yml` in repo root with config from `design.md` (Claude)
3. Add Run Script build phase in Xcode (Claude provides the script)

**Acceptance**: SwiftLint violations appear as Xcode warnings inline. `swiftlint` runs clean on the starter project.

---

### T8 — Install and configure SwiftFormat

**Maps to**: FR-5 (code quality)
**Owner**: Claude (config file) + You (install via Homebrew)
**Effort**: Small

Steps:
1. `brew install swiftformat` (you run this)
2. Create `.swiftformat` in repo root (Claude)
3. Run `swiftformat .` to verify it formats correctly

**Acceptance**: `swiftformat --lint .` exits with code 0 on the starter project.

---

### T9 — Create GitHub Actions CI workflow

**Maps to**: FR-6 (CI pipeline)
**Owner**: Claude
**Effort**: Medium

Create `.github/workflows/ci.yml` with content from `design.md`.

**Acceptance**: Push to `main` triggers the workflow. Build and test steps pass in GitHub Actions UI.

---

### T10 — Create empty test target

**Maps to**: FR-6 (CI runs tests), future TDD
**Owner**: Claude
**Effort**: Small

Add `TranslateCallTests` target to the Xcode project with a single placeholder test:

```swift
import Testing

struct TranslateCallTests {
    @Test func placeholder() {
        // TODO: replace with real tests as features are implemented
    }
}
```

**Acceptance**: `Cmd+U` runs the test suite and reports 1 test passed.

---

### T11 — Update .gitignore

**Maps to**: Repo hygiene
**Owner**: Claude
**Effort**: Small

Add/update `.gitignore` with standard macOS + Xcode + SPM entries:
- `*.xcuserstate`, `xcuserdata/`
- `.build/`
- `DerivedData/`
- `.DS_Store`

**Acceptance**: `git status` shows no unintended files staged after a clean build.

---

### T12 — Validate full acceptance criteria

**Maps to**: All requirements
**Owner**: Both
**Effort**: Small

Run through the acceptance checklist in `requirements.md`:
- [ ] Clean build, zero warnings
- [ ] Strict concurrency enabled
- [ ] Microphone permission dialog on first launch
- [ ] Sandbox enabled
- [ ] FluidAudio resolves
- [ ] SwiftLint inline warnings
- [ ] CI passes on GitHub
- [ ] PrivacyInfo.xcprivacy in bundle

**Acceptance**: All items checked. F1.1 marked complete. Ready for F1.2.

---

## Dependency Order

```
T1 (structure) ──▶ T2 (build settings) ──▶ T3 (entitlements) ──▶ T4 (Info.plist)
                                                                         │
T5 (privacy) ──────────────────────────────────────────────────────────▼
T6 (FluidAudio) ────────────────────────────────────────────────▶ T12 (validate)
T7 (SwiftLint) ─────────────────────────────────────────────────────────▲
T8 (SwiftFormat) ───────────────────────────────────────────────────────│
T9 (CI) ────────────────────────────────────────────────────────────────│
T10 (tests) ────────────────────────────────────────────────────────────┘
T11 (gitignore) ────────────────────────────────────────────────────────┘
```

T1–T5 are sequential. T6–T11 can be done in parallel once T1–T5 are done.
