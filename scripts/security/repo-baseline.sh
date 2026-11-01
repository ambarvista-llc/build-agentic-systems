#!/usr/bin/env bash
# Audit one GitHub repository against the security baseline, and optionally fix drift.
#
# Usage:  bash scripts/security/repo-baseline.sh <owner>/<repo> [--apply]
# Needs:  gh logged in as an admin of the repo, and jq.
#
# Default is audit: GET requests only, prints drift, exits 1 if anything differs.
# --apply shows the drift, asks for a y/N on the terminal, writes only the groups
# that drifted, then audits again. An agent should only ever run the audit.
#
# Free-plan note: rulesets and secret push protection are only enforced on
# PUBLIC repos; on private repos they need GitHub Team. Dependabot is free everywhere.
#
# This is the seed of the planned security audit agent (spec 002).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="usage: repo-baseline.sh <owner>/<repo> [--apply]"
parse_args "$@"
[[ $TARGET =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ && $TARGET != *..* && $TARGET != */. ]] || { echo "$USAGE" >&2; exit 2; }
R="repos/$TARGET"
VISIBILITY=$(gh api "$R" --jq .visibility) || { echo "can't read $TARGET" >&2; exit 2; }
echo "Baseline for $TARGET ($VISIBILITY)"

# Desired rulesets. bypass_actors is explicit so the audit can compare it.
PROTECT_MAIN='{
  "name": "protect-main", "target": "branch", "enforcement": "active", "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [
    {"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true,
      "require_code_owner_review": false, "require_last_push_approval": false,
      "required_review_thread_resolution": true}}
  ]}'
# required_approving_review_count is 0 because GitHub won't let you approve your own PRs.
# Accepted risk: an admin or agent token can merge without review. Raise it to 1
# (and require code owner review) once agents open PRs through a bot account.
PROTECT_TAGS='{
  "name": "protect-episode-tags", "target": "tag", "enforcement": "active", "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/tags/ep*"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "update"}, {"type": "non_fast_forward"}]}'

# The parts of a ruleset the baseline cares about (GitHub adds default fields we ignore).
SHAPE='{enforcement, include: .conditions.ref_name.include, bypass: (.bypass_actors // []),
  types: ([.rules[].type] | sort),
  pr: ([.rules[] | select(.type == "pull_request") | .parameters
        | {required_approving_review_count, dismiss_stale_reviews_on_push, required_review_thread_resolution}][0])}'

ruleset_id() { gh api "$R/rulesets" --jq ".[] | select(.name == \"$1\") | .id"; }

check_ruleset() {  # name, desired json
  local id have want
  id=$(ruleset_id "$1")
  if [[ -z $id ]]; then mark_drift "ruleset-$1" "ruleset $1: missing"; return; fi
  have=$(gh api "$R/rulesets/$id" | jq -cS "$SHAPE")
  want=$(jq -cS "$SHAPE" <<<"$2")
  if [[ "$have" == "$want" ]]; then echo "   ok     ruleset $1"; else mark_drift "ruleset-$1" "ruleset $1 differs: want $want, got $have"; fi
}

apply_ruleset() {  # name, desired json
  local id
  id=$(ruleset_id "$1")
  if [[ -n $id ]]; then try gh api -X PUT "$R/rulesets/$id" --input - <<<"$2"
  else try gh api -X POST "$R/rulesets" --input - <<<"$2"; fi
}

audit() {
  check features "$R" .has_issues false "Issues off"
  check features "$R" .has_wiki false "Wiki off"
  check features "$R" .has_projects false "Projects off"
  check features "$R" .has_discussions false "Discussions off"
  check merges "$R" .allow_squash_merge true "squash merge on"
  check merges "$R" .allow_merge_commit false "merge commits off"
  check merges "$R" .allow_rebase_merge false "rebase merge off"
  check merges "$R" .allow_auto_merge false "auto-merge off"
  check merges "$R" .delete_branch_on_merge true "delete branch on merge"
  check merges "$R" .squash_merge_commit_title PR_TITLE "squash title = PR title"
  check merges "$R" .squash_merge_commit_message PR_BODY "squash message = PR body"
  check_ok dependabot-alerts "$R/vulnerability-alerts" "Dependabot alerts"
  check dependabot-updates "$R" .security_and_analysis.dependabot_security_updates.status enabled "Dependabot security updates"
  check immutable "$R/immutable-releases" .enabled true "immutable releases"
  if [[ $VISIBILITY == public ]]; then
    check scanning-secret "$R" .security_and_analysis.secret_scanning.status enabled "secret scanning"
    check scanning-push "$R" .security_and_analysis.secret_scanning_push_protection.status enabled "secret push protection"
    check pvr "$R/private-vulnerability-reporting" .enabled true "private vulnerability reporting"
  fi
  check actions-perms "$R/actions/permissions" .allowed_actions selected "Actions: selected only"
  check actions-perms "$R/actions/permissions" .sha_pinning_required true "Actions: SHA pinning required"
  check actions-selected "$R/actions/permissions/selected-actions" .github_owned_allowed true "Actions: GitHub-owned allowed"
  check actions-selected "$R/actions/permissions/selected-actions" .verified_allowed false "Actions: verified creators not allowed"
  check actions-workflow "$R/actions/permissions/workflow" .default_workflow_permissions read "Actions: read-only token"
  check actions-workflow "$R/actions/permissions/workflow" .can_approve_pull_request_reviews false "Actions: can't approve PRs"
  check actions-fork "$R/actions/permissions/fork-pr-contributor-approval" .approval_policy all_external_contributors "Actions: approve all outside runs"
  check_ruleset protect-main "$PROTECT_MAIN"
  check_ruleset protect-episode-tags "$PROTECT_TAGS"
  note "CodeQL default setup: $(gh api "$R/code-scanning/default-setup" --jq .state 2>/dev/null || echo unreadable) (add once there's code)"
  manual "Settings → General → Pull requests → collaborators only (UNVERIFIED)"
  manual "Settings → General → turn off 'Allow comments on individual commits' (UNVERIFIED)"
  manual "Settings → Advanced Security → malware alerts (UNVERIFIED)"
}

apply() {
  drifted features && try gh api -X PATCH "$R" -F has_issues=false -F has_wiki=false -F has_projects=false -F has_discussions=false
  drifted merges && try gh api -X PATCH "$R" \
    -F allow_merge_commit=false -F allow_rebase_merge=false -F allow_squash_merge=true -F allow_auto_merge=false \
    -F delete_branch_on_merge=true -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
  drifted dependabot-alerts && try gh api -X PUT "$R/vulnerability-alerts"
  drifted dependabot-updates && try gh api -X PUT "$R/automated-security-fixes"
  drifted immutable && try gh api -X PUT "$R/immutable-releases"
  if drifted scanning-secret || drifted scanning-push; then
    try gh api -X PATCH "$R" --input - <<<'{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
  fi
  drifted pvr && try gh api -X PUT "$R/private-vulnerability-reporting"
  # When the org already sets these, the repo-level call returns 409; that's fine.
  drifted actions-perms && try_org_managed -X PUT "$R/actions/permissions" -F enabled=true -f allowed_actions=selected -F sha_pinning_required=true
  drifted actions-selected && try_org_managed -X PUT "$R/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false
  drifted actions-workflow && try_org_managed -X PUT "$R/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  drifted actions-fork && try_org_managed -X PUT "$R/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
  drifted ruleset-protect-main && apply_ruleset protect-main "$PROTECT_MAIN"
  drifted ruleset-protect-episode-tags && apply_ruleset protect-episode-tags "$PROTECT_TAGS"
  return 0
}

run_baseline
