# Week 4 — AWS Lambda via Serverless Framework

Same GitHub → CSV → S3 behavior as [`../03_aws_lambda`](../03_aws_lambda), but deployed with **Serverless Framework v3** (`serverless.yml`) instead of `deploy.sh`.

## Prerequisites

- **Node.js 18+** and npm
- **AWS credentials** (for deploy: profile with CloudFormation + Lambda + S3 + IAM pass-role; see IAM section below)
- **Python 3.11** on your machine (used by `serverless-python-requirements` to resolve wheels)
- **IAM role `surfalytics-lambda-github-role`** in the same account (created by [`../infrastructure/scripts/deploy-raw-csv-stack.sh`](../infrastructure/scripts/deploy-raw-csv-stack.sh) or [`../infrastructure/scripts/deploy-stack.sh`](../infrastructure/scripts/deploy-stack.sh) `03`). `serverless.yml` sets `provider.role` to `arn:aws:iam::<account>:role/surfalytics-lambda-github-role` using `${aws:accountId}` — no CloudFormation output lookup. If you renamed the role, edit `provider.role` in `serverless.yml`.
- Optional: **Docker** if `pip` / Linux wheel builds fail on macOS (then set `dockerizePip: true` under `custom.pythonRequirements` in `serverless.yml`)

## Install

```bash
cd 04_aws_lambda_serverless_deploy
npm install
```

## IAM for the lab user (`surfalytics-s3-ingestion`)

Direct `aws lambda create-function` (Week 3) is covered by the raw CSV stack’s `IngestionLambdaPolicy`. **Serverless** also drives **CloudFormation** and an **artifact S3 bucket** inside its stack — deploy the extra policy stack once (admin profile):

```bash
# From repository root:
aws cloudformation deploy \
  --profile local \
  --region us-east-1 \
  --stack-name surfalytics-04-serverless-policy \
  --template-file infrastructure/cloudformation/04_serverless_lab_user_policy.yaml \
  --capabilities CAPABILITY_NAMED_IAM
```

Or: `bash infrastructure/scripts/deploy-stack.sh 04`

## Configure

- **`S3_BUCKET`** — raw CSV bucket (default in `serverless.yml` matches Week 3 `deploy.sh`; override with env if your account differs).

## Deploy

```bash
# Use surfalytics-lab for the ingestion IAM user, or local for admin deploy.
export AWS_PROFILE=surfalytics-lab

npm run deploy

# Or explicit stage/region:
# npx serverless deploy --stage dev --region us-east-1 --aws-profile surfalytics-lab
```

## Function name vs Week 3

By default this service deploys **`surfalytics-github-ingest-sls-<stage>`** (e.g. `surfalytics-github-ingest-sls-dev`) so it does **not** collide with the CLI-managed **`surfalytics-github-ingest`** from Week 3.

To use the **same** physical name as Week 3: delete the Week 3 function once, then in `serverless.yml` set `functions.githubIngest.name` to `surfalytics-github-ingest` (no `${sls:stage}` suffix if you want a single stable name) and redeploy.

## Invoke

```bash
echo '{"target_rows": 100}' > payload.json
aws lambda invoke \
  --cli-binary-format raw-in-base64-out \
  --function-name surfalytics-github-ingest-sls-dev \
  --payload file://payload.json \
  --profile surfalytics-lab \
  response.json
cat response.json
```

Adjust `--function-name` if you changed `stage` or `name` in `serverless.yml`.

## Keep handler in sync

`src/extract_github_data.py` is copied from Week 3. If you change extraction logic, update either [`../03_aws_lambda/src/extract_github_data.py`](../03_aws_lambda/src/extract_github_data.py) or this copy and keep them aligned.

## Remove the Serverless stack

```bash
npx serverless remove --stage dev
```
