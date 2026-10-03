#!/usr/bin/env bash
# One-off: protect main (REQ-W-61). Run ONLY after explicit confirmation from the repo owner.
set -euo pipefail
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
read -r -p "Apply branch protection to $repo:main (requires check + local/just-pr)? [y/N] " ans
[[ "$ans" == "y" ]] || { echo "aborted"; exit 1; }
gh api -X PUT "repos/$repo/branches/main/protection" --input - >/dev/null <<'JSON'
{
  "required_status_checks": { "strict": true, "contexts": ["check", "local/just-pr"] },
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
gh api -X PATCH "repos/$repo" -F allow_squash_merge=true -F allow_merge_commit=false \
  -F allow_rebase_merge=false -F delete_branch_on_merge=true >/dev/null
echo "✓ main protected; squash-only; branches auto-deleted"
