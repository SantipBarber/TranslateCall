# Contributing to TranslateCall

## Requirements

macOS 15+ on Apple Silicon, Xcode 27, Homebrew, [just](https://github.com/casey/just) and the
GitHub CLI (`gh`, authenticated). Run `just setup` once: it installs and verifies the pinned tools
(`tools/versions.env`) and the Metal Toolchain needed by MLX.

## Branches

Never commit to `main`. Always branch from an up-to-date `main`:

```bash
git switch main && git pull --ff-only
git switch -c <prefix>/<kebab-slug>
```

Prefixes: `feat/`, `fix/`, `chore/`, `docs/`, `spec/`, `test/`, `refactor/`.

## Commits

[Conventional Commits](https://www.conventionalcommits.org): `<type>(<scope>): <summary>`, e.g.
`fix(audio): recreate system stream on activate`. Types match the branch prefixes.

## Specs first

Features follow Spec-Driven Development under `specs/`: `requirements.md` → `design.md` →
`tasks.md` → implementation. Link the spec and task in the PR.

## Everyday commands

| Command | What it does |
|---------|--------------|
| `just` | List recipes |
| `just build` | Debug build |
| `just test` | Unit tier (fast: no network, mic or models) |
| `just test-only <Suite>…` | Selected unit suites |
| `just test-integration` | Real Apple frameworks + audio fixtures; writes `build/reports/latency.json` |
| `just check` | SwiftLint (strict) + opengrep — exactly what GitHub runs |
| `just fixtures` | Regenerate audio fixtures from `TranslateCallTests/Fixtures/Audio/manifest.json` |
| `just pr` | Full gate (below) |

Integration tests live under `TranslateCallTests/Integration/` as `extension IntegrationTests { … }`.
A missing prerequisite (permission, language pack, model) must **fail** with a clear message,
never skip. Disabling a test needs `.disabled("F<x.y>: reason")`; a known product limitation uses
`withKnownIssue("F<x.y>: …")`.

## Pull requests

`just pr` refuses to run on `main` or with uncommitted changes. It pushes the branch, runs
build → check → unit → integration, publishes the commit status `local/just-pr` on that exact SHA
and opens the PR if needed. A new commit invalidates the status: run `just pr` again.

`main` is protected: PRs need the GitHub `check` job (Linux: opengrep + SwiftLint) and
`local/just-pr` to be green. Merge with **squash**; the branch is deleted automatically.

## Static analysis

Project rules live in `.opengrep/rules/` (see `.opengrep/README.md`). `ERROR` findings block;
`WARNING` findings are tracked debt from the 2026-10-03 audit and are promoted to `ERROR` when
their last occurrence is fixed.
