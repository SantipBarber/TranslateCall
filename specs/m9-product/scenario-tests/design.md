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

## 5. v2: pauses (Task 18 Q4/Q5)

> Status: written 2026-11-04 while the user was away ("Avanza con todo lo que puedas hacer sin que necesites mi ayuda"). Every call below is mine; the user reviews it in the PR.

Both scenarios run outgoing es-ES>en on Best (the profile the user tested by hand), with no echo route.

### 5.1 What Task 18 asked

- Q5: hesitations mid-sentence are not cut more than before; each sentence is spoken once, whole.
- Q4: stop mid-sentence and talk again at once: the next sentence is in the standard voice, then the clone comes back. The first pass found the interrupted sentence dropped, by design.

Q4's "stop" is the session's Pause button (`AudioCoordinator.pause()`), my reading: pausing stops the clone's playback, so its generation is abandoned and holds the gate (qwen-streaming design §3 point 5). The next clone sentence then falls back at once. A speaker who merely goes quiet gets queued sentences, which are never cut (F8.5.3 D-5), and that cannot give the standard voice.

### 5.2 Clip shapes

Clips are the line's PR set, as in v1. A scenario can reshape them before playing:

- `innerPause(seconds)`: silence inserted between two words, at the word gap nearest the middle of the clip's speech (`speechStartMs…speechEndMs`). The clips have no word timings, so the runner asks Apple Speech for them on the original clip (`WordGaps.find`). If recognition finds fewer than two words, it falls back to the quietest 20 ms frame between 35 % and 65 % of the speech. The first version always used that frame, and in cv-es-es-0097 it fell inside "antigua" (the closure of the "g"), which caused QS-8.
- `joined(n)`: n consecutive clips played as one, with no gap. This gives a sentence long enough for the clone to still be generating when the user pauses.

### 5.3 Scenarios

- `pause-short` (Q5): `innerPause(0.4)`, which is above the 0.2 s tentative and below the 0.6 s default pause. Rules:
  - `piecesPerClip(1...1)`: no cut;
  - `spokenOnce(.outgoing)`;
  - `wordsKept(0.85)`;
  - `quietAfter(12 s)`.
- `pause-long` (Q5): `innerPause(1.0)`, so the cut is expected. Rules:
  - `piecesPerClip(1...2)`;
  - `spokenOnce(.outgoing, perClip: 2)`;
  - `wordsKept(0.85)`;
  - `quietAfter(12 s)`.
- `pause-resume` (Q4) runs this script:
  1. Play 3 clips joined.
  2. Wait for its first outgoing audio, then 0.5 s.
  3. `pause()`; 0.3 s of silence; `resume()`.
  4. At once, 3 more clips, one by one, each settled.

  Its rules:
  - `noAudioWhilePaused`;
  - `spokenOnce(.outgoing)`;
  - `cloneAfterResume`: every clip after the resume is spoken, and the last one by `voiceClone`. The engines are listed. Whether the first sentence after the resume falls back depends on how long the abandoned generation runs, so it is reported, not failed;
  - `quietAfter(12 s)`.

### 5.4 Rules

A clip's utterances are the outgoing seqs whose `speechStart` falls in its window. The window runs from the clip's start − 0.5 s to the next clip's start − 0.5 s.

- `piecesPerClip(range)`: the count of spoken utterances (with `ttsFirstBuffer`) of each clip is in `range`.
- `wordsKept(minRecall)`: the share of the transcripts' words, folded as in `WordErrorRate`, found in the recognized text of their clip's spoken utterances, all clips pooled. The worst clip is reported. On this set es-ES WER is 2.7 % (Basic baseline), so 0.85 leaves room for STT noise while a lost half-sentence fails.
- `spokenOnce(direction, perClip:)`: v1's rule, generalised. The v1 scenarios use `.spokenOnce(.incoming)`.
- `noAudioWhilePaused`: no TTS buffer of either direction is scheduled from pause + 50 ms to the resume.
- `cloneAfterResume`: described in §5.3.

### 5.5 First runs (2026-11-04, main 79d8b6b plus this branch)

All three scenarios passed in every run (`pause-*` ran 3 times, the full catalog once).

- `pause-short`: never cut, 100 % of the words kept every time.
- `pause-long`: cut as expected, 87–96 % of the words kept. Clip 0 lost one of its two pieces in 2 of 3 runs, because Apple Speech returned empty text for it (backlog QS-8).
  - In one run the clone took 5–9 s per 2–5-word piece. In the run with the audio saved, every piece was 1.5–3.5 s, so the slow run is not explained.
- `pause-resume`: no audio while paused. The clone spoke every sentence after the resume: the abandoned generation was over before the next sentence was translated. The standard-voice fallback was not exercised (§5.3: reported, not failed).
- Found while building this, a v1 bug: `BenchOutput.drain()` also cleared the schedule times that `quietAfter` reads. A rule could then only see buffers scheduled after the last drain. The times are now kept for the whole session. The 5 v1 scenarios still pass.
