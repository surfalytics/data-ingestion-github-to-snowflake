#!/usr/bin/env bash
# Remove a Lambda function's custom KMS key and force its environment
# variables to be re-encrypted with the default AWS-managed key
# (aws/lambda). Use when a Lambda's env vars are locked behind a CMK that
# the execution role cannot decrypt (KMSAccessDeniedException at invoke).
#
# Workflow:
#   1. Unset the function's KMSKeyArn (so new writes use the default key)
#   2. Clear the environment variables (removes the stuck encrypted blob)
#   3. Re-apply the original environment variables, now encrypted with
#      the default key
#
# Usage:
#   bash infrastructure/scripts/fix-lambda-env-kms.sh <function-name>
#
# Optional env vars:
#   AWS_PROFILE  profile with lambda:UpdateFunctionConfiguration (default: local)
#   AWS_REGION   region                                          (default: us-east-1)
set -euo pipefail

FN_NAME="${1:-}"
if [[ -z "$FN_NAME" ]]; then
  echo "Usage: bash fix-lambda-env-kms.sh <function-name>" >&2
  exit 1
fi

PROFILE="${AWS_PROFILE:-local}"
REGION="${AWS_REGION:-us-east-1}"

echo ">>> Reading current configuration for $FN_NAME ..."
ENV_JSON=$(aws lambda get-function-configuration \
  --function-name "$FN_NAME" \
  --profile "$PROFILE" --region "$REGION" \
  --query 'Environment.Variables' --output json)
echo "    Current env vars:"
echo "$ENV_JSON" | sed 's/^/      /'

echo ""
echo ">>> Step 1/3: Unsetting KMSKeyArn ..."
aws lambda update-function-configuration \
  --function-name "$FN_NAME" \
  --kms-key-arn "" \
  --profile "$PROFILE" --region "$REGION" \
  --output text --query 'LastUpdateStatus' >/dev/null
aws lambda wait function-updated \
  --function-name "$FN_NAME" \
  --profile "$PROFILE" --region "$REGION"

echo ">>> Step 2/3: Clearing env vars to drop the stuck encrypted blob ..."
aws lambda update-function-configuration \
  --function-name "$FN_NAME" \
  --environment 'Variables={}' \
  --profile "$PROFILE" --region "$REGION" \
  --output text --query 'LastUpdateStatus' >/dev/null
aws lambda wait function-updated \
  --function-name "$FN_NAME" \
  --profile "$PROFILE" --region "$REGION"

echo ">>> Step 3/3: Re-applying env vars (re-encrypted with default key) ..."
# Rebuild the Variables=key=val,key=val form from the captured JSON.
ENV_ARG=$(echo "$ENV_JSON" \
  | python3 -c 'import json,sys; v=json.load(sys.stdin) or {}; print("Variables={"+",".join(f"{k}={v[k]}" for k in v)+"}")')
aws lambda update-function-configuration \
  --function-name "$FN_NAME" \
  --environment "$ENV_ARG" \
  --profile "$PROFILE" --region "$REGION" \
  --output text --query 'LastUpdateStatus' >/dev/null
aws lambda wait function-updated \
  --function-name "$FN_NAME" \
  --profile "$PROFILE" --region "$REGION"

KMS_NOW=$(aws lambda get-function-configuration \
  --function-name "$FN_NAME" \
  --profile "$PROFILE" --region "$REGION" \
  --query 'KMSKeyArn' --output text)

echo ""
echo "Done. $FN_NAME now uses KMSKeyArn=${KMS_NOW} (None = default aws/lambda key)."
