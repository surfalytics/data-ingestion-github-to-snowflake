# Week 6 — AWS Step Functions (orchestrate Lambda)

This exercise adds a **Step Functions** state machine that calls the same GitHub ingest Lambda as Week 3 (`surfalytics-github-ingest`), but through a workflow instead of a direct `lambda invoke`.

Infrastructure lives in the shared CloudFormation folder: [`infrastructure/cloudformation/step-functions.yaml`](../infrastructure/cloudformation/step-functions.yaml).

## Prerequisites

1. **IAM stack** deployed and updated (includes Step Functions permissions for the lab user).
2. **Lambda** `surfalytics-github-ingest` exists in the same account and region (deploy [Week 3 `03_aws_lambda`](../03_aws_lambda/) first).

## Deploy

Use the admin profile that deploys CloudFormation (often `local`):

```bash
# Pick up new Step Functions permissions for surfalytics-s3-ingestion
AWS_PROFILE=local bash infrastructure/scripts/deploy-stack.sh iam

AWS_PROFILE=local bash infrastructure/scripts/deploy-stack.sh stepfunctions
```

Optional: target a different Lambda name:

```bash
GITHUB_INGEST_FUNCTION_NAME=surfalytics-github-ingest-sls-dev \
  AWS_PROFILE=local bash infrastructure/scripts/deploy-stack.sh stepfunctions
```

Stack outputs include the state machine ARN.

## Run an execution

Start execution input must include **`target_rows`** (the Pass state nests your input under `pipeline` for the Task; the Lambda reads `target_rows` from the payload).

Restricted lab user (`surfalytics-lab`):

```bash
SM_ARN=$(aws cloudformation describe-stacks --stack-name surfalytics-stepfunctions \
  --query 'Stacks[0].Outputs[?OutputKey==`StateMachineArn`].OutputValue' --output text \
  --profile local --region us-east-1)

aws stepfunctions start-execution \
  --state-machine-arn "$SM_ARN" \
  --input '{"target_rows":100}' \
  --profile surfalytics-lab --region us-east-1
```

Follow progress in the **Step Functions** console, or:

```bash
aws stepfunctions describe-execution \
  --execution-arn "<executionArn from start-execution output>" \
  --profile surfalytics-lab --region us-east-1
```

## What each step in this state machine does

This template uses two state types. Other types are listed so you can tell them apart from **Pass** and **Task**.

| State type | In this exercise | Role |
|------------|------------------|------|
| **Pass** | `AnnotateRun` | Updates the execution’s JSON **only inside the state machine**. Here it wraps your input in a `pipeline` object and adds static `orchestrator` metadata. No Lambda, no S3, no billing for “remote” work—only a transition. |
| **Task** | `InvokeIngestLambda` | **Does work**: calls AWS Lambda through the SDK integration `arn:aws:states:::lambda:invoke`. The Lambda run time, API calls, and S3 upload behave exactly as in Week 3. Retries and error handling can be attached to Task states (not shown here). |

**Not used here, but common elsewhere**

- **Choice** — branch on a value in the state (like `if` / `switch`).
- **Wait** — pause for a duration or until a timestamp (good for rate limits or schedules).
- **Parallel** — run multiple branches at once.
- **Succeed** / **Fail** — end the workflow with a success or error outcome without invoking a service.

**Legacy vs SDK Lambda invoke:** This workflow uses the **AWS SDK service integration** (`Resource: arn:aws:states:::lambda:invoke`). Older tutorials sometimes set `Resource` to the Lambda function ARN directly; both can invoke Lambda, but the SDK style is the one AWS documents for new workflows.

## Files and naming

| Resource | Name / notes |
|----------|----------------|
| CloudFormation stack | `surfalytics-stepfunctions` |
| State machine | `surfalytics-github-ingest-pipeline` |
| Step Functions → Lambda IAM role | `surfalytics-stepfunctions-github-ingest` |

## Troubleshooting

### `KMSAccessDeniedException` when the ingest Lambda runs

Lambda decrypts **environment variables** with the KMS key you chose on the function. That requires **two** things:

1. **Identity policy** on `surfalytics-lambda-github-role` — the IAM stack already includes `kms:Decrypt` / `kms:DescribeKey` on keys in this account (`KMSDecryptLambdaEnv` in [`iam.yaml`](../infrastructure/cloudformation/iam.yaml)). Redeploy IAM if you are unsure it is applied.
2. **Key policy** on the CMK — the error *“no resource-based policy allows the kms:Decrypt action”* means the **KMS key** does not yet trust this role. Open **KMS** in the console → the key shown in the error → **Key policy** → edit JSON and add a statement that allows the execution role (use your account ID):

```json
{
  "Sid": "AllowSurfalyticsLambdaExecutionRole",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::<ACCOUNT_ID>:role/surfalytics-lambda-github-role"
  },
  "Action": [
    "kms:Decrypt",
    "kms:DescribeKey"
  ],
  "Resource": "*"
}
```

Merge this with the existing policy array (do not remove administrators’ statements). Alternatively, on the Lambda function, set environment encryption to the **default AWS managed key for Lambda** (`aws/lambda`) so a custom CMK is not required for env vars (fine for learning; orgs may require a CMK).

## Cleanup

Delete the stack when finished experimenting:

```bash
AWS_PROFILE=local aws cloudformation delete-stack --stack-name surfalytics-stepfunctions --region us-east-1
```

Removing Step Functions permissions from the lab user is done by editing and redeploying the IAM stack if you no longer want them.
