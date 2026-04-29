#!/usr/bin/env bash
# Mirror public.ecr.aws/aws-cli/aws-cli:latest into the private ECR repo as the
# :aws-cli tag. Required because the Fargate subnet used by the Batch stack
# cannot resolve public.ecr.aws, but can pull from private ECR via the AWS
# internal network.
#
# The surfalytics-lambda-invoker-job Batch job definition references this tag.
# Run once after the batch stack is created, or whenever you want a fresh
# AWS CLI version.
#
# Usage:
#   bash infrastructure/scripts/mirror-aws-cli-image.sh
#
# Optional env vars:
#   AWS_PROFILE     profile that can push to ECR (default: local)
#   AWS_REGION      target region                (default: us-east-1)
#   ECR_REPO_NAME   private ECR repo name        (default: surfalytics-github-ingest)
set -euo pipefail

PROFILE="${AWS_PROFILE:-local}"
REGION="${AWS_REGION:-us-east-1}"
ECR_REPO_NAME="${ECR_REPO_NAME:-surfalytics-github-ingest}"
SOURCE_IMAGE="public.ecr.aws/aws-cli/aws-cli:latest"

ACCOUNT_ID=$(aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" \
  --query 'Account' --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
TARGET_IMAGE="${ECR_REGISTRY}/${ECR_REPO_NAME}:aws-cli"

echo ">>> Mirroring $SOURCE_IMAGE -> $TARGET_IMAGE"

echo "    Pulling $SOURCE_IMAGE ..."
docker pull --platform linux/amd64 "$SOURCE_IMAGE"

echo "    Authenticating to ECR ($REGION)..."
aws ecr get-login-password --profile "$PROFILE" --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "    Tagging and pushing..."
docker tag "$SOURCE_IMAGE" "$TARGET_IMAGE"
docker push "$TARGET_IMAGE"

echo ""
echo "Done: $TARGET_IMAGE"
