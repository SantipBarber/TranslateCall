# F1.1 - Project Setup & Build Configuration
## Requirements

**Feature**: F1.1
**Milestone**: M1 - Foundation
**Status**: COMPLETED — 2026-03-06
**Last Updated**: 2026-03-06

---

## Context

The Xcode project for TranslateCall has been created (macOS App, SwiftUI, Swift, no Storage).
This feature establishes the build system, entitlements, dependency management, code quality tooling, and CI pipeline that all subsequent features will build on.

---

## Functional Requirements

### FR-1: Build Target

- WHEN the project is opened in Xcode THEN it SHALL build successfully for macOS 14.0+ without warnings or errors.
- WHEN the app is built THEN it SHALL target Apple Silicon (arm64) as primary architecture, with x86_64 as secondary.
- WHEN the app is built with Swift 6.0 THEN strict concurrency checking SHALL be enabled (`SWIFT_STRICT_CONCURRENCY = complete`).

### FR-2: App Lifecycle

- WHEN the app launches THEN it SHALL present a single main window via SwiftUI `WindowGroup`.
- WHEN the app is running THEN it SHALL support menu bar mode (`LSUIElement` configurable for future phases).
- WHEN the app launches for the first time THEN it SHALL request microphone permission with a descriptive usage string.

### FR-3: Entitlements

- WHEN the app is code-signed THEN it SHALL include the following entitlements:
  - `com.apple.security.device.audio-input` — for microphone capture
  - `com.apple.security.app-sandbox` — sandbox enabled (required for App Store)
- WHEN the app attempts audio capture without microphone permission THEN it SHALL handle the denial gracefully (no crash).

### FR-4: Dependency Management (SPM)

- WHEN the project is opened THEN Swift Package Manager SHALL be the sole dependency manager (no CocoaPods, no Carthage).
- WHEN FluidAudio is added as a dependency THEN it SHALL resolve without conflicts at the version pinned in the spec.
- IF a dependency fails to resolve THEN the build SHALL fail with a clear error message (not silently).

### FR-5: Code Quality Tooling

- WHEN a Swift file is saved THEN SwiftLint SHALL flag violations in Xcode (via build phase).
- WHEN SwiftLint runs THEN it SHALL use the project's `.swiftlint.yml` configuration (not defaults).
- WHEN SwiftFormat runs THEN it SHALL enforce consistent formatting defined in `.swiftformat`.

### FR-6: CI Pipeline

- WHEN a commit is pushed to `main` or a pull request is opened THEN GitHub Actions SHALL trigger a build.
- WHEN the CI build runs THEN it SHALL: resolve dependencies, build the app, run unit tests.
- WHEN the CI build fails THEN it SHALL report the failure with logs accessible in the GitHub Actions UI.
- IF no unit tests exist THEN the CI SHALL still succeed (empty test suite is valid at this stage).

---

## Non-Functional Requirements

### NFR-1: Build Performance
- WHEN building from clean THEN the build SHALL complete in under 3 minutes on Apple Silicon.
- WHEN building incrementally THEN it SHALL complete in under 30 seconds for a single-file change.

### NFR-2: Reproducibility
- WHEN any developer clones the repo and runs the CI workflow THEN it SHALL produce an identical build (pinned dependency versions).

### NFR-3: Privacy
- WHEN the app is submitted to App Store THEN it SHALL declare no data collection in the privacy manifest (`PrivacyInfo.xcprivacy`).

---

## Out of Scope (F1.1)

- Audio capture implementation → F1.2
- UI components beyond app launch → F1.3
- Translation, VAD, or STT integration → M2/M3
- TestFlight or distribution → M5

---

## Acceptance Criteria

- [ ] `Cmd+B` builds successfully with zero errors and zero warnings on macOS 14.0+
- [ ] Strict concurrency checking is enabled and the project still compiles clean
- [ ] Microphone entitlement is present and permission dialog appears on first launch
- [ ] App sandbox is enabled
- [ ] FluidAudio resolves via SPM
- [ ] SwiftLint runs as a build phase and reports violations inline in Xcode
- [ ] GitHub Actions CI workflow triggers on push to `main` and on PRs
- [ ] CI build passes (build + test)
- [ ] `PrivacyInfo.xcprivacy` is present with no data collection declared
