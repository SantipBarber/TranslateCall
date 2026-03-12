# F7.1 — Voice Profile Training: Requirements

> **Feature**: F7.1 — Voice Profile Training
> **Milestone**: M7 — Voice Cloning
> **Status**: DRAFT
> **Author**: SDD Process
> **Date**: 2026-03-12

---

## 1. Overview

Implement the voice profile subsystem: the UI-guided recording workflow that captures a user's voice, stores the audio with its paired transcript, and manages the encrypted profile library. Voice profiles are the sole input to F7.2 (CSM-1B inference); F7.1 produces no synthesis output itself.

### 1.1 Scope

- **In scope**: Microphone capture UI (30-second guided recording); transcript pairing; audio pre-processing to 24 kHz mono PCM (CSM-1B required format); AES-256-GCM encrypted storage under `~/Library/Application Support/TranslateCall/VoiceProfiles/`; profile management (create, rename, delete); profile listing and selection UI; quality validation (RMS level, duration, clipping detection).
- **Out of scope**: CSM-1B inference or synthesis (F7.2); voice similarity scoring (F7.2 / F7.3); A/B preview of cloned voice (F7.3); multi-speaker diarisation; iCloud / cross-device sync; voice profile export or sharing.

### 1.2 Key Constraints

| Constraint | Value | Source |
|------------|-------|--------|
| Reference audio format required by CSM-1B | 24 kHz, mono, Float32 PCM | mlx-audio `sesame.py` analysis |
| Reference transcript required | Yes — paired with audio at inference time | CSM-1B `Segment` API |
| Minimum useful reference duration | ≥ 10 seconds (more → better quality) | CSM-1B docs: "sounds best with context" |
| Target capture duration | 30 seconds | M7 roadmap |
| Encryption standard | AES-256-GCM with per-profile random IV | M7 acceptance gate (security) |
| Minimum macOS | 15.0 | Project deployment target |
| Recording permission | `NSMicrophoneUsageDescription` already present | F1.1 entitlements |

### 1.3 Technical Background (from Research)

CSM-1B (Sesame Conversational Speech Model) accepts voice conditioning via "Segment" objects: raw PCM audio at **24 kHz** paired with its **text transcript**. There are no pre-computed speaker embeddings — the model encodes the reference audio through its Mimi audio codec at inference time on every call. Therefore F7.1 must store:
1. The raw audio samples (Float32, 24 kHz, mono) — not compressed
2. The verbatim transcript spoken during recording

A Swift SPM package for CSM-1B does not yet exist (`mlx-audio-swift` covers other models); F7.1 is intentionally designed so the stored format is implementation-agnostic, compatible with both a future Swift CSM port and a Python microservice bridge (F7.2 decision).

---

## 2. Functional Requirements

### 2.1 Recording Capture

**REQ-VCP-01** — WHEN the user initiates "Record Voice Profile" THEN the system SHALL request microphone permission if not already granted before any audio capture begins.

**REQ-VCP-02** — IF microphone permission is denied THEN the system SHALL display an informational alert directing the user to System Settings > Privacy > Microphone and SHALL NOT proceed with recording.

**REQ-VCP-03** — WHEN microphone permission is granted and the user begins recording THEN the system SHALL capture audio from the currently selected input device at 24 kHz, mono, Float32 PCM using `AVAudioEngine`.

**REQ-VCP-04** — WHILE recording is active THEN the system SHALL display:
  - A waveform / level meter updated at ≥ 10 Hz
  - A countdown timer showing elapsed and remaining time (target: 30 seconds)
  - A real-time quality indicator (green / amber / red) based on RMS level

**REQ-VCP-05** — WHEN 30 seconds of audio have been captured THEN the system SHALL automatically stop recording and advance to the review step.

**REQ-VCP-06** — WHILE recording is active THEN the user SHALL be able to manually stop recording at any time; captures shorter than 10 seconds SHALL trigger a warning that quality may be reduced, with options to re-record or proceed.

**REQ-VCP-07** — WHEN recording stops THEN the system SHALL run quality validation (REQ-VCP-12) before presenting the review step.

### 2.2 Transcript Entry

**REQ-VCP-08** — WHEN the review step is presented THEN the system SHALL display a text field for the user to enter the transcript of what they said during recording.

**REQ-VCP-09** — IF the transcript field is empty when the user attempts to save THEN the system SHALL display a validation error "A transcript is required for voice cloning quality" and SHALL NOT save the profile.

**REQ-VCP-10** — WHEN the user enters a transcript THEN the system SHALL display the character count and enforce a maximum of 2 000 characters.

**REQ-VCP-11** — WHEN the review step is presented THEN the system SHALL offer a "Re-record" action that discards the current audio and returns to the recording step.

### 2.3 Quality Validation

