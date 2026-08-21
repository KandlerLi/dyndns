#!/usr/bin/env bash
set -euo pipefail

# Everything about this repository's GitHub settings, branch protection, and
# Actions permissions that Terraform can manage now lives in
# /home/julian/projects/bootstrap/repo-infra instead of here (see
# home-infra-ai-context's decision "Infrastructure changes always go through
# IaC, never imperative commands"). This script only remains for the one
# setting the hashicorp/github Terraform provider has no resource for yet:
# pull_request_creation_policy (GitHub added this in Feb 2026; tracked as an
# unimplemented feature request against terraform-provider-github, issues
# #3251 and #3198). Collaborator pruning also stays here since no
# Terraform resource declares an authoritative empty collaborator set in
# this workspace today.

readonly repository="KandlerLi/dyndns"
readonly owner="KandlerLi"

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

echo "Restricting pull request creation to collaborators..."
gh api --method PATCH "repos/$repository" \
  -f pull_request_creation_policy=collaborators_only \
  --silent

echo
echo "Collaborator and pull-request-creation restrictions are active."
echo "Everything else (branch protection, Actions permissions, the"
echo "production environment) is managed by Terraform in"
echo "/home/julian/projects/bootstrap/repo-infra -- run terraform plan/apply"
echo "there for any change, not gh api commands here."
echo
echo "Review these remaining credentials/integrations manually:"
gh api "repos/$repository/keys" --jq '.[] | "deploy key: \(.title) (read_only=\(.read_only))"'
gh api "repos/$repository/hooks" --jq '.[] | "webhook: id=\(.id) (active=\(.active))"'
echo "GitHub Apps: https://github.com/$repository/settings/installations"
