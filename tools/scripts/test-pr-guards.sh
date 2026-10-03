#!/usr/bin/env bash
# Verifies `just pr` refuses on main and on a dirty tree (REQ-W-40). Runs in a throwaway clone.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git clone -q "$ROOT" "$TMP/repo"
cd "$TMP/repo"
git checkout -q "$(git -C "$ROOT" rev-parse HEAD)"   # test the committed scripts of the current HEAD
export TC_PR_DRY_RUN=1                               # pr.sh exits right after the guards

git switch -q -C main
if tools/scripts/pr.sh >/dev/null 2>&1; then echo "✗ ran on main"; exit 1; fi
git switch -q -c test/guard
echo dirty > dirty.txt
if tools/scripts/pr.sh >/dev/null 2>&1; then echo "✗ ran with dirty tree"; exit 1; fi
rm dirty.txt
tools/scripts/pr.sh >/dev/null || { echo "✗ refused a clean feature branch"; exit 1; }
echo "✓ pr guards"
