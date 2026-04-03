# Week 3: AWS Lambda — Setup and execution

This document explains what AWS Lambda is, how it differs from the previous weeks, and walks through deploying and invoking the GitHub extractor as a serverless function.

---

## 1. What is AWS Lambda?

AWS Lambda is a **serverless compute** service. You upload code; AWS runs it on demand without you managing any servers.

Key characteristics:

| Property | Value |
|----------|-------|
| Execution model | Event-driven (triggered by HTTP, schedule, queue, etc.) |
| Billing | Per invocation + duration (free tier: 1M invocations/month) |
| Max timeout | 15 minutes |
| Max memory | 10 GB |
| Runtime | Python, Node.js, Java, Go, and more |
| Credentials | Automatically provided via IAM execution role |

### How it compares to the previous weeks

| | Week 1 (local) | Week 2 (Docker) | Week 3 (Lambda) |
|-|---------------|-----------------|-----------------|
| Where it runs | Your laptop | Docker on your laptop | AWS cloud |
| How you start it | `python script.py` | `docker run ...` | AWS Console / CLI / schedule |
| AWS credentials | `~/.aws` profile | Env vars in `.env` | IAM execution role (automatic) |
| Cost when idle | 0 (your laptop) | 0 (your laptop) | 0 (no invocations = no charge) |
| Scalability | Manual | Manual | Automatic |

### Lambda execution model (simplified)

```
You (or a schedule) → Trigger → Lambda Service → Runs your handler function
                                                         ↓
                                               extract_github_data.lambda_handler(event, context)
                                                         ↓
                                               Fetches GitHub API → Uploads CSV to S3
```

### What is an IAM execution role?

When Lambda runs your code, it needs AWS credentials to call S3 and Secrets Manager. Instead of hard-coding keys, Lambda **assumes an IAM role** and injects temporary credentials automatically. Your code calls `boto3` exactly the same way — it just finds credentials via the role instead of `~/.aws`.

The role for this project (`surfalytics-lambda-github-role`) is defined in the CloudFormation stack at `infrastructure/cloudformation/raw-csv-s3-stack.yaml` and grants:
- **CloudWatch Logs** — write execution logs
- **S3** — PutObject, GetObject, ListBucket on the raw CSV bucket
- **Secrets Manager** — GetSecretValue for the GitHub token

---

## 2. Prerequisites

- AWS CLI configured with the `surfalytics-lab` profile
- Python 3.11 installed locally (for building the ZIP)
- The CloudFormation stack already deployed (creates the S3 bucket, IAM role, and secret)

Verify:

```bash
aws sts get-caller-identity --profile surfalytics-lab
```

---

## 3. Project layout

```
03_aws_lambda/
├── src/
│   └── extract_github_data.py   ← same script as Week 1/2, with lambda_handler added
├── requirements.txt              ← only requests + rich (pandas/numpy come from a Lambda Layer)
├── deploy.sh                     ← packages and deploys everything
└── WEEK3_LAMBDA_SETUP_AND_EXECUTION.md
```

### What is a Lambda Layer?

A **Layer** is a ZIP of libraries that Lambda mounts at `/opt/python` before running your function. It keeps your deployment package small and lets multiple functions share the same dependencies.

This project uses the **AWS managed pandas layer** (`AWSSDKPandas-Python311`) which includes `pandas` and `numpy` pre-built for the Lambda runtime. You reference it by ARN — no need to bundle those large libraries yourself.

---

## 4. Deploy the CloudFormation stack (creates the IAM role)

If you haven't deployed the stack yet, or need to update it to add the Lambda role:

```bash
aws cloudformation deploy \
  --stack-name surfalytics-ingestion \
  --template-file infrastructure/cloudformation/raw-csv-s3-stack.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --profile surfalytics-lab
```

> `--capabilities CAPABILITY_NAMED_IAM` is required because the template creates named IAM resources.

After deployment, get the Lambda role ARN:

```bash
aws cloudformation describe-stacks \
  --stack-name surfalytics-ingestion \
  --query 'Stacks[0].Outputs[?OutputKey==`LambdaExecutionRoleArn`].OutputValue' \
  --output text \
  --profile surfalytics-lab
```

---

## 5. Deploy the Lambda function

### 5.1 First-time deploy

```bash
cd 03_aws_lambda

ROLE_ARN=arn:aws:iam::180795190369:role/surfalytics-lambda-github-role \
  bash deploy.sh
```

