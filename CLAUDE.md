# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Context

This is a **GitHub repository metadata extraction pipeline** built as part of the [Surfalytics async project 06](https://github.com/surfalytics/data-projects/tree/main/async-projects/06-data-ingestion-patterns). It demonstrates three progressive deployment patterns: local Python → Docker → AWS Lambda.

**Data flow**: GitHub API → 17 selected fields → CSV → S3 bucket (`github-data/github_repos_YYYYMMDD_HHMMSS.csv`)

## AWS Setup

Infrastructure is managed via CloudFormation using the AWS CLI profile `local` (admin rights). The `local` profile creates the CF stack and a restricted `surfalytics-s3-ingestion` IAM user for actual data ingestion.

**Deploy infrastructure:**
```bash
cd infrastructure/scripts
AWS_PROFILE=local ./deploy-raw-csv-stack.sh us-east-1
```

**Store GitHub token in Secrets Manager:**
```bash
AWS_PROFILE=local ./push-github-token-to-secrets-manager.sh <token>
```

**Configure ingestion AWS profile from stack outputs:**
```bash
DEPLOY_PROFILE=local ./configure-lab-ingestion-profile.sh us-east-1
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

# Invoke directly
aws --profile surfalytics-lab lambda invoke \
  --function-name surfalytics-github-ingest \
  --payload '{"target_rows": 1000}' response.json
```

## CloudFormation Stack

**Template**: `infrastructure/cloudformation/raw-csv-s3-stack.yaml`

Creates:
- **S3 bucket**: `surfalytics-raw-csv-{AccountId}`
- **IAM policies** attached to existing `surfalytics-s3-ingestion` user: S3 access, Secrets Manager read, Lambda create/update/invoke
- **Lambda execution role** (`surfalytics-lambda-github-role`): S3 + Secrets Manager + CloudWatch Logs

Stack requires `CAPABILITY_NAMED_IAM` (handled in deploy script).

## Lambda Deployment (`deploy.sh`)

1. Installs `requests` + `rich` into `package/` folder
2. Zips `package/` + `extract_github_data.py` → `function.zip`
3. Looks up `surfalytics-lambda-github-role` ARN (or reads `$ROLE_ARN`)
4. Creates or updates function `surfalytics-github-ingest`:
   - Runtime: Python 3.11, Handler: `extract_github_data.lambda_handler`
   - Timeout: 300s, Memory: 512 MB
   - Layer: `AWSSDKPandas-Python311:23` (provides pandas/numpy — do NOT bundle them)

## Core Script Architecture

`src/extract_github_data.py` is shared logic across all three stages:
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

Week 1 uses `AWS_PROFILE`; Week 2/3 use `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` directly.