**REQ-VCP-12** — WHEN recording stops THEN the system SHALL compute the following metrics from the captured audio:
  - Peak RMS level (dBFS)
  - Maximum sample amplitude (clipping detection)
  - Effective voiced duration (frames above –40 dBFS)

**REQ-VCP-13** — IF peak RMS < –30 dBFS THEN the system SHALL display a warning "Recording level is too low — consider moving closer to the microphone" and offer re-record.

**REQ-VCP-14** — IF clipping is detected (any sample ≥ 0.98 FS in > 0.1% of frames) THEN the system SHALL display a warning "Recording contains clipping — audio quality will be reduced" and offer re-record.

**REQ-VCP-15** — IF voiced duration < 8 seconds THEN the system SHALL display a warning "Insufficient speech detected" and SHALL require the user to re-record (no option to proceed).

**REQ-VCP-16** — Quality metrics SHALL be stored alongside the profile for future display in the profile detail view.

### 2.4 Profile Storage

**REQ-VCP-17** — WHEN the user confirms saving THEN the system SHALL:
  1. Serialise the profile (audio samples + transcript + metadata) to a binary format
  2. Encrypt the serialised bytes with AES-256-GCM using a per-profile random 96-bit IV
  3. Derive the encryption key from the macOS Keychain (one key per app, created on first use)
  4. Write the encrypted blob to `~/Library/Application Support/TranslateCall/VoiceProfiles/<UUID>.vpf`

**REQ-VCP-18** — WHEN saving completes successfully THEN the system SHALL display a confirmation and navigate to the profile list showing the new profile.

**REQ-VCP-19** — IF saving fails (I/O error, Keychain error) THEN the system SHALL display an error alert with the failure reason and SHALL NOT leave a partial file on disk.

**REQ-VCP-20** — WHEN the system initialises THEN the profile store SHALL enumerate `*.vpf` files and load only the metadata headers (UUID, name, creation date, duration, quality metrics) without decrypting the audio payload, to minimise startup memory usage.

**REQ-VCP-21** — WHEN a profile is selected for use in F7.2 THEN the system SHALL decrypt the full payload on demand and hold it in memory only for the duration of the inference call, then release it.

### 2.5 Profile Management

**REQ-VCP-22** — The system SHALL display a "Voice Profiles" list in Settings showing all saved profiles with: name, creation date, duration, and quality indicator badge.

**REQ-VCP-23** — WHEN the user taps "Add Profile" THEN the system SHALL launch the recording capture flow (REQ-VCP-01 through REQ-VCP-18).

**REQ-VCP-24** — WHEN the user selects an existing profile THEN the system SHALL display its detail view showing: name, creation date, duration, transcript excerpt (first 100 chars), and quality metrics.

**REQ-VCP-25** — WHEN the user renames a profile THEN the system SHALL update the metadata header of the `.vpf` file in place without re-encrypting the audio payload (name is stored unencrypted in the header).

**REQ-VCP-26** — WHEN the user deletes a profile THEN the system SHALL:
  1. Display a confirmation alert ("Delete this voice profile? This cannot be undone.")
  2. On confirmation: securely delete the `.vpf` file (overwrite + remove), remove it from the in-memory list, and (if it was the active profile) reset the active profile selection to none.

**REQ-VCP-27** — WHEN no profiles exist THEN the "Voice Profiles" list SHALL display an empty-state illustration with a "Record your first profile" call-to-action button.

**REQ-VCP-28** — WHEN a profile is active (selected for use in F7.2) THEN it SHALL be indicated in the list with a checkmark badge. Only one profile may be active at a time.

### 2.6 Active Profile Selection

**REQ-VCP-29** — WHEN the user selects a profile as active THEN the selection SHALL be persisted in `UserDefaults` under key `tlk.voiceCloning.activeProfileId` (stores the UUID string).

**REQ-VCP-30** — WHEN the app launches THEN the system SHALL restore the previously active profile by UUID; if the file no longer exists, the active profile SHALL be reset to none and a silent log entry written.

**REQ-VCP-31** — WHEN no active profile is selected THEN `TTSEngineSelector` SHALL treat voice cloning as unavailable and route to the standard TTS engine (Kokoro or AVSpeech per language).

---

## 3. Non-Functional Requirements

### 3.1 Performance

**REQ-VCP-NF-01** — The profile list SHALL load (enumerate + parse headers from all `.vpf` files) in ≤ 1 second for up to 20 profiles on M1 hardware.

**REQ-VCP-NF-02** — Profile save (encrypt + write a 30-second 24 kHz Float32 mono buffer ≈ 2.88 MB raw) SHALL complete in ≤ 3 seconds on M1 hardware.

**REQ-VCP-NF-03** — Recording capture SHALL introduce ≤ 20 ms latency on the level meter update path (UI responsiveness); audio buffering latency is independent of the display path.

