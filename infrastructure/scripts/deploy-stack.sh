#!/usr/bin/env bash
# Deploy CloudFormation stacks for the surfalytics data ingestion pipeline.
#
# Usage:
#   bash infrastructure/scripts/deploy-stack.sh iam         # IAM policies + execution role
#   bash infrastructure/scripts/deploy-stack.sh serverless  # Serverless Framework deploy permissions
#   bash infrastructure/scripts/deploy-stack.sh batch       # AWS Batch infrastructure (ECR, compute env, job queue)
#
# Optional env vars:
#   AWS_PROFILE      override the deploying profile (default: local)
#   AWS_REGION       override the target region    (default: us-east-1)
#   IAM_STACK_NAME   IAM stack name imported by the batch stack (default: surfalytics-iam)
#
# batch requires two extra env vars:
#   BATCH_SUBNET_ID  subnet for the Fargate compute environment
#   BATCH_SG_ID      security group for the Fargate compute environment
#
# Example — get default VPC values:
#   BATCH_SUBNET_ID=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
#     --query 'Subnets[0].SubnetId' --output text --profile local)
#   BATCH_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=default \
#     --query 'SecurityGroups[0].GroupId' --output text --profile local)
set -euo pipefail

SERVICE="${1:-}"
if [[ -z "$SERVICE" ]]; then
  echo "Usage: bash deploy-stack.sh <iam|serverless|batch>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${AWS_PROFILE:-local}"
REGION="${AWS_REGION:-us-east-1}"
PARAM_OVERRIDES=""

case "$SERVICE" in
  iam)
    STACK_NAME="surfalytics-iam"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/iam.yaml"
    ;;
  serverless)
    STACK_NAME="surfalytics-serverless"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/serverless.yaml"
    ;;
  batch)
    STACK_NAME="surfalytics-batch"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/batch.yaml"
    if [[ -z "${BATCH_SUBNET_ID:-}" || -z "${BATCH_SG_ID:-}" ]]; then
      echo "batch requires BATCH_SUBNET_ID and BATCH_SG_ID. Get them with:" >&2
      echo "  BATCH_SUBNET_ID=\$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \\" >&2
      echo "    --query 'Subnets[0].SubnetId' --output text --profile local)" >&2
      echo "  BATCH_SG_ID=\$(aws ec2 describe-security-groups --filters Name=group-name,Values=default \\" >&2
      echo "    --query 'SecurityGroups[0].GroupId' --output text --profile local)" >&2
      exit 1
    fi
    IAM_STACK="${IAM_STACK_NAME:-surfalytics-iam}"
    PARAM_OVERRIDES="BatchSubnetId=${BATCH_SUBNET_ID} BatchSecurityGroupId=${BATCH_SG_ID} IAMStackName=${IAM_STACK}"
    ;;
  *)
    echo "Unknown service '${SERVICE}'. Use: iam, serverless, or batch." >&2
    exit 1
    ;;
esac

echo "Profile: $PROFILE  Stack: $STACK_NAME  Region: $REGION"
echo "Template: $(basename "$TEMPLATE")"
echo ""

aws cloudformation deploy \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --capabilities CAPABILITY_NAMED_IAM \
  ${PARAM_OVERRIDES:+--parameter-overrides $PARAM_OVERRIDES}

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table
