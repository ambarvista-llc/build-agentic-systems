#!/usr/bin/env bash
# Apply the security baseline to a GitHub organization.
#
# Usage:  bash scripts/security/org-baseline.sh <org>
# Needs:  gh logged in as an org owner, with the admin:org scope:
#           gh auth refresh -h github.com -s admin:org
#
# Some org settings can't be changed through the API; they're listed at the end.
set -euo pipefail

ORG="${1:?usage: org-baseline.sh <org>}"
O="orgs/$ORG"
echo "Applying org baseline to $ORG"

echo "== Members: no default repo access; only owners create repos and Pages"
gh api -X PATCH "$O" \
  -f default_repository_permission=none \
  -F members_can_create_repositories=false \
  -F members_can_create_public_repositories=false \
  -F members_can_create_private_repositories=false \
  -F members_can_create_pages=false \
  -F members_can_create_public_pages=false \
  -F members_can_create_private_pages=false \
  -F members_can_fork_private_repositories=false >/dev/null

echo "== Actions: GitHub-owned only, SHA pinning required, read-only token"
gh api -X PUT "$O/actions/permissions" -f enabled_repositories=all -f allowed_actions=selected -F sha_pinning_required=true
gh api -X PUT "$O/actions/permissions/selected-actions" -F github_owned_allowed=true -F verified_allowed=false
gh api -X PUT "$O/actions/permissions/workflow" -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT "$O/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors

echo "== Current state:"
gh api "$O" --jq '{two_factor_requirement_enabled, default_repository_permission, members_can_create_repositories, members_can_delete_repositories, members_can_change_repo_visibility, members_can_invite_outside_collaborators}'
gh api "$O/actions/permissions"

cat <<EOF
== Browser-only (github.com/organizations/$ORG/settings):
   Authentication security → require 2FA, secure methods only
     (check every member has 2FA first, without SMS, or they lose access)
   Member privileges → turn off repo deletion/transfer, visibility changes,
     inviting outside collaborators, team creation, discussions by readers
   Third-party access → restrict OAuth app access
   GitHub Apps → scope each app to selected repos only
   Verified and approved domains → verify your domain
Done.
EOF
