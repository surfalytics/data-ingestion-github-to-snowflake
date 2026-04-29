#!/usr/bin/env bash
# Deploy CloudFormation stacks for the surfalytics data ingestion pipeline.
#
# Usage:
#   bash infrastructure/scripts/deploy-stack.sh iam           # IAM policies + execution role
#   bash infrastructure/scripts/deploy-stack.sh serverless    # Serverless Framework deploy permissions
#   bash infrastructure/scripts/deploy-stack.sh batch         # AWS Batch infrastructure (ECR, compute env, job queue)
#   bash infrastructure/scripts/deploy-stack.sh stepfunctions # Step Functions pipeline (GitHub ingest Lambda)
#   bash infrastructure/scripts/deploy-stack.sh ecs           # ECS Fargate cluster + task definition
#   bash infrastructure/scripts/deploy-stack.sh eventbridge  # EventBridge schedule → StartExecution on that state machine
#
# Optional env vars:
#   AWS_PROFILE      override the deploying profile (default: local)
#   AWS_REGION       override the target region    (default: us-east-1)
#   IAM_STACK_NAME   IAM stack name imported by the batch stack (default: surfalytics-iam)
#
# batch optional env vars (auto-discovered from default VPC in $AWS_REGION when unset):
#   BATCH_SUBNET_ID  subnet for the Fargate compute environment
#   BATCH_SG_ID      security group for the Fargate compute environment
#
# stepfunctions optional env vars (subnet/SG auto-discovered from default VPC when unset):
#   GITHUB_INGEST_FUNCTION_NAME  Lambda function name (default: surfalytics-github-ingest)
#   ECS_STACK_NAME               ECS stack name imported for cluster/task def (default: surfalytics-ecs)
#   ECS_SUBNET_ID                subnet for the ECS task in the full-pipeline state machine
#   ECS_SG_ID                    security group for the ECS task in the full-pipeline state machine
#
# eventbridge optional env vars:
#   STATE_MACHINE_ARN        full ARN; if unset, template uses StateMachineName in this account/region
#   STATE_MACHINE_NAME       default surfalytics-github-ingest-pipeline
#   SCHEDULE_EXPRESSION      default cron(0 6 * * ? *) (06:00 UTC daily)
#   SCHEDULE_INPUT           JSON for StartExecution (default {"target_rows":100})
#
# iam optional env var:
#   LAMBDA_ENV_KMS_KEY_ID  KMS key ID or ARN for CMK-encrypted Lambda env vars; creates a KMS grant
set -euo pipefail

SERVICE="${1:-}"
if [[ -z "$SERVICE" ]]; then
  echo "Usage: bash deploy-stack.sh <iam|serverless|batch|ecs|stepfunctions|eventbridge>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${AWS_PROFILE:-local}"
REGION="${AWS_REGION:-us-east-1}"
DEPLOY_OVERRIDES=()

