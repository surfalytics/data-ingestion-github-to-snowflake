#!/usr/bin/env bash
# Deploy S3 + IAM stack. Requires an AWS profile with CloudFormation + IAM + S3
# permissions (often your personal/admin user — not necessarily the ingestion user).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../cloudformation/raw-csv-s3-stack.yaml"

PROFILE="${AWS_PROFILE:-local}"
STACK_NAME="${STACK_NAME:-surfalytics-raw-csv}"

REGION_ARGS=()
if [[ -n "${AWS_REGION:-}" ]]; then
  REGION_ARGS=(--region "$AWS_REGION")
elif [[ -n "${1:-}" ]]; then
  REGION_ARGS=(--region "$1")
fi

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE" >&2
  exit 1
fi

if ((${#REGION_ARGS[@]} > 0)); then
  echo "Profile: $PROFILE  Stack: $STACK_NAME  ${REGION_ARGS[*]}"
else
  echo "Profile: $PROFILE  Stack: $STACK_NAME  (region from profile config)"
fi
aws cloudformation deploy \
  --profile "$PROFILE" \
  "${REGION_ARGS[@]}" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "Stack outputs (save bucket name, region, and keys from the ingestion user):"
aws cloudformation describe-stacks \
  --profile "$PROFILE" \
  "${REGION_ARGS[@]}" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table
