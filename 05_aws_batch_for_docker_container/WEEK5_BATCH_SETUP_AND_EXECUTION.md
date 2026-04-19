# Week 5 — AWS Batch (Fargate)

Run the same Docker container from Week 2 as an AWS Batch job on Fargate. No EC2 fleet to manage, no 15-minute Lambda timeout, and the same IAM role used by all prior weeks.

## Why AWS Batch?

| Topic | Week 2 (Docker local) | Week 5 (AWS Batch) |
|---|---|---|
| Where it runs | Your laptop | AWS Fargate (serverless containers) |
| AWS credentials | `AWS_ACCESS_KEY_ID` in `.env` | IAM role assumed by Fargate task |
| Image storage | Local only | ECR (private registry, versioned) |
| Job tracking | Terminal process | Batch job queue — status, history, retry |
| Max runtime | Until you Ctrl-C | Up to 10 min (configurable to 24 hours) |
| Cost | Free (local) | Per-vCPU/memory-second on Fargate |

## Prerequisites

- Docker Desktop running locally
- AWS CLI v2 with `surfalytics-lab` profile configured (`surfalytics-s3-ingestion` user)
- Admin profile `local` for deploying CloudFormation
- Main stack `surfalytics-raw-csv` already deployed (Week 1–4 prerequisite)

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Same image as Week 2 — `python:3.11-slim`, installs deps, runs the script |
| `src/extract_github_data.py` | Same extraction script used in all weeks |
| `requirements.txt` | All Python dependencies (full, not lambda-stripped) |
| `.env.example` | Local env vars for `deploy.sh` / `submit_job.sh` (not injected into container) |
| `deploy.sh` | Build → push to ECR → register new job definition revision |
| `submit_job.sh` | Submit a Batch job with configurable parameters |

## One-time Setup

### 1. Update the main IAM stack

The `surfalytics-lambda-github-role` role has been extended to also be trusted by Fargate (`ecs-tasks.amazonaws.com`), and the `surfalytics-s3-ingestion` user policy now includes ECR push and Batch submit permissions. Apply the update:

```bash
bash infrastructure/scripts/deploy-raw-csv-stack.sh us-east-1
```

### 2. Deploy the Batch infrastructure stack

The Batch stack needs your default VPC subnet and security group IDs:

```bash
# Get default VPC subnet and security group
BATCH_SUBNET_ID=$(aws ec2 describe-subnets \
  --filters Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text --profile local)

BATCH_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=default \
  --query 'SecurityGroups[0].GroupId' --output text --profile local)

# Deploy
BATCH_SUBNET_ID=$BATCH_SUBNET_ID BATCH_SG_ID=$BATCH_SG_ID \
  bash infrastructure/scripts/deploy-stack.sh 05
```

This creates:
- ECR repository `surfalytics-github-ingest`
- Fargate compute environment `surfalytics-batch-fargate`
- Job queue `surfalytics-github-ingest-queue`
- Job definition `surfalytics-github-ingest-job` (placeholder image — real image set by `deploy.sh`)
- CloudWatch log group `/aws/batch/surfalytics-github-ingest`

## Build and Deploy the Container

```bash
cd 05_aws_batch_for_docker_container

bash deploy.sh            # build + push to ECR + register new job definition revision
bash deploy.sh --submit   # also submit a test job immediately after
```

What `deploy.sh` does:
1. Detects your AWS account ID via STS
2. Builds the image with `--platform linux/amd64` (required for Fargate on Apple Silicon)
3. Authenticates to ECR and pushes the image
4. Registers a new job definition revision with the real ECR image URI
5. (Optional) Submits a test job

## Submit a Job

```bash
bash submit_job.sh                              # 1000 repos, default settings
bash submit_job.sh --target-rows 100            # quick smoke test
bash submit_job.sh --target-rows 1000 --wait    # block until job completes
bash submit_job.sh --dry-run --target-rows 50   # container runs but does not upload to S3
```

## Monitor

```bash
# Check job status
aws batch describe-jobs --jobs <JOB_ID> --profile surfalytics-lab \
  --query 'jobs[0].{Status:status,Reason:statusReason}'

# Stream logs (once job is RUNNING)
aws logs tail /aws/batch/surfalytics-github-ingest --follow --profile surfalytics-lab

# List recent jobs
aws batch list-jobs --job-queue surfalytics-github-ingest-queue \
  --profile surfalytics-lab --output table
```

## Verify S3 Output

```bash
aws s3 ls s3://surfalytics-raw-csv-180795190369/github-data/ --profile surfalytics-lab
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `AccessDenied` on ECR push | Re-deploy `surfalytics-raw-csv` main stack to attach new ECR+Batch policy to user |
| Job stuck at `RUNNABLE` | Check compute environment status: `aws batch describe-compute-environments --compute-environments surfalytics-batch-fargate --profile surfalytics-lab`. Verify subnet has `AssignPublicIp: ENABLED` so Fargate can reach ECR and S3 |
| Job `FAILED` immediately | Check logs: `aws logs tail /aws/batch/surfalytics-github-ingest --profile surfalytics-lab`. Common cause: wrong platform (arm64 vs amd64) |
| Image architecture mismatch | Rebuild with `docker build --platform linux/amd64` (already in `deploy.sh`) |
| `ProfileNotFound` error in container | The container uses the IAM role, not a profile — do not set `AWS_PROFILE` in the job definition |
| `InvalidJobDefinition` on submit | Run `deploy.sh` first to register a revision with the real ECR image |
