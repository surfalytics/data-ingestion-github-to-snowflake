#!/usr/bin/env bash
# Store a GitHub token in AWS Secrets Manager for use with resolve_github_token() in Python.
#
# Token source (first match wins):
#   1) First argument
#   2) GITHUB_TOKEN_TO_STORE env
#   3) gh auth token (current gh login)
#
# Usage:
#   export AWS_REGION=us-east-1
#   ./push-github-token-to-secrets-manager.sh
#   ./push-github-token-to-secrets-manager.sh "ghp_xxxx"
#
# For a repo-scoped token, create a fine-grained PAT at:
#   https://github.com/settings/tokens?type=beta
#   Repository: surfalytics/data-ingestion-github-to-snowflake
#   Permissions: e.g. Contents (read), Metadata (read).

set -euo pipefail

SECRET_NAME="${GITHUB_TOKEN_SECRET_NAME:-surfalytics/data-ingestion/github-token}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

TOKEN="${1:-}"
if [[ -z "${TOKEN}" ]]; then
  TOKEN="${GITHUB_TOKEN_TO_STORE:-}"
fi
if [[ -z "${TOKEN}" ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "No token provided and gh not found. Pass token as arg or set GITHUB_TOKEN_TO_STORE." >&2
    exit 1
  fi
  TOKEN="$(gh auth token)"
fi

if [[ -z "${TOKEN}" ]]; then
  echo "Token is empty." >&2
  exit 1
fi

export AWS_DEFAULT_REGION="${REGION}"

if aws secretsmanager describe-secret --secret-id "${SECRET_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  aws secretsmanager put-secret-value \
    --secret-id "${SECRET_NAME}" \
    --secret-string "${TOKEN}" \
    --region "${REGION}"
  echo "Updated secret: ${SECRET_NAME} (${REGION})"
else
  aws secretsmanager create-secret \
    --name "${SECRET_NAME}" \
    --secret-string "${TOKEN}" \
    --region "${REGION}" \
    --description "GitHub PAT for surfalytics/data-ingestion-github-to-snowflake (API access)"
  echo "Created secret: ${SECRET_NAME} (${REGION})"
fi

echo "In Python or your runtime, set:"
echo "  export GITHUB_TOKEN_SECRET_NAME=${SECRET_NAME}"
echo "  export AWS_REGION=${REGION}"
