# M9 UI core — shared backlog

> Collected 2026-10-18 from the M9 UI core implementation and review.
> Every `.disabled("M9 …")`, `withKnownIssue("M9 …")` and opengrep WARNING points here.

## Sub-features

| Sub-feature | Spec | Items |
|-------------|------|-------|
| UI core | `m9-product/ui-core/` | A29, UI-L1, UI-L2 |

## From the implementation

| # | Defect / Finding | Where | Guard in place |
|---|------------------|-------|----------------|
| A29 | `LanguagePairManagerTests` uses `UserDefaults.standard` in a parallel suite; it flaked once in 4 runs (P16) | `LanguagePairManagerTests.swift` | — |
| UI-L1 | Wire `TraceLatencyProvider` once `spec/m9-benchmark` is on `main` (D-3) | `LatencyProvider.swift` | `NoLatencyProvider` production placeholder; hidden label and setting |
| UI-L2 | "Advanced…" opens the legacy tab until feature 2 | `LanguageSection.swift`, `SettingsOpener` | `SettingsTab.advancedLegacy` wired to "Advanced…" and legacy view |
