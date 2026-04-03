#!/usr/bin/env bash
# Deploy S3 + IAM stack. Requires an AWS profile with CloudFormation + IAM + S3
# permissions (often your personal/admin user — not necessarily the ingestion user).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/../cloudformation/raw-csv-s3-stack.yaml"

PROFILE="${AWS_PROFILE:-local}"
REGION="${AWS_REGION:-${1:-us-east-1}}"
STACK_NAME="${STACK_NAME:-surfalytics-raw-csv}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Template not found: $TEMPLATE" >&2
  exit 1
fi

echo "Profile: $PROFILE  Region: $REGION  Stack: $STACK_NAME"
aws cloudformation deploy \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "Stack outputs (save bucket name, region, and keys from the ingestion user):"
aws cloudformation describe-stacks \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table
