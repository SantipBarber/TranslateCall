#!/usr/bin/env bash
# Full PR gate (REQ-W-40..43): guards → push → build → check → test → test-integration → status → PR.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

branch=$(git branch --show-current)
[[ -n "$branch" && "$branch" != "main" ]] || { echo "✗ just pr must run on a feature branch, not main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ working tree not clean — commit or stash first" >&2; exit 1; }
if [[ "${TC_PR_DRY_RUN:-}" == "1" ]]; then echo "✓ guards passed (dry run)"; exit 0; fi

git push -u origin HEAD          # the status must point at a commit GitHub knows
tools/scripts/pr-status.sh pending "just pr running…"

step="build"
# The step already failed and set -e will exit non-zero; a network error while
# reporting the failure must not mask that exit code.
trap 'tools/scripts/pr-status.sh failure "failed at: just $step" || true' ERR
start=$SECONDS
for step in build check test test-integration; do
  echo "━━ just $step ━━"
  just "$step"
done
trap - ERR

passed() {
  xcrun xcresulttool get test-results summary --path "$1" --format json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["passedTests"])'
}
unit=$(passed build/logs/unit.xcresult)
integ=$(passed build/logs/integration.xcresult)
dur=$((SECONDS - start))
tools/scripts/pr-status.sh success "$unit unit, $integ integration · $((dur / 60))m$((dur % 60))s"

if gh pr view --json url -q .url >/dev/null 2>&1; then
  echo "• PR already exists: $(gh pr view --json url -q .url)"
else
  gh pr create --base main --fill
fi
