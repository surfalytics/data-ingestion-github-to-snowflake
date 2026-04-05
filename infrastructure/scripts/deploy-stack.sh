#!/usr/bin/env bash
# Deploy one of the three exercise CloudFormation stacks.
#
# Usage:
#   bash infrastructure/scripts/deploy-stack.sh 01   # Week 1 — Local Python
#   bash infrastructure/scripts/deploy-stack.sh 02   # Week 2 — Docker
#   bash infrastructure/scripts/deploy-stack.sh 03   # Week 3 — Lambda
#
# Optional env vars:
#   AWS_PROFILE  override the deploying profile (default: local)
#   AWS_REGION   override the target region    (default: us-east-1)
set -euo pipefail

WEEK="${1:-}"
if [[ -z "$WEEK" ]]; then
  echo "Usage: bash deploy-stack.sh <01|02|03>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${AWS_PROFILE:-local}"
REGION="${AWS_REGION:-us-east-1}"

case "$WEEK" in
  01) STACK_NAME="surfalytics-01-local";  TEMPLATE="${SCRIPT_DIR}/../cloudformation/01_local_python.yaml" ;;
  02) STACK_NAME="surfalytics-02-docker"; TEMPLATE="${SCRIPT_DIR}/../cloudformation/02_docker.yaml" ;;
  03) STACK_NAME="surfalytics-03-lambda"; TEMPLATE="${SCRIPT_DIR}/../cloudformation/03_lambda.yaml" ;;
  *)  echo "Unknown week '$WEEK'. Use 01, 02, or 03." >&2; exit 1 ;;
esac

echo "Profile: $PROFILE  Stack: $STACK_NAME  Region: $REGION"
echo "Template: $(basename "$TEMPLATE")"
echo ""

aws cloudformation deploy \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table
