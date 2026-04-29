#!/usr/bin/env bash
# Submit a Lambda-invoker Batch job.
# The job runs the public AWS CLI image on Fargate and invokes the SLS Lambda synchronously.
#
# Usage:
#   bash submit_lambda_job.sh
#   bash submit_lambda_job.sh --target-rows 500
#   bash submit_lambda_job.sh --target-rows 500 --wait
#
# Flags:
#   --target-rows N    Number of repos to pass to the Lambda (default: 1000)
#   --job-name NAME    Batch job name (default: auto-generated with timestamp)
#   --wait             Poll until the job completes and print final status
set -euo pipefail

PROFILE="surfalytics-lab"
REGION="${AWS_REGION:-us-east-1}"
JOB_QUEUE="surfalytics-github-ingest-queue"
JOB_DEFINITION="surfalytics-lambda-invoker-job"
LAMBDA_FN="surfalytics-github-ingest-sls-dev"
TARGET_ROWS="1000"
JOB_NAME="surfalytics-lambda-invoker-$(date +%Y%m%d-%H%M%S)"
WAIT_FOR_COMPLETION="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-rows) TARGET_ROWS="$2"; shift 2 ;;
    --job-name)    JOB_NAME="$2";    shift 2 ;;
    --wait)        WAIT_FOR_COMPLETION="true"; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

COMMAND_OVERRIDE="[\"lambda\",\"invoke\",\"--function-name\",\"${LAMBDA_FN}\",\"--region\",\"${REGION}\",\"--invocation-type\",\"RequestResponse\",\"--cli-binary-format\",\"raw-in-base64-out\",\"--payload\",\"{\\\"target_rows\\\": ${TARGET_ROWS}}\",\"/tmp/response.json\"]"

echo ">>> Submitting Lambda-invoker Batch job: $JOB_NAME"
echo "    Queue:          $JOB_QUEUE"
echo "    Job definition: $JOB_DEFINITION"
echo "    Lambda:         $LAMBDA_FN"
echo "    Target rows:    $TARGET_ROWS"

JOB_ID=$(aws batch submit-job \
  --profile "$PROFILE" \
  --region "$REGION" \
  --job-name "$JOB_NAME" \
  --job-queue "$JOB_QUEUE" \
  --job-definition "$JOB_DEFINITION" \
  --container-overrides "{\"command\": ${COMMAND_OVERRIDE}}" \
  --query 'jobId' --output text)

echo ""
echo "Job submitted: $JOB_ID"
echo ""
echo "Monitor status:"
echo "  aws batch describe-jobs --jobs $JOB_ID --profile $PROFILE --query 'jobs[0].status'"
echo ""
echo "Stream logs (once RUNNING):"
echo "  aws logs tail /aws/batch/surfalytics-lambda-invoker --follow --profile $PROFILE"

if [[ "$WAIT_FOR_COMPLETION" == "true" ]]; then
  echo ""
  echo ">>> Waiting for job $JOB_ID to complete..."
  while true; do
    STATUS=$(aws batch describe-jobs \
      --profile "$PROFILE" \
      --region "$REGION" \
      --jobs "$JOB_ID" \
      --query 'jobs[0].status' --output text)
    echo "    Status: $STATUS"
    case "$STATUS" in
      SUCCEEDED) echo "Job succeeded."; break ;;
      FAILED)    echo "Job FAILED. Check logs above."; exit 1 ;;
      *)         sleep 15 ;;
    esac
  done
fi
