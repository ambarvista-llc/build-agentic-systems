#!/usr/bin/env bash
# Apply the security baseline to one GitHub repository.
#
# Usage:  bash scripts/security/repo-baseline.sh <owner>/<repo>
# Needs:  gh logged in as an admin of the repo.
#
# Safe to rerun: rulesets are created only if one with the same name is missing.
# Free-plan note: rulesets and secret push protection are only enforced on
# PUBLIC repos; on private repos they need GitHub Team. Dependabot is free everywhere.
#
# This is the seed of the Episode 1 security audit agent (spec 002), which
# adds a read-only audit mode and reports drift from this baseline.
set -euo pipefail

REPO="${1:?usage: repo-baseline.sh <owner>/<repo>}"
R="repos/$REPO"
VISIBILITY=$(gh api "$R" --jq .visibility)
echo "Applying baseline to $REPO ($VISIBILITY)"

ensure_ruleset() {  # name, json
  if gh api "$R/rulesets" --jq '.[].name' | grep -qx "$1"; then
    echo "   ruleset '$1' already exists, skipping"
  else
    gh api -X POST "$R/rulesets" --input - >/dev/null <<<"$2"
    echo "   ruleset '$1' created"
  fi
}

echo "== Features: no issues, wiki, projects, discussions; PRs from collaborators only"
gh api -X PATCH "$R" \
  -F has_issues=false -F has_wiki=false -F has_projects=false -F has_discussions=false >/dev/null

echo "== Merges: squash only, PR title/body, auto-delete branches"
gh api -X PATCH "$R" \
  -F allow_merge_commit=false -F allow_rebase_merge=false -F allow_squash_merge=true \
  -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY >/dev/null

echo "== Dependabot alerts + security updates"
gh api -X PUT "$R/vulnerability-alerts"
gh api -X PUT "$R/automated-security-fixes"

if [[ "$VISIBILITY" == "public" ]]; then
  echo "== Public repo: secret scanning + push protection, private vulnerability reporting"
  gh api -X PATCH "$R" --input - >/dev/null <<'EOF'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
EOF
  gh api -X PUT "$R/private-vulnerability-reporting"
fi

echo "== Actions: GitHub-owned actions only, read-only token, approve all outside runs"
gh api -X PUT "$R/actions/permissions" -F enabled=true -f allowed_actions=selected
gh api -X PUT "$R/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false
gh api -X PUT "$R/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "$R/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors

echo "== Rulesets"
# required_approving_review_count is 0 because GitHub won't let you approve your own PRs.
# Raise it to 1 (and require code owner review) once agents open PRs through a bot account.
ensure_ruleset protect-main '{
  "name": "protect-main", "target": "branch", "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false, "require_last_push_approval": false,
      "required_review_thread_resolution": true}}
  ]}'
ensure_ruleset protect-episode-tags '{
  "name": "protect-episode-tags", "target": "tag", "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/ep*"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "update"}, {"type": "non_fast_forward"}]}'

echo "== Browser-only (do these by hand):"
echo "   Settings → General → Pull requests → Collaborators only"
echo "   Settings → Advanced Security → malware alerts"
echo "   Once there's code: CodeQL default setup"
echo "     gh api -X PATCH $R/code-scanning/default-setup -f state=configured"
echo "Done."
