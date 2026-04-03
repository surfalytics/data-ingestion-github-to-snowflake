#!/usr/bin/env bash
# Creates/updates a dedicated lab profile with the ingestion user's keys from stack
# outputs. Stack metadata is read with DEPLOY_PROFILE (default: local — whoever
# deployed the stack). Run after deploy-raw-csv-stack.sh.
set -euo pipefail

PROFILE="${PROFILE:-surfalytics-lab}"
DEPLOY_PROFILE="${DEPLOY_PROFILE:-local}"
STACK_NAME="${STACK_NAME:-surfalytics-raw-csv}"

REGION_ARGS=()
if [[ -n "${AWS_REGION:-}" ]]; then
  REGION_ARGS=(--region "$AWS_REGION")
elif [[ -n "${1:-}" ]]; then
  REGION_ARGS=(--region "$1")
fi

key_id=$(aws cloudformation describe-stacks \
  --profile "$DEPLOY_PROFILE" \
  "${REGION_ARGS[@]}" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='IngestionAccessKeyId'].OutputValue | [0]" \
  --output text)

secret=$(aws cloudformation describe-stacks \
  --profile "$DEPLOY_PROFILE" \
  "${REGION_ARGS[@]}" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='IngestionSecretAccessKey'].OutputValue | [0]" \
  --output text)

stack_region=$(aws cloudformation describe-stacks \
  --profile "$DEPLOY_PROFILE" \
  "${REGION_ARGS[@]}" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='AwsRegion'].OutputValue | [0]" \
  --output text)

if [[ -z "$key_id" || "$key_id" == "None" || -z "$secret" || "$secret" == "None" ]]; then
  echo "Could not read access key outputs from stack $STACK_NAME." >&2
  echo "Secret is only available immediately after the AccessKey resource is created;" >&2
  echo "if the stack was updated without replacing the key, create a new key in IAM" >&2
  echo "or delete/recreate the stack." >&2
  exit 1
fi

aws configure set aws_access_key_id "$key_id" --profile "$PROFILE"
aws configure set aws_secret_access_key "$secret" --profile "$PROFILE"
aws configure set region "$stack_region" --profile "$PROFILE"

echo "Configured lab profile: $PROFILE (stack read with --profile $DEPLOY_PROFILE)"
echo "Region: $(aws configure get region --profile "$PROFILE")"
echo "Test: aws sts get-caller-identity --profile $PROFILE"
