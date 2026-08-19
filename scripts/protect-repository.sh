#!/usr/bin/env bash
set -euo pipefail

readonly repository="KandlerLi/dyndns"
readonly owner="KandlerLi"
readonly owner_id="24520951"
readonly branch="main"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI is required: https://cli.github.com/"
  exit 1
fi

authenticated_user="$(gh api user --jq '.login')"
if [[ "$authenticated_user" != "$owner" ]]; then
  echo "Refusing to continue: authenticated as $authenticated_user, expected $owner."
  exit 1
fi

if [[ "$(gh api "repos/$repository" --jq '.permissions.admin')" != "true" ]]; then
  echo "Refusing to continue: $owner is not an administrator of $repository."
  exit 1
fi

echo "Removing every explicit collaborator except $owner..."
while IFS= read -r collaborator; do
  [[ -z "$collaborator" || "$collaborator" == "$owner" ]] && continue
  gh api --method DELETE "repos/$repository/collaborators/$collaborator"
  echo "Removed collaborator: $collaborator"
done < <(gh api --paginate "repos/$repository/collaborators?affiliation=direct&per_page=100" --jq '.[].login')

echo "Restricting repository and pull-request behavior..."
gh api --method PATCH "repos/$repository" \
  -F has_wiki=false \
  -F allow_auto_merge=false \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F allow_squash_merge=true \
  -F allow_update_branch=true \
  -F delete_branch_on_merge=true \
  -f pull_request_creation_policy=collaborators_only \
  --silent

echo "Restricting GitHub Actions permissions..."
gh api --method PUT "repos/$repository/actions/permissions" \
  -F enabled=true \
  -f allowed_actions=selected \
  --silent

gh api --method PUT "repos/$repository/actions/permissions/selected-actions" \
  --input - --silent <<'JSON'
{
  "github_owned_allowed": false,
  "verified_allowed": false,
  "patterns_allowed": [
    "actions/checkout@*",
    "aws-actions/configure-aws-credentials@*",
    "hashicorp/setup-terraform@*"
  ]
}
JSON

gh api --method PUT "repos/$repository/actions/permissions/workflow" \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false \
  --silent

echo "Creating a production approval gate for AWS deployments..."
gh api --method PUT "repos/$repository/environments/production" \
  --input - --silent <<JSON
{
  "wait_timer": 0,
  "prevent_self_review": false,
  "reviewers": [
    {"type": "User", "id": $owner_id}
  ],
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
JSON

echo "Protecting $branch and requiring PRs, CI, and owner authorization..."
gh api --method PUT "repos/$repository/branches/$branch/protection" \
  --input - --silent <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Owner approval",
      "Validate",
      "Terraform plan"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": false,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0,
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true,
  "lock_branch": false,
  "allow_fork_syncing": false
}
JSON

gh api --method POST "repos/$repository/branches/$branch/protection/required_signatures" --silent
gh api --method PUT "repos/$repository/vulnerability-alerts" --silent

echo
echo "Repository protection is active."
echo "For each PR, wait for Validate and Terraform plan, then comment exactly: /approve"
echo "After merge, approve the production deployment before Terraform receives AWS credentials."
echo
echo "Review these remaining credentials/integrations manually:"
gh api "repos/$repository/keys" --jq '.[] | "deploy key: \(.title) (read_only=\(.read_only))"'
gh api "repos/$repository/hooks" --jq '.[] | "webhook: \(.config.url) (active=\(.active))"'
gh api "repos/$repository/installations" --jq '.installations[] | "GitHub App: \(.app_slug)"'
