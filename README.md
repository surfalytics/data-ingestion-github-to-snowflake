# Surfalytics Data Ingestion Patterns

A progressive learning project demonstrating five ways to run the same Python data pipeline — from a local script to a fully managed cloud container — using AWS services and infrastructure-as-code.

Part of the [Surfalytics async project 06](https://github.com/surfalytics/data-projects/tree/main/async-projects/06-data-ingestion-patterns).

---

## What it does

Extracts public GitHub repository metadata via the GitHub API and saves it as a timestamped CSV to S3.

**Data flow:** GitHub API → 17 fields per repo → `github-data/github_repos_YYYYMMDD_HHMMSS.csv` → S3

**17 fields collected:** id, name, full_name, owner, private, html_url, description, fork, created_at, updated_at, pushed_at, size, stargazers_count, language, forks_count, open_issues_count, default_branch

---

## Five Deployment Patterns

| # | Folder | Approach | Credentials |
|---|--------|----------|-------------|
| 1 | `01_local_python_development/` | Plain Python script, local venv | `GITHUB_TOKEN` env var, `AWS_PROFILE` |
| 2 | `02_docker_container/` | Docker container, run locally | `.env` file with access key |
| 3 | `03_aws_lambda/` | AWS Lambda, deployed via CLI `deploy.sh` | IAM role assumed by Lambda |
| 4 | `04_aws_lambda_serverless_deploy/` | AWS Lambda, deployed via Serverless Framework | IAM role assumed by Lambda |
| 5 | `05_aws_batch_for_docker_container/` | AWS Batch (Fargate), Docker container in the cloud | IAM role assumed by Fargate task |

Each week's folder contains its own copy of `src/extract_github_data.py` — the same core logic adapted for that runtime.

---

## Repository Layout

```
.
├── 01_local_python_development/   # Week 1: local Python
├── 02_docker_container/           # Week 2: Docker
├── 03_aws_lambda/                 # Week 3: Lambda CLI deploy
├── 04_aws_lambda_serverless_deploy/  # Week 4: Lambda via Serverless Framework
├── 05_aws_batch_for_docker_container/  # Week 5: AWS Batch (Fargate)
├── 06_aws_step_function_run_lambda/   # (upcoming)
├── ...
├── infrastructure/
│   ├── cloudformation/
│   │   ├── iam.yaml               # IAM role + policies (deploy first)
│   │   ├── batch.yaml             # ECR, Fargate compute env, job queue
│   │   └── serverless.yaml        # Extra permissions for Serverless Framework
│   └── scripts/
│       ├── deploy-stack.sh        # Deploy any CloudFormation stack
│       ├── deploy-raw-csv-stack.sh
│       ├── push-github-token-to-secrets-manager.sh
│       └── configure-lab-ingestion-profile.sh
└── CLAUDE.md                      # Claude Code project instructions
```

---

## AWS Setup (one-time)

### Prerequisites

- AWS CLI configured with two profiles:
  - `local` — admin rights, deploys CloudFormation stacks
  - `surfalytics-lab` — restricted IAM user (`surfalytics-s3-ingestion`), runs ingestion
- Docker Desktop (for Week 2 and Week 5)
- Node.js + npm (for Week 4 Serverless Framework)

### 1. Store GitHub token in Secrets Manager

```bash
AWS_PROFILE=local bash infrastructure/scripts/push-github-token-to-secrets-manager.sh <your-github-pat>
```

### 2. Deploy IAM stack

Creates the shared execution role and all ingestion user policies.

```bash
bash infrastructure/scripts/deploy-stack.sh iam
```

### 3. Configure the ingestion profile

```bash
DEPLOY_PROFILE=local bash infrastructure/scripts/configure-lab-ingestion-profile.sh us-east-1
```

### 4. Deploy Batch stack (for Week 5)

```bash
BATCH_SUBNET_ID=$(aws ec2 describe-subnets \
  --filters Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text --profile local)

BATCH_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text --profile local)

BATCH_SUBNET_ID=$BATCH_SUBNET_ID BATCH_SG_ID=$BATCH_SG_ID \
  bash infrastructure/scripts/deploy-stack.sh batch
```

### 5. Deploy Serverless permissions (for Week 4 only)

```bash
bash infrastructure/scripts/deploy-stack.sh serverless
```

---

## Running Each Week

### Week 1 — Local Python

```bash
cd 01_local_python_development
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt

python src/extract_github_data.py --dry-run --target-rows 100   # local CSV, no S3
python src/extract_github_data.py --target-rows 1000            # upload to S3
```

Requires `GITHUB_TOKEN` or `GH_TOKEN` env var, and `AWS_PROFILE=surfalytics-lab`.

### Week 2 — Docker

```bash
cd 02_docker_container
cp .env.example .env   # fill in GITHUB_TOKEN, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_BUCKET

docker build -t surfalytics-github-ingest .
docker run --rm --env-file .env surfalytics-github-ingest --target-rows 1000
```

### Week 3 — AWS Lambda (CLI deploy)

```bash
cd 03_aws_lambda
bash deploy.sh   # packages + creates/updates the Lambda function

aws --profile surfalytics-lab lambda invoke \
  --cli-binary-format raw-in-base64-out \
  --function-name surfalytics-github-ingest \
  --payload '{"target_rows": 1000}' response.json

cat response.json
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

See [`04_aws_lambda_serverless_deploy/README.md`](04_aws_lambda_serverless_deploy/README.md) for removal instructions.

### Week 5 — AWS Batch (Fargate)

```bash
cd 05_aws_batch_for_docker_container

# Build image, push to ECR, register job definition
bash deploy.sh

# Submit a job and wait for it to finish
bash submit_job.sh --target-rows 1000 --wait

# Monitor logs live
aws logs tail /aws/batch/surfalytics-github-ingest --follow --profile surfalytics-lab

# Verify output landed in S3
aws s3 ls s3://surfalytics-raw-csv-180795190369/github-data/ --profile surfalytics-lab
```

`submit_job.sh` flags: `--target-rows N`, `--job-name NAME`, `--job-definition ARN`, `--dry-run`, `--wait`

---

## Infrastructure Design

**Single shared IAM role** (`surfalytics-lambda-github-role`) is reused across all weeks. It trusts both `lambda.amazonaws.com` and `ecs-tasks.amazonaws.com`, so the same role works for Lambda (Weeks 3–4) and Fargate (Week 5).

**CloudFormation stacks** are organized by AWS service, not by week:

| Stack | Template | What it creates |
|-------|----------|-----------------|
| `surfalytics-iam` | `iam.yaml` | Execution role, S3/Secrets/Deploy policies for ingestion user |
| `surfalytics-batch` | `batch.yaml` | ECR repo, Fargate compute env, job queue, job definition |
| `surfalytics-serverless` | `serverless.yaml` | Extra CF + Lambda permissions for Serverless Framework |

Deploy order: `iam` → `batch` (batch imports the role ARN exported by iam).

---

## Environment Variables

| Variable | Default | Used by |
|---|---|---|
| `GITHUB_TOKEN` / `GH_TOKEN` | — | All weeks (env var path) |
| `GITHUB_TOKEN_SECRET_NAME` | `surfalytics/data-ingestion/github-token` | All weeks (Secrets Manager path) |
| `AWS_REGION` | `us-east-1` | All weeks |
| `S3_BUCKET` | `surfalytics-raw-csv-180795190369` | All weeks |
| `S3_PREFIX` | `github-data` | All weeks |
| `TARGET_ROWS` | `1000` | All weeks |
| `AWS_PROFILE` | `surfalytics-lab` | Week 1 (local boto3 session) |

**Token resolution order:** `GITHUB_TOKEN` env var → `GH_TOKEN` env var → AWS Secrets Manager

**Rate limit handling:** On HTTP 403, the script reads the `X-RateLimit-Reset` header and sleeps until the reset time.
