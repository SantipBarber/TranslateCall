# opengrep rules

Project-specific static analysis run by `just scan` / `just check` and the GitHub `check` job
(`tools/scripts/scan.sh`). Rules are regex-based (`languages: [regex]`) because opengrep's Swift
support is pattern-level only (spec F8.5.0 OQ-2).

Each `rules/<name>.yml` has a sibling `rules/<name>.swift` with `// ruleid:` / `// ok:` annotations;
`scan.sh` runs `opengrep test` first and fails if those self-tests fail or don't run.

| Rule | Severity | Why | Audit reference |
|------|----------|-----|-----------------|
| `asyncstream-unbounded` | WARNING | Unbounded `AsyncStream` in audio/TTS code grows without limit | 48 kHz stream leak, `AudioManager.swift:148` |
| `asyncstream-force-unwrap` | WARNING | `cont!` after `AsyncStream { cont = $0 }` | 6 occurrences; use `AsyncStream.makeStream` |
| `nonisolated-unsafe-justified` | WARNING | `nonisolated(unsafe)` without a `// SAFETY:` comment on the previous line | 41 occurrences |
| `playernode-isplaying-poll` | WARNING | `AVAudioPlayerNode.isPlaying` stays true until `stop()` — polling never ends | `EdgeTTSService.swift:167` |
| `buffer-nocopy-escape` | WARNING | `bufferListNoCopy` buffers alias caller memory | `SystemAudioCaptureService.swift:236` |
| `no-print` | ERROR | Use `os.Logger` | clean |
| `hardcoded-secret` | ERROR | Credentials in source | clean (one justified suppression) |

## Severity policy

- `ERROR` fails `just scan`, `just pr` and CI. `WARNING` is listed as tracked debt.
- A rule targeting an audited defect starts as `WARNING` and is promoted to `ERROR` in the PR
  that removes its last occurrence (F8.5.1+).
- Suppress a proven-safe line with `// nosemgrep: <rule-id>` plus a comment explaining why.