**REQ-VCP-NF-04** — Profile decryption for F7.2 use SHALL complete in ≤ 500 ms for a 30-second profile on M1 hardware.

### 3.2 Security & Privacy

**REQ-VCP-NF-05** — Voice audio SHALL never be written to disk unencrypted; the only plaintext representation is the in-memory `AVAudioPCMBuffer` during capture and the decrypted payload during active inference.

**REQ-VCP-NF-06** — The AES-256-GCM key SHALL be stored exclusively in the macOS Keychain with `kSecAttrAccessibleWhenUnlocked` accessibility, preventing access when the device is locked.

**REQ-VCP-NF-07** — Profile names stored in the `.vpf` header (unencrypted) SHALL NOT contain audio data, transcript content, or any biometric derivative.

**REQ-VCP-NF-08** — All voice profile data SHALL be stored exclusively on-device; no network access SHALL be required or attempted for profile creation, storage, or retrieval.

**REQ-VCP-NF-09** — Secure deletion SHALL overwrite the file with zeros before unlinking (mitigates casual filesystem recovery).

### 3.3 Reliability

**REQ-VCP-NF-10** — The recording flow SHALL be interruptible at any step (user quits app, incoming call interrupts audio session) without corrupting any existing profiles.

**REQ-VCP-NF-11** — IF the audio engine is interrupted mid-recording (e.g. another app takes exclusive access) THEN the system SHALL stop recording, discard the incomplete capture, and notify the user.

**REQ-VCP-NF-12** — The profile store SHALL be resilient to corrupt `.vpf` files: if decryption fails on a file (bad IV, truncated, wrong key) THEN the system SHALL log the error, exclude that file from the list, and continue loading remaining profiles.

### 3.4 Compatibility

**REQ-VCP-NF-13** — The `VoiceProfileStore` SHALL be injectable with a custom storage URL for unit testing (no hardcoded `Application Support` path in testable code).

**REQ-VCP-NF-14** — The recording capture engine SHALL reuse `AudioManager`'s existing `AVAudioEngine` session or co-exist with it without conflict; if `AudioManager` is active (call in progress), recording SHALL be disallowed with an explanatory message.

---

## 4. Acceptance Criteria

| ID | Criterion | How Validated |
|----|-----------|---------------|
| AC-01 | A 30-second recording is captured, transcript entered, and profile saved to disk in encrypted form | Manual test: verify `.vpf` file exists; attempt to open as plaintext (should fail) |
| AC-02 | Quality warnings appear for low-level, clipped, and short recordings | Unit test: inject synthetic audio buffers meeting each threshold |
| AC-03 | Profiles survive app restart and are listed correctly | Manual test: quit, relaunch, verify list |
| AC-04 | Active profile selection persists across restarts | Unit test: set active, simulate launch, verify UUID restored |
| AC-05 | Delete removes the file from disk and resets active profile if needed | Unit test with mock store URL |
| AC-06 | A corrupt `.vpf` file does not crash the app; other profiles load normally | Unit test: inject file with invalid bytes at the store URL |
| AC-07 | Profile save fails gracefully (no partial file) when Keychain is unavailable | Unit test with mock Keychain that throws |
| AC-08 | Decrypted audio is Float32 mono at exactly 24 kHz (format F7.2 expects) | Unit test: decrypt saved profile, assert `AVAudioFormat` properties |
| AC-09 | Transcript is required; saving without one is blocked | Unit test: call save with empty transcript, expect error |
| AC-10 | `VoiceProfileStore` correctly reports `noActiveProfile` when the stored UUID file has been deleted | Unit test |
| AC-11 | Recording is blocked when `AudioManager` is in an active call session | Unit test: mock `AudioCoordinator` as active, attempt start recording |
| AC-12 | No microphone audio is captured before permission is explicitly granted | Manual test via Privacy dashboard — no mic access before dialog |

---

## 5. Out of Scope (Explicitly Deferred)

- **CSM-1B inference**: Model loading, voice conditioning, synthesis — deferred to F7.2.
- **Voice similarity score**: Cosine similarity or MOS-based quality rating of cloned output — deferred to F7.2.
- **A/B voice preview**: Toggle between cloned and standard TTS before a call — deferred to F7.3.
- **Per-language profile tuning**: Separate profiles per locale — deferred to F7.3.
- **iCloud sync**: Cross-device profile sharing — not in M7 scope.
- **Voice profile export**: Sharing profiles between users or devices — not in M7 scope.
- **Automatic transcript generation**: Using STT (Parakeet or Apple Speech) to auto-transcribe the recording — considered as a UX enhancement but deferred to keep F7.1 scope tight; the user types the transcript manually.
- **Multiple recordings per profile**: Averaging across multiple takes for better conditioning — deferred to F7.3.
