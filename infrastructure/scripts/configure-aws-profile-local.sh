#!/usr/bin/env bash
# Writes ~/.aws/credentials and ~/.aws/config for profile "local" (or PROFILE)
# using values from CloudFormation stack outputs. Run after deploy-raw-csv-stack.sh.
set -euo pipefail

PROFILE="${PROFILE:-local}"
DEPLOY_PROFILE="${DEPLOY_PROFILE:-$PROFILE}"
REGION="${AWS_REGION:-${1:-us-east-1}}"
STACK_NAME="${STACK_NAME:-surfalytics-raw-csv}"

key_id=$(aws cloudformation describe-stacks \
  --profile "$DEPLOY_PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='IngestionAccessKeyId'].OutputValue | [0]" \
  --output text)

secret=$(aws cloudformation describe-stacks \
  --profile "$DEPLOY_PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='IngestionSecretAccessKey'].OutputValue | [0]" \
  --output text)

stack_region=$(aws cloudformation describe-stacks \
  --profile "$DEPLOY_PROFILE" \
  --region "$REGION" \
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
aws configure set region "${stack_region:-$REGION}" --profile "$PROFILE"

echo "Updated AWS CLI profile: $PROFILE"
echo "Region set to: $(aws configure get region --profile "$PROFILE")"
echo "Test: aws sts get-caller-identity --profile $PROFILE"
