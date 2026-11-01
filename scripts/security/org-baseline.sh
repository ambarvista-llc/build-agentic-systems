#!/usr/bin/env bash
# Audit a GitHub organization against the security baseline, and optionally fix drift.
#
# Usage:  bash scripts/security/org-baseline.sh <org> [--apply]
# Needs:  gh logged in as an org owner, with the admin:org scope
#           (gh auth refresh -h github.com -s admin:org), and jq.
#
# Default is audit: GET requests only, prints drift, exits 1 if anything differs.
# --apply shows the drift, asks for a y/N on the terminal, writes only the settings
# that drifted, then audits again. An agent should only ever run the audit.
#
# Some org settings can't be read or changed through the API; they're listed as MANUAL.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

USAGE="usage: org-baseline.sh <org> [--apply]"
parse_args "$@"
[[ $TARGET =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || { echo "$USAGE" >&2; exit 2; }
O="orgs/$TARGET"
ROLE=$(gh api "user/memberships/orgs/$TARGET" --jq .role 2>/dev/null || true)
[[ $ROLE == admin ]] || { echo "you need to be an owner of $TARGET (role: ${ROLE:-none})" >&2; exit 2; }
echo "Baseline for org $TARGET"

# Each is <field>=<value> on PATCH orgs/{org}; one call per field so a rejected field is visible.
MEMBER_FIELDS=(
  default_repository_permission=none
  members_can_create_repositories=false
  members_can_create_public_repositories=false
  members_can_create_private_repositories=false
  members_can_create_pages=false
  members_can_create_public_pages=false
  members_can_create_private_pages=false
  members_can_fork_private_repositories=false
)
# Readable through the API but changed only in the browser.
BROWSER_FIELDS=(
  two_factor_requirement_enabled=true
  members_can_delete_repositories=false
  members_can_change_repo_visibility=false
)

audit() {
  local kv
  for kv in "${MEMBER_FIELDS[@]}"; do check "m:${kv%%=*}" "$O" ".${kv%%=*}" "${kv#*=}" "${kv%%=*}"; done
  for kv in "${BROWSER_FIELDS[@]}"; do check "b:${kv%%=*}" "$O" ".${kv%%=*}" "${kv#*=}" "${kv%%=*} (browser-only)"; done
  check actions-perms "$O/actions/permissions" .allowed_actions selected "Actions: selected only"
  check actions-perms "$O/actions/permissions" .sha_pinning_required true "Actions: SHA pinning required"
  check actions-selected "$O/actions/permissions/selected-actions" .github_owned_allowed true "Actions: GitHub-owned allowed"
  check actions-selected "$O/actions/permissions/selected-actions" .verified_allowed false "Actions: verified creators not allowed"
  check actions-workflow "$O/actions/permissions/workflow" .default_workflow_permissions read "Actions: read-only token"
  check actions-workflow "$O/actions/permissions/workflow" .can_approve_pull_request_reviews false "Actions: can't approve PRs"
  check actions-fork "$O/actions/permissions/fork-pr-contributor-approval" .approval_policy all_external_contributors "Actions: approve all outside runs"
  plan_limit "outside-collaborator invites can't be restricted on the free plan (Enterprise Cloud only); currently members_can_invite_outside_collaborators=$(gh api "$O" --jq .members_can_invite_outside_collaborators). Low risk while you're the only repo admin."
  note "owners: $(gh api "$O/members?role=admin" --jq length). With one owner, save the 2FA recovery codes or add a second owner."
  note "allowed-action patterns: $(gh api "$O/actions/permissions/selected-actions" --jq '.patterns_allowed | length') (kept as they are when applying)"
  manual "Third-party access → restrict OAuth app access"
  check b:apps "$O/installations" '[.installations[] | select(.repository_selection != "selected") | .app_slug] | join(",")' "" "GitHub Apps scoped to selected repos (browser-only)"
  manual "Verified and approved domains"
  manual "Deploy keys, Pages and packages visibility"
}

apply() {
  local kv enabled patterns=() p
  for kv in "${MEMBER_FIELDS[@]}"; do
    drifted "m:${kv%%=*}" && try gh api -X PATCH "$O" -F "$kv"
  done
  # enabled_repositories is read back and passed through, so a narrower setting isn't widened.
  enabled=$(gh api "$O/actions/permissions" --jq .enabled_repositories)
  drifted actions-perms && try gh api -X PUT "$O/actions/permissions" -f enabled_repositories="$enabled" -f allowed_actions=selected -F sha_pinning_required=true
  if drifted actions-selected; then
    # The PUT replaces the whole list, so pass the existing patterns back.
    while IFS= read -r p; do [[ -n $p ]] && patterns+=(-f "patterns_allowed[]=$p"); done \
      < <(gh api "$O/actions/permissions/selected-actions" --jq '.patterns_allowed[]?')
    try gh api -X PUT "$O/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false ${patterns[@]+"${patterns[@]}"}
  fi
  drifted actions-workflow && try gh api -X PUT "$O/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  drifted actions-fork && try gh api -X PUT "$O/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors
  return 0
}

run_baseline
