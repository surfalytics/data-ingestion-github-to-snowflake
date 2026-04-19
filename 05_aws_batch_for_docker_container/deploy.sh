#!/usr/bin/env bash
# Build the Docker image, push to ECR, and register a new Batch job definition revision.
#
# Usage:
#   bash deploy.sh            # build + push + register
#   bash deploy.sh --submit   # also submit a test job after registering
#
# Optional env vars (override defaults):
#   AWS_REGION     (default: us-east-1)
#   S3_BUCKET      (default: surfalytics-raw-csv-180795190369)
#   TARGET_ROWS    (default: 1000)
#   AWS_ACCOUNT    (auto-detected via STS if not set)
set -euo pipefail

PROFILE="surfalytics-lab"
REGION="${AWS_REGION:-us-east-1}"
S3_BUCKET="${S3_BUCKET:-surfalytics-raw-csv-180795190369}"
TARGET_ROWS="${TARGET_ROWS:-1000}"
ECR_REPO_NAME="surfalytics-github-ingest"
JOB_DEFINITION_NAME="surfalytics-github-ingest-job"
JOB_QUEUE_NAME="surfalytics-github-ingest-queue"
ROLE_NAME="surfalytics-lambda-github-role"
SUBMIT="${1:-}"

export AWS_REGION="$REGION"

# ── Step 1: Resolve AWS account ID ────────────────────────────────────────────
echo ">>> Resolving AWS account ID..."
ACCOUNT_ID="${AWS_ACCOUNT:-}"
if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID=$(aws sts get-caller-identity \
    --profile "$PROFILE" \
    --query 'Account' --output text)
fi
echo "    Account: $ACCOUNT_ID"

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
FULL_IMAGE="${ECR_REGISTRY}/${ECR_REPO_NAME}:latest"

# ── Step 2: Build Docker image ─────────────────────────────────────────────────
echo ">>> Building Docker image (linux/amd64 for Fargate)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker build --platform linux/amd64 -t "${ECR_REPO_NAME}:latest" "$SCRIPT_DIR"

# ── Step 3: Authenticate to ECR ────────────────────────────────────────────────
echo ">>> Authenticating to ECR ($REGION)..."
aws ecr get-login-password \
  --profile "$PROFILE" \
  --region "$REGION" \
  | docker login \
      --username AWS \
      --password-stdin "$ECR_REGISTRY"

# ── Step 4: Tag and push ────────────────────────────────────────────────────────
echo ">>> Pushing $FULL_IMAGE ..."
docker tag "${ECR_REPO_NAME}:latest" "$FULL_IMAGE"
docker push "$FULL_IMAGE"
echo "    Pushed: $FULL_IMAGE"

# ── Step 5: Construct execution role ARN ───────────────────────────────────────
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "    Role: $ROLE_ARN"

# ── Step 6: Register new job definition revision ────────────────────────────────
echo ">>> Registering new Batch job definition revision..."
JOB_DEF_ARN=$(aws batch register-job-definition \
  --profile "$PROFILE" \
  --region "$REGION" \
  --job-definition-name "$JOB_DEFINITION_NAME" \
  --type container \
  --platform-capabilities FARGATE \
  --container-properties "{
    \"image\": \"$FULL_IMAGE\",
    \"executionRoleArn\": \"$ROLE_ARN\",
    \"jobRoleArn\": \"$ROLE_ARN\",
    \"resourceRequirements\": [
      {\"type\": \"VCPU\", \"value\": \"0.5\"},
      {\"type\": \"MEMORY\", \"value\": \"1024\"}
    ],
    \"command\": [\"--target-rows\", \"$TARGET_ROWS\"],
    \"environment\": [
      {\"name\": \"AWS_REGION\", \"value\": \"$REGION\"},
      {\"name\": \"S3_BUCKET\", \"value\": \"$S3_BUCKET\"},
      {\"name\": \"S3_PREFIX\", \"value\": \"github-data\"},
      {\"name\": \"GITHUB_TOKEN_SECRET_NAME\", \"value\": \"surfalytics/data-ingestion/github-token\"}
    ],
    \"logConfiguration\": {
      \"logDriver\": \"awslogs\",
      \"options\": {
        \"awslogs-group\": \"/aws/batch/surfalytics-github-ingest\",
        \"awslogs-region\": \"$REGION\",
        \"awslogs-stream-prefix\": \"batch\"
      }
    },
    \"networkConfiguration\": {\"assignPublicIp\": \"ENABLED\"},
    \"fargatePlatformConfiguration\": {\"platformVersion\": \"LATEST\"}
  }" \
  --query 'jobDefinitionArn' --output text)

echo "    Registered: $JOB_DEF_ARN"

# ── Step 7 (optional): Submit test job ─────────────────────────────────────────
if [[ "$SUBMIT" == "--submit" ]]; then
  echo ">>> Submitting test job..."
  JOB_ID=$(aws batch submit-job \
    --profile "$PROFILE" \
    --region "$REGION" \
    --job-name "surfalytics-github-ingest-test-$(date +%Y%m%d-%H%M%S)" \
    --job-queue "$JOB_QUEUE_NAME" \
    --job-definition "$JOB_DEF_ARN" \
    --query 'jobId' --output text)
  echo "    Job submitted: $JOB_ID"
  echo ""
  echo "    Monitor: aws batch describe-jobs --jobs $JOB_ID --profile $PROFILE | jq '.jobs[0].status'"
  echo "    Logs:    aws logs tail /aws/batch/surfalytics-github-ingest --follow --profile $PROFILE"
fi

echo ""
echo "Done."
echo "  ECR image:       $FULL_IMAGE"
echo "  Job definition:  $JOB_DEF_ARN"
echo "  Job queue:       $JOB_QUEUE_NAME"
echo ""
echo "Submit a job:"
echo "  bash submit_job.sh"
echo "  bash submit_job.sh --target-rows 100 --wait"
