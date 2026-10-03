#!/usr/bin/env bash
# Full PR gate (REQ-W-40..43): guards → push → build → check → test → test-integration → status → PR.
# The status is bound to the SHA captured at start; success is only posted if that exact,
# unmodified commit is what was tested and both tiers actually ran tests.
#
# Test hooks (tools/scripts/test-pr-gate.sh): TC_PR_DRY_RUN, TC_PR_PUSH, TC_PR_STATUS,
# TC_PR_STEPS, TC_PR_COUNTS ("unit_passed unit_skipped integ_passed integ_skipped"), TC_PR_CREATE.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

branch=$(git branch --show-current)
[[ -n "$branch" && "$branch" != "main" ]] || { echo "✗ just pr must run on a feature branch, not main" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "✗ working tree not clean — commit or stash first" >&2; exit 1; }
if [[ "${TC_PR_DRY_RUN:-}" == "1" ]]; then echo "✓ guards passed (dry run)"; exit 0; fi

sha=$(git rev-parse HEAD)
status() { "${TC_PR_STATUS:-tools/scripts/pr-status.sh}" "$1" "$2" "$sha"; }
# The run already failed; a network error while reporting it must not mask the exit code.
report_failure() { status "$1" "$2" || true; }

${TC_PR_PUSH:-git push -u origin HEAD}   # the status must point at a commit GitHub knows
status pending "just pr running…"

step="start"
trap 'report_failure failure "failed at: $step"' ERR
trap 'report_failure error "interrupted at: $step"; exit 130' INT TERM
start=$SECONDS
IFS=';' read -r -a steps <<<"${TC_PR_STEPS:-just build;just check;just test;just test-integration}"
for step in "${steps[@]}"; do
  echo "━━ $step ━━"
  $step
done

step="verify"
counts() {
  if [[ -n "${TC_PR_COUNTS:-}" ]]; then echo "$TC_PR_COUNTS"; return; fi
  for bundle in build/logs/unit.xcresult build/logs/integration.xcresult; do
    xcrun xcresulttool get test-results summary --path "$bundle" --format json |
      python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["passedTests"], d["skippedTests"], end=" ")'
  done
}
read -r unit unit_skipped integ integ_skipped <<<"$(counts)"
fail() { report_failure failure "$1"; echo "✗ $1" >&2; exit 1; }
[[ "$(git rev-parse HEAD)" == "$sha" ]] || fail "HEAD moved during the run — rerun just pr"
[[ -z "$(git status --porcelain)" ]] || fail "working tree changed during the run — rerun just pr"
(( unit > 0 )) || fail "unit tier ran 0 tests"
(( integ > 0 )) || fail "integration tier ran 0 tests (TC_TEST_TIER not reaching the test host?)"
(( integ_skipped == 0 )) || fail "integration tier skipped $integ_skipped test(s)"
trap - ERR INT TERM

dur=$((SECONDS - start))
status success "$unit unit ($unit_skipped skipped), $integ integration · $((dur / 60))m$((dur % 60))s"

if [[ -n "${TC_PR_CREATE:-}" ]]; then $TC_PR_CREATE; exit 0; fi
if gh pr view --json url -q .url >/dev/null 2>&1; then
  echo "• PR already exists: $(gh pr view --json url -q .url)"
else
  # --fill would ignore the PR template (REQ-W-04); use it as the body explicitly.
  gh pr create --base main --title "$(git log -1 --format=%s)" --body-file .github/pull_request_template.md
fi
