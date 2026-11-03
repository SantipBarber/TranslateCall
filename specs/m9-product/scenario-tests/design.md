# M9 scenario tests — Design

> Status: APPROVED in chat (2026-11-03): "Si, me parece bien, arranca". Layer 1 of the plan: automate the manual Task 18 checks so a change is verified in minutes, without the user. Layer 2 (Peekaboo, real UI) is a later spec.

## 1. Why

The Task 18 manual pass (2026-11-02) cost the user a session and found three things the bench never sees:

- Q6: a translation repeated in a loop on the Mac speakers;
- Q3: the guided recording too short to save;
- pitch drift: some clone sentences higher and less like the user.

The bench already drives the production `AudioCoordinator` with clip-fed captures and a fake output (`TranslateCallTests/Bench`). Scenarios reuse that session and add what those checks need: playback in real time, an acoustic path from the output back to a capture, the listening mode, and pass/fail rules.

## 2. Goals and non-goals

Goals:

- `just scenario <name>` runs one scenario (or `all`) in a few minutes on the Release build, prints a verdict per rule and exits non-zero on a failed rule.
- Scenarios v1:
  - `echo-speakers`: incoming en>es on speakers, listening mode `.speakers`;
  - `echo-headphones`: the same acoustic path with the default mode `.headphones` (the user's likely Q6 setup);
  - `echo-both`: both sides on speakers (remote echo too), the runaway-loop case.
- Every run writes its trace and audio under `build/scenarios/<run-id>/<scenario>/` for a look afterwards.

Non-goals (later tasks or specs):

- the real UI (layer 2);
- the guided recording (Q3);
- pauses (Q4/Q5);
- the voice-pitch metric.

Anti-goal: a scenario that passes because the fake is kinder than the device. Playback finishes in real time, plus the `.dataPlayedBack` delay macOS 27.2 adds (A30, 250 ms).

## 3. Design

### 3.1 Real-time output with an acoustic path

`BenchOutput` gains a real-time mode; the default stays the bench's instant mode.

- In real-time mode, each direction plays on its own timeline. The bench's TTS output factory hands each direction a `BenchOutput.Device` view, so the speakers and the call mic are separate devices.
- A buffer starts at `max(now, end of the previous buffer)`. Its handle is marked played at `start + duration + playedLatency`.
- `stop()`/`shutdown()` cancel pending handles. They also drop the echo not yet heard (from now on).
- An echo route is a `(from: TraceDirection, to: BenchClipPlayer, gain, delay)` pair. Each scheduled buffer is resampled to 16 kHz mono, scaled by `gain` and mixed into the target player at `start + delay`.

`BenchClipPlayer` gains `mix(_ samples: [Float], at instant: ContinuousClock.Instant)`. Mixed segments are added on top of whatever the stream yields (clip or silence), at the stream position of `instant`, which is `(instant − stream start) × 16 000`. `truncateMix(from:)` drops what has not played yet. Clipping is to ±1.

### 3.2 Scenario

Scenarios are Swift values (`ScenarioCatalog`), not JSON: rules are code, and the test asserts them.

```swift
struct Scenario {
    let name: String
    let line: BenchRunLine            // which side the clips play on
    let profile: BenchProfile
    let listeningMode: ListeningMode
    let routes: [EchoRoute]            // output → capture
    let playedLatency: Duration        // A30
    let clipLimit: Int                 // first N clips of the line's PR set
    let rules: [ScenarioRule]
}
```

Rules, each checked from the trace and reported with its numbers:

- `noOutgoingFromEcho`: no outgoing `sttFinal` with non-empty text. The user never speaks in an incoming scenario, so anything recognized there is echo.
- `spokenOnce`: no incoming translated text reaches `ttsFirstBuffer` twice (normalized text). The number of incoming `ttsFirstBuffer` events is at most the number of clips.
- `quietAfter(seconds)`: no TTS buffer of either direction is scheduled later than `seconds` after the last clip ended. This is the runaway-loop guard.

`echo-headphones` has the same acoustic path with the default mode. Its rule set is the product's real requirement: no translation repeated. If it fails, that is the finding (the default mode cannot cope with speakers), not a broken test.

### 3.3 Running

- `ScenarioTests` is a Bench-tier suite, enabled only when `TC_SCENARIO` is set (`name` or `all`), with one parameterised test per scenario.
- `tools/scripts/scenario.sh <name>` reuses the bench's Release `build-for-testing` and runs `test-without-building -only-testing:TranslateCallTests/BenchTests/ScenarioTests`.
- Each scenario writes `scenario.json` (rules, numbers, events by direction) and the audio per direction.
- The script prints the verdict table and the run directory.

## 4. Settled calls (mine)

- Gain 0.5 and delay 40 ms for the Mac mini speakers into the Brio. The clips come in at about −20 dBFS speech, and a 0.5 echo is about −26 dBFS. That is loud enough for Silero, which is the worst case.
- Up to 6 clips per scenario, which keeps each scenario around 1.5 min.
- Basic profile (AVSpeech): the loop is about routing, not the voice. A `best` variant can follow.