case "$SERVICE" in
  iam)
    STACK_NAME="surfalytics-iam"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/iam.yaml"
    if [[ -n "${LAMBDA_ENV_KMS_KEY_ID:-}" ]]; then
      DEPLOY_OVERRIDES+=("LambdaEnvironmentKmsKeyId=${LAMBDA_ENV_KMS_KEY_ID}")
    fi
    ;;
  serverless)
    STACK_NAME="surfalytics-serverless"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/serverless.yaml"
    ;;
  batch)
    STACK_NAME="surfalytics-batch"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/batch.yaml"
    # Auto-discover default-VPC subnet and SG in the target REGION.
    # Prevents region-mismatch bugs when the AWS profile's default region
    # differs from the stack's deploy region.
    if [[ -z "${BATCH_SUBNET_ID:-}" ]]; then
      BATCH_SUBNET_ID=$(aws ec2 describe-subnets \
        --profile "$PROFILE" --region "$REGION" \
        --filters Name=default-for-az,Values=true \
        --query 'Subnets[0].SubnetId' --output text)
      echo "Auto-discovered subnet in $REGION: $BATCH_SUBNET_ID"
    fi
    if [[ -z "${BATCH_SG_ID:-}" ]]; then
      BATCH_SG_ID=$(aws ec2 describe-security-groups \
        --profile "$PROFILE" --region "$REGION" \
        --filters Name=group-name,Values=default \
        --query 'SecurityGroups[0].GroupId' --output text)
      echo "Auto-discovered security group in $REGION: $BATCH_SG_ID"
    fi
    if [[ -z "$BATCH_SUBNET_ID" || "$BATCH_SUBNET_ID" == "None" || \
          -z "$BATCH_SG_ID" || "$BATCH_SG_ID" == "None" ]]; then
      echo "Failed to resolve default subnet/SG in $REGION. Set BATCH_SUBNET_ID and BATCH_SG_ID explicitly." >&2
      exit 1
    fi
    IAM_STACK="${IAM_STACK_NAME:-surfalytics-iam}"
    DEPLOY_OVERRIDES=(
      "BatchSubnetId=${BATCH_SUBNET_ID}"
      "BatchSecurityGroupId=${BATCH_SG_ID}"
      "IAMStackName=${IAM_STACK}"
    )
    ;;
  stepfunctions)
    STACK_NAME="surfalytics-stepfunctions"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/step-functions.yaml"
    if [[ -n "${GITHUB_INGEST_FUNCTION_NAME:-}" ]]; then
      DEPLOY_OVERRIDES+=("GitHubIngestFunctionName=${GITHUB_INGEST_FUNCTION_NAME}")
    fi
    if [[ -n "${ECS_STACK_NAME:-}" ]]; then
      DEPLOY_OVERRIDES+=("EcsStackName=${ECS_STACK_NAME}")
    fi
    # Same auto-discovery as batch: keeps subnet/SG in the target REGION.
    if [[ -z "${ECS_SUBNET_ID:-}" ]]; then
      ECS_SUBNET_ID=$(aws ec2 describe-subnets \
        --profile "$PROFILE" --region "$REGION" \
        --filters Name=default-for-az,Values=true \
        --query 'Subnets[0].SubnetId' --output text)
      echo "Auto-discovered ECS subnet in $REGION: $ECS_SUBNET_ID"
    fi
    if [[ -z "${ECS_SG_ID:-}" ]]; then
      ECS_SG_ID=$(aws ec2 describe-security-groups \
        --profile "$PROFILE" --region "$REGION" \
        --filters Name=group-name,Values=default \
        --query 'SecurityGroups[0].GroupId' --output text)
      echo "Auto-discovered ECS security group in $REGION: $ECS_SG_ID"
    fi
    DEPLOY_OVERRIDES+=("EcsSubnetId=${ECS_SUBNET_ID}")
    DEPLOY_OVERRIDES+=("EcsSecurityGroupId=${ECS_SG_ID}")
    ;;
  ecs)
    STACK_NAME="surfalytics-ecs"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/ecs.yaml"
    ;;
  eventbridge)
    STACK_NAME="surfalytics-eventbridge-github-ingest"
    TEMPLATE="${SCRIPT_DIR}/../cloudformation/eventbridge-github-ingest-schedule.yaml"
    if [[ -n "${STATE_MACHINE_ARN:-}" ]]; then
      DEPLOY_OVERRIDES+=("StateMachineArn=${STATE_MACHINE_ARN}")
    fi
    if [[ -n "${STATE_MACHINE_NAME:-}" ]]; then
      DEPLOY_OVERRIDES+=("StateMachineName=${STATE_MACHINE_NAME}")
    fi
    if [[ -n "${SCHEDULE_EXPRESSION:-}" ]]; then
      DEPLOY_OVERRIDES+=("ScheduleExpression=${SCHEDULE_EXPRESSION}")
    fi
    if [[ -n "${SCHEDULE_INPUT:-}" ]]; then
      DEPLOY_OVERRIDES+=("ScheduleExecutionInput=${SCHEDULE_INPUT}")
    fi
    ;;
  *)
    echo "Unknown service '${SERVICE}'. Use: iam, serverless, batch, ecs, stepfunctions, or eventbridge." >&2
    exit 1
    ;;
esac

echo "Profile: $PROFILE  Stack: $STACK_NAME  Region: $REGION"
echo "Template: $(basename "$TEMPLATE")"
echo ""

DEPLOY_CMD=(
  aws cloudformation deploy
  --profile "$PROFILE"
  --region "$REGION"
  --stack-name "$STACK_NAME"
  --template-file "$TEMPLATE"
  --capabilities CAPABILITY_NAMED_IAM
)
if [[ ${#DEPLOY_OVERRIDES[@]} -gt 0 ]]; then
  DEPLOY_CMD+=(--parameter-overrides "${DEPLOY_OVERRIDES[@]}")
fi
"${DEPLOY_CMD[@]}"

echo ""
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --profile "$PROFILE" \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' \
  --output table
