# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Context

This is a **GitHub repository metadata extraction pipeline** built as part of the [Surfalytics async project 06](https://github.com/surfalytics/data-projects/tree/main/async-projects/06-data-ingestion-patterns). It demonstrates five progressive deployment patterns: local Python → Docker → AWS Lambda (CLI) → AWS Lambda (Serverless Framework) → AWS Batch (Fargate).

**Data flow**: GitHub API → 17 selected fields → CSV → S3 bucket (`github-data/github_repos_YYYYMMDD_HHMMSS.csv`)

**Design principle**: All weeks share the same IAM role (`surfalytics-lambda-github-role`) and user (`surfalytics-s3-ingestion`). CloudFormation templates are organized by AWS service, not by week number. IAM lives in `iam.yaml`; Batch infrastructure in `batch.yaml`; Serverless Framework extras in `serverless.yaml`.

## CloudFormation Templates

Templates are in `infrastructure/cloudformation/`, organized by service:

| Template | Stack name | What it creates |
|---|---|---|
| `iam.yaml` | `surfalytics-iam` | S3 policy, Secrets Manager policy, Lambda/ECR/Batch deploy policy, shared execution role |
| `serverless.yaml` | `surfalytics-serverless` | Extra CF + S3 + Lambda permissions for Serverless Framework deploys |
| `batch.yaml` | `surfalytics-batch` | ECR repo, Fargate compute environment, job queue, job definition |

Deploy order: `iam` first (exports the execution role ARN), then `batch`.

```bash
# Deploy IAM stack (required first)
bash infrastructure/scripts/deploy-stack.sh iam

# Deploy Batch stack (requires iam stack to exist)
BATCH_SUBNET_ID=$(aws ec2 describe-subnets --filters Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text --profile local)
BATCH_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text --profile local)
BATCH_SUBNET_ID=$BATCH_SUBNET_ID BATCH_SG_ID=$BATCH_SG_ID \
  bash infrastructure/scripts/deploy-stack.sh batch

# Deploy Serverless permissions (only if using Week 4 Serverless Framework)
bash infrastructure/scripts/deploy-stack.sh serverless
```

Stack requires `CAPABILITY_NAMED_IAM` (handled in the deploy script).

## AWS Setup

Infrastructure is managed via CloudFormation using the AWS CLI profile `local` (admin rights). The `local` profile creates the CF stacks. The restricted `surfalytics-s3-ingestion` IAM user (profile `surfalytics-lab`) runs the actual data ingestion.

**Store GitHub token in Secrets Manager:**
```bash
AWS_PROFILE=local bash infrastructure/scripts/push-github-token-to-secrets-manager.sh <token>
```

**Configure ingestion AWS profile from stack outputs:**
```bash
DEPLOY_PROFILE=local bash infrastructure/scripts/configure-lab-ingestion-profile.sh us-east-1
```

## Running the Pipeline

### Week 1 — Local Python
```bash
cd 01_local_python_development
source venv/bin/activate
python src/extract_github_data.py --dry-run --target-rows 100   # test without S3 upload
python src/extract_github_data.py --target-rows 1000            # full run
```

### Week 2 — Docker
```bash
cd 02_docker_container
cp .env.example .env   # fill in credentials
docker build -t surfalytics-github-ingest .
docker run --rm --env-file .env surfalytics-github-ingest --target-rows 1000
```

### Week 3 — AWS Lambda
```bash
cd 03_aws_lambda
bash deploy.sh   # packages + creates/updates Lambda function

aws --profile surfalytics-lab lambda invoke \
  --cli-binary-format raw-in-base64-out \
  --function-name surfalytics-github-ingest \
  --payload '{"target_rows": 1000}' response.json
```

### Week 4 — AWS Lambda (Serverless Framework)
```bash
cd 04_aws_lambda_serverless_deploy
npm install
npm run deploy

aws --profile surfalytics-lab lambda invoke \
  --cli-binary-format raw-in-base64-out \
  --function-name surfalytics-github-ingest-sls-dev \
  --payload '{"target_rows": 1000}' response.json
```

See [`04_aws_lambda_serverless_deploy/README.md`](04_aws_lambda_serverless_deploy/README.md) for `SLS_CF_STACK` config and removal instructions.

### Week 5 — AWS Batch (Fargate)
```bash
# One-time: deploy IAM + Batch stacks (see CloudFormation section above)

# Build + push container image + register job definition
cd 05_aws_batch_for_docker_container
bash deploy.sh

# Submit a job
bash submit_job.sh --target-rows 1000 --wait

# Monitor logs
aws logs tail /aws/batch/surfalytics-github-ingest --follow --profile surfalytics-lab
```

## Lambda Deployment — Week 3 (`deploy.sh`)

1. Installs `requests` + `rich` into `package/` folder
2. Zips `package/` + `extract_github_data.py` → `function.zip`
3. Constructs role ARN from account ID (`surfalytics-lambda-github-role`)
4. Creates or updates function `surfalytics-github-ingest`:
   - Runtime: Python 3.11, Handler: `extract_github_data.lambda_handler`
   - Timeout: 300s, Memory: 512 MB
   - Layer: `AWSSDKPandas-Python311:23` (provides pandas/numpy — do NOT bundle them)

## Batch Deployment — Week 5 (`deploy.sh`)

1. Detects account ID via STS
2. Builds Docker image with `--platform linux/amd64` (required for Fargate on Apple Silicon)
3. Pushes to ECR `surfalytics-github-ingest`
4. Registers new job definition revision with the real image URI

## Core Script Architecture

`src/extract_github_data.py` is shared logic across all weeks (each week keeps its own copy):
- **`main()`** — CLI entry point, parses `argparse` args + env vars
- **`lambda_handler(event, context)`** — Lambda entry point, reads config from env vars + event dict overrides
- Both call the same extraction functions

**GitHub token resolution order**: `GITHUB_TOKEN` env var → `GH_TOKEN` env var → AWS Secrets Manager (`surfalytics/data-ingestion/github-token`)

**Rate limit handling**: On 403, script reads `X-RateLimit-Reset` header and sleeps until reset.

## Key Environment Variables

| Variable | Default | Notes |
|---|---|---|
| `AWS_REGION` | `us-east-1` | |
| `S3_BUCKET` | `surfalytics-raw-csv-180795190369` | Set from CF stack output |
| `TARGET_ROWS` | `1000` | Repos to collect |
| `S3_PREFIX` | `github-data` | S3 object prefix |
| `GITHUB_TOKEN_SECRET_NAME` | `surfalytics/data-ingestion/github-token` | Secrets Manager key |

Week 1 uses `AWS_PROFILE`; Week 2/3 use `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` directly; Week 5 uses IAM role assumed by Fargate.

## Currently Deployed Stacks

| Stack | Contents |
|---|---|
| `surfalytics-raw-csv` | S3 bucket, IAM user, access key (base infrastructure) |
| `surfalytics-iam` | S3 policy, Secrets Manager policy, Lambda/ECR/Batch deploy policy, shared execution role |
| `surfalytics-batch` | ECR repo, Fargate compute environment, job queue, job definition |
| `surfalytics-serverless` | Serverless Framework deploy permissions |
| `surfalytics-github-serverless-dev` | Lambda function deployed by Serverless Framework (Week 4) |