The script does three things:

1. **Builds a ZIP** — installs `requests` and `rich` into a `package/` folder, copies `extract_github_data.py`, and zips it all up (~2 MB).
2. **Resolves the IAM role** — uses the ARN you provide (or looks it up by name if already deployed).
3. **Creates the Lambda function** — calls `aws lambda create-function` with the ZIP, the pandas layer, and environment variables (`S3_BUCKET`, `AWS_REGION`).

### 5.2 Update after code changes

Just re-run the same command — the script detects the function already exists and calls `update-function-code` instead:

```bash
ROLE_ARN=arn:aws:iam::180795190369:role/surfalytics-lambda-github-role \
  bash deploy.sh
```

Once the role is deployed via CloudFormation, the script will also find it by name automatically:

```bash
bash deploy.sh
```

---

## 6. Invoke the Lambda function

### 6.1 From the CLI

```bash
aws lambda invoke \
  --function-name surfalytics-github-ingest \
  --payload '{"target_rows": 1000}' \
  --cli-binary-format raw-in-base64-out \
  response.json \
  --profile surfalytics-lab

cat response.json
```

Expected response:

```json
{"statusCode": 200, "body": "Uploaded 1000 rows to s3://surfalytics-raw-csv-180795190369/github-data/"}
```

### 6.2 From the AWS Console

1. Go to **Lambda → Functions → surfalytics-github-ingest**
2. Click **Test** tab
3. Create a test event:
   ```json
   { "target_rows": 1000 }
   ```
4. Click **Test** — watch the execution logs appear below

### 6.3 What the event payload does

The `lambda_handler` reads config from environment variables set on the function, but the event dict can override any of them:

| Event key | Overrides env var | Default |
|-----------|-------------------|---------|
| `target_rows` | `TARGET_ROWS` | `1000` |
| `s3_bucket` | `S3_BUCKET` | `surfalytics-raw-csv-180795190369` |
| `s3_prefix` | `S3_PREFIX` | `github-data` |
| `aws_region` | `AWS_REGION` | `us-east-1` |

---

## 7. View execution logs

Lambda automatically sends all `print()` and `logging` output to **CloudWatch Logs**.

From the CLI:

```bash
# List log streams (most recent first)
aws logs describe-log-streams \
  --log-group-name /aws/lambda/surfalytics-github-ingest \
  --order-by LastEventTime --descending \
  --query 'logStreams[0].logStreamName' --output text \
  --profile surfalytics-lab

# Tail the latest stream
aws logs get-log-events \
  --log-group-name /aws/lambda/surfalytics-github-ingest \
  --log-stream-name "<stream-name-from-above>" \
  --profile surfalytics-lab
```

Or in the Console: **Lambda → Monitor → View CloudWatch logs**

---

## 8. Verify the S3 upload

```bash
aws s3 ls s3://surfalytics-raw-csv-180795190369/github-data/ \
  --profile surfalytics-lab
```

---

## 9. Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `AccessDenied` on S3 or Secrets Manager | Check the CloudFormation stack deployed the `LambdaExecutionRole` with correct policies |
| `Task timed out after 3.00 seconds` | The default timeout is 3s — `deploy.sh` sets it to 300s; confirm with `aws lambda get-function-configuration` |
| `No module named 'pandas'` | The pandas layer ARN in `deploy.sh` may be wrong for your region; check [AWS SDK for pandas docs](https://aws-sdk-pandas.readthedocs.io/en/stable/install.html) for the correct ARN |
| `No module named 'requests'` | Re-run `deploy.sh` — the ZIP build may have failed silently |
| `ProfileNotFound` | Lambda never uses a local profile; if you see this, check the script is not setting `AWS_PROFILE` env var on the function |
| Function not found during invoke | Run `deploy.sh` first to create it |

---

## 10. Success criteria checklist

- [ ] CloudFormation stack deployed with `LambdaExecutionRole` in outputs
- [ ] `deploy.sh` completes without errors and prints the function ARN
- [ ] CLI invocation returns `{"statusCode": 200, ...}`
- [ ] S3 object visible at `s3://surfalytics-raw-csv-180795190369/github-data/github_repos_<timestamp>.csv`
- [ ] CloudWatch log group `/aws/lambda/surfalytics-github-ingest` exists and shows the run
