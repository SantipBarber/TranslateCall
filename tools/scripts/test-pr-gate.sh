#!/usr/bin/env bash
# Verifies pr.sh never certifies the wrong thing (review findings 1–2): a tree/HEAD change during the
# run, or a tier that ran 0 tests / skipped tests, must publish `failure`, never `success`.
# Runs pr.sh in a throwaway clone with stubbed push/status/steps/counts (TC_PR_* test hooks).
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git clone -q "$ROOT" "$TMP/repo" && cd "$TMP/repo"
git clone -q --bare "$ROOT" "$TMP/remote.git"       # never push to the real repo, even if a hook is ignored
git remote set-url origin "$TMP/remote.git"
git checkout -q -B test/gate "$(git -C "$ROOT" rev-parse HEAD)"

export TC_PR_PUSH=true                              # no network
export TC_PR_STATUS="$TMP/status.sh"                # records "<state> <sha> <desc>"
printf '#!/usr/bin/env bash\necho "$1 $3 $2" >> %q\n' "$TMP/statuses" > "$TC_PR_STATUS"; chmod +x "$TC_PR_STATUS"
export TC_PR_CREATE=true                            # no PR creation
fail=0
last() { tail -1 "$TMP/statuses" | cut -d' ' -f1; }
expect() {  # expect <name> <final-state>
  if [[ "$(last)" == "$2" ]]; then echo "✓ $1"; else echo "✗ $1: last status '$(last)', expected '$2'"; fail=1; fi
  : > "$TMP/statuses"
}

TC_PR_STEPS="true" TC_PR_COUNTS="10 0 5 0" tools/scripts/pr.sh >/dev/null 2>&1 || true
expect "happy path posts success" success

TC_PR_STEPS="touch edited.swift" TC_PR_COUNTS="10 0 5 0" tools/scripts/pr.sh >/dev/null 2>&1 || true
expect "tree changed during run → failure" failure
rm -f edited.swift

TC_PR_STEPS="git commit -q --allow-empty -m drift" TC_PR_COUNTS="10 0 5 0" tools/scripts/pr.sh >/dev/null 2>&1 || true
expect "HEAD moved during run → failure" failure
git reset -q --hard HEAD~1

TC_PR_STEPS="true" TC_PR_COUNTS="10 0 0 0" tools/scripts/pr.sh >/dev/null 2>&1 || true
expect "0 integration tests → failure" failure

TC_PR_STEPS="true" TC_PR_COUNTS="10 0 5 2" tools/scripts/pr.sh >/dev/null 2>&1 || true
expect "skipped integration tests → failure" failure

TC_PR_STEPS="false" TC_PR_COUNTS="10 0 5 0" tools/scripts/pr.sh >/dev/null 2>&1 || true
expect "failing step → failure" failure

# Every status must be posted on the SHA captured at start.
exit $fail
