# Week 3: AWS Lambda — Setup and Execution

This is a learning guide for deploying the GitHub extractor as a serverless AWS Lambda function for the first time. It explains not just *what* to do but *why* each piece exists, and documents the real issues encountered during this lab deployment so you know what to expect.

---

## 1. What is AWS Lambda, and why does it matter?

In Week 1 you ran a Python script on your laptop. In Week 2 you packaged that script inside Docker. Both approaches have one thing in common: **you need a computer running to do the work.**

Lambda flips this model. You upload your code to AWS, and AWS runs it only when triggered — in response to an event, a schedule, an API call, or anything else. When it is not running, you pay nothing and nothing is using server resources.

This is called **serverless compute**. There is still a server — you just do not manage it.

### Key Lambda properties

| Property | Value |
|---|---|
| Execution model | Event-driven — code runs in response to a trigger |
| Billing | Per invocation + duration (free tier: 1 million calls/month) |
| Max runtime | 15 minutes per invocation |
| Max memory | 10 GB |
| Cold start | First invocation after idle period takes a second or two longer |
| Runtimes | Python, Node.js, Java, Go, Ruby, and more |
| Credentials | Injected automatically via an IAM execution role — no keys in code |

### How this week compares to the previous two

| | Week 1 — Local Python | Week 2 — Docker | Week 3 — Lambda |
|---|---|---|---|
| Where it runs | Your laptop | Docker on your laptop | AWS cloud |
| How you start it | `python script.py` | `docker run ...` | AWS CLI, Console, or a schedule |
| AWS credentials | `~/.aws` profile | Env vars in `.env` file | IAM execution role (automatic) |
| Cost when idle | $0 (your laptop) | $0 (your laptop) | $0 (no invocations = no charge) |
| Scalability | You run it manually | You run it manually | AWS runs multiple copies automatically |
| Logs | Terminal output | Terminal output | CloudWatch Logs (persisted in AWS) |

---

## 2. How Lambda runs your code

When Lambda receives an event (e.g., you invoke it from the CLI), it:

1. Finds a warm container or starts a new one with your runtime (Python 3.11)
2. Mounts your deployment ZIP and any Layers
3. Sets environment variables on the container
4. Calls your **handler function** with two arguments: `event` and `context`
5. Returns whatever your handler returns, and logs all output to CloudWatch

```
You (or a schedule)
    │
    ▼
aws lambda invoke --payload '{"target_rows": 1000}' ...
    │
    ▼
Lambda Service
    │  mounts your ZIP + pandas Layer
    │  sets S3_BUCKET env var
    │
    ▼
extract_github_data.lambda_handler(event, context)
    │
    ├── reads target_rows from event dict
    ├── gets GitHub token from Secrets Manager
    ├── fetches 1000 repos from GitHub API
    └── uploads CSV to S3
    │
    ▼
{"statusCode": 200, "body": "Uploaded 1000 rows to s3://..."}
```

### The handler function

Your script has two entry points. Lambda uses `lambda_handler`:

```python
def lambda_handler(event, context):
    # event  — the JSON payload you pass at invocation time
    # context — Lambda metadata (function name, timeout remaining, etc.)

    target_rows = int(event.get("target_rows", os.environ.get("TARGET_ROWS", 1000)))
    s3_bucket   = event.get("s3_bucket",  os.environ.get("S3_BUCKET", DEFAULT_BUCKET))
    ...
```

The `event` dict is how you pass parameters at runtime — like `{"target_rows": 500}`. The function first checks the event, then falls back to environment variables, then uses hardcoded defaults. This lets you override behaviour without changing code.

---

## 3. What is an IAM execution role, and why do you need it?

When Lambda runs your code and it calls `boto3.client("s3")` or `boto3.client("secretsmanager")`, boto3 needs AWS credentials. On your laptop in Week 1 those came from `~/.aws/credentials`. Inside Lambda there is no such file.

Instead, Lambda **assumes an IAM role** before your code runs. AWS injects temporary, auto-rotating credentials into the container. Your code never sees or handles keys — boto3 finds them automatically via the environment.

The role for this project is `surfalytics-lambda-github-role`. It grants:

- **CloudWatch Logs** — so Lambda can write your print/logging output somewhere
- **S3** — PutObject, GetObject, ListBucket on the raw CSV bucket
- **Secrets Manager** — GetSecretValue to read the GitHub personal access token

Without this role your function would start and immediately fail with `AccessDenied`.

### Two profiles, two purposes

This lab uses two separate AWS identities:

| Profile | Identity | Purpose |
|---|---|---|
| `local` | `admin-local` (AdministratorAccess) | Deploy CloudFormation stacks, create IAM roles |
| `surfalytics-lab` | `surfalytics-s3-ingestion` (restricted) | Deploy and invoke the Lambda function |

The ingestion user cannot create IAM roles or manage CloudFormation stacks. That is intentional — the principle of least privilege means the account that runs code day-to-day cannot modify its own permissions.

---

## 4. What is a Lambda Layer?

A **Layer** is a ZIP of additional files (libraries, binaries, data) that Lambda extracts to `/opt` before running your function. Layers are:

- **Shared** — multiple functions can reference the same Layer
- **Versioned** — each upload gets a version number and ARN
- **Size-reducing** — large dependencies live in the Layer, not your ZIP

This project uses the AWS-managed pandas Layer:

```
arn:aws:lambda:us-east-1:336392948345:layer:AWSSDKPandas-Python311:23
```

This provides `pandas` and `numpy` pre-built for the Lambda runtime. Without this Layer you would need to bundle those libraries in your ZIP, adding ~50 MB to every deployment. With the Layer, your ZIP stays around 2 MB.

The Layer ARN encodes: **AWS account** (336392948345 = AWS's own account for managed layers), **region**, **layer name**, and **version number**. If you deploy to a different region, the ARN changes.

---

## 5. Infrastructure — CloudFormation stacks

The infrastructure is split into three CloudFormation stacks that match each week's exercise. A **CloudFormation stack** is a group of AWS resources (IAM policies, roles, S3 buckets, etc.) that are created, updated, and deleted together as a unit.

### The three stacks

| Stack name | Template | What it creates |
|---|---|---|
| `surfalytics-01-local` | `01_local_python.yaml` | S3 + Secrets Manager policies for the ingestion user |
| `surfalytics-02-docker` | `02_docker.yaml` | Same as 01 — deploy only if you skipped Week 1 |
| `surfalytics-03-lambda` | `03_lambda.yaml` | `surfalytics-lambda-github-role` + Lambda deploy policy |

The S3 bucket and IAM user (`surfalytics-s3-ingestion`) were created outside these stacks during the initial lab setup.

### Deploy a stack

```bash
# From the repo root
bash infrastructure/scripts/deploy-stack.sh 01   # Week 1
bash infrastructure/scripts/deploy-stack.sh 02   # Week 2 (skip if 01 is already deployed)
bash infrastructure/scripts/deploy-stack.sh 03   # Week 3 — creates the Lambda execution role
```

The script uses the `local` profile (admin) and deploys to `us-east-1`.

### Verify a stack is deployed

```bash
aws cloudformation describe-stacks \
  --stack-name surfalytics-03-lambda \
  --region us-east-1 \
  --profile local \
  --query 'Stacks[0].{Status:StackStatus,Outputs:Outputs}' \
  --output json
```

Expected status: `CREATE_COMPLETE`. The outputs include the Lambda execution role ARN.

> **Region note:** The `local` profile defaults to `us-west-2`. Always pass `--region us-east-1` when verifying stacks or you will see "stack does not exist" even when it is there.

---

## 6. Deploy the Lambda function

The `deploy.sh` script handles packaging and deployment. It must be run from inside `03_aws_lambda/`.

### What deploy.sh does, step by step

**Step 1 — Build the ZIP**

```bash
pip install requests rich --target package/
cp src/extract_github_data.py package/
cd package && zip -r ../function.zip .
```

Lambda requires a self-contained ZIP. `pandas` and `numpy` are excluded because they come from the Layer. Only `requests` and `rich` are bundled (~2 MB total).

**Step 2 — Resolve the IAM role ARN**

The script calls `aws iam get-role --role-name surfalytics-lambda-github-role`. This uses the `surfalytics-lab` profile, which does **not** have `iam:GetRole` permission. You will see an error like:

```
ERROR: IAM role 'surfalytics-lambda-github-role' not found and ROLE_ARN not set.
```

Pass the ARN directly to skip the lookup:

```bash
ROLE_ARN=arn:aws:iam::180795190369:role/surfalytics-lambda-github-role bash deploy.sh
```

**Step 3 — Create or update the function**

If the function does not exist: `aws lambda create-function`

If it already exists: `aws lambda update-function-code` + `aws lambda update-function-configuration`

The function is configured with:
- Runtime: `python3.11`
- Handler: `extract_github_data.lambda_handler`
- Timeout: 300 seconds (5 minutes)
- Memory: 512 MB
- Layer: the AWS pandas Layer ARN
- Environment variable: `S3_BUCKET=surfalytics-raw-csv-180795190369`

> **Important:** `AWS_REGION` is a **reserved** Lambda environment variable injected automatically. If you try to set it manually you will get `InvalidParameterValueException: Reserved keys used in this request: AWS_REGION`. It is intentionally excluded from `deploy.sh`.

### Run the deployment

```bash
cd 03_aws_lambda

ROLE_ARN=arn:aws:iam::180795190369:role/surfalytics-lambda-github-role \
  bash deploy.sh
```

Expected output:

```
>>> Building deployment ZIP...
    ZIP size: 2.3M
>>> Resolving IAM role...
    Using role: arn:aws:iam::180795190369:role/surfalytics-lambda-github-role
>>> Deploying Lambda function: surfalytics-github-ingest
    Creating new function...
arn:aws:lambda:us-east-1:180795190369:function:surfalytics-github-ingest

✓ Done.
```

---

## 7. Invoke the Lambda function

### From the CLI

```bash
aws lambda invoke \
  --function-name surfalytics-github-ingest \
  --payload '{"target_rows": 1000}' \
  --cli-binary-format raw-in-base64-out \
  --region us-east-1 \
  --profile surfalytics-lab \
  response.json

cat response.json
```

Expected response:

```json
{"statusCode": 200, "body": "Uploaded 1000 rows to s3://surfalytics-raw-csv-180795190369/github-data/"}
```

The `--cli-binary-format raw-in-base64-out` flag is required for AWS CLI v2 when passing a plain JSON string as the payload.

### From the AWS Console

1. Open **Lambda → Functions → surfalytics-github-ingest**
2. Click the **Test** tab
3. Create a new test event with this JSON:
   ```json
   { "target_rows": 1000 }
   ```
4. Click **Test** and watch logs appear in the Execution result panel below

### What the event payload controls

| Event key | Env var fallback | Default |
|---|---|---|
| `target_rows` | `TARGET_ROWS` | `1000` |
| `s3_bucket` | `S3_BUCKET` | `surfalytics-raw-csv-180795190369` |
| `s3_prefix` | `S3_PREFIX` | `github-data` |
| `aws_region` | `AWS_REGION` (auto) | `us-east-1` |

---

## 8. View execution logs

Every `print()` and `logging` call inside your function is automatically sent to **CloudWatch Logs** under the log group `/aws/lambda/surfalytics-github-ingest`. Logs persist after the function finishes, which is very different from Week 1 where output disappeared when you closed the terminal.

### Get the latest log stream name

```bash
aws logs describe-log-streams \
  --log-group-name /aws/lambda/surfalytics-github-ingest \
  --order-by LastEventTime \
  --descending \
  --query 'logStreams[0].logStreamName' \
  --output text \
  --region us-east-1 \
  --profile surfalytics-lab
```

### Read the log events

```bash
aws logs get-log-events \
  --log-group-name /aws/lambda/surfalytics-github-ingest \
  --log-stream-name "<stream-name-from-above>" \
  --region us-east-1 \
  --profile surfalytics-lab
```

Or go to the Console: **Lambda → Monitor → View CloudWatch logs**

---

## 9. Verify the S3 upload

```bash
aws s3 ls s3://surfalytics-raw-csv-180795190369/github-data/ \
  --region us-east-1 \
  --profile surfalytics-lab
```

You should see timestamped CSV files like:

```
2026-04-04  162426  github_repos_20260404_010000.csv
```

---

## 10. What actually happened during this lab (real deployment notes)

This section documents the real issues encountered during the first deployment of this lab. These are not theoretical — they all happened and were debugged live.

### Issue 1 — `AWS_REGION` is a reserved environment variable

**What happened:** `deploy.sh` originally set `AWS_REGION` as a Lambda environment variable. Lambda rejected this with:

```
InvalidParameterValueException: Reserved keys used in this request: AWS_REGION
```

**Why:** Lambda automatically injects `AWS_REGION` (and several other variables like `AWS_EXECUTION_ENV`) into every function container. You cannot override them.

**Fix:** Removed `AWS_REGION` from the `--environment` block in `deploy.sh`. Lambda already provides it.

**Lesson:** Lambda reserved variables are `AWS_REGION`, `AWS_LAMBDA_FUNCTION_NAME`, `AWS_LAMBDA_FUNCTION_MEMORY_SIZE`, `AWS_LAMBDA_FUNCTION_VERSION`, and a few others. Never try to set these manually.

---

### Issue 2 — The ingestion user cannot look up IAM roles

**What happened:** `deploy.sh` tried to look up the Lambda role ARN by calling `aws iam get-role`. The `surfalytics-lab` profile (the ingestion user) does not have `iam:GetRole` permission and the script exited with:

```
ERROR: IAM role 'surfalytics-lambda-github-role' not found and ROLE_ARN not set.
```

**Why:** The ingestion user is intentionally restricted. It can deploy and invoke Lambda functions, but it cannot read IAM metadata. This is least-privilege in practice.

**Fix:** Pass the role ARN as an environment variable to bypass the lookup:

```bash
ROLE_ARN=arn:aws:iam::180795190369:role/surfalytics-lambda-github-role bash deploy.sh
```

**Lesson:** In a real team environment you would either (a) use a CI/CD system with a deployment role that has IAM read access, or (b) hard-code the known role ARN in the deploy script. We chose (b) — the ARN is deterministic once the CF stack is deployed.

---

### Issue 3 — The Lambda execution role was orphaned from a deleted CloudFormation stack

**What happened:** An older CloudFormation stack (`surfalytics-ingestion`) had previously created `surfalytics-lambda-github-role`. That stack was deleted, but CloudFormation could not fully clean up — the role was still attached to the Lambda function and the ingestion user's policies referenced it. The role became **orphaned**: it existed in IAM but was not managed by any stack.

When we tried to deploy the `surfalytics-03-lambda` stack to recreate the role, CloudFormation refused:

```
surfalytics-lambda-github-role already exists in stack
arn:aws:cloudformation:us-east-1:.../surfalytics-ingestion/...
```

Even though that old stack no longer showed up in normal stack listings.

**Why:** CloudFormation tracks resource ownership internally. Even a deleted stack's ghost entry can block a new stack from claiming a named resource.

**Fix:**
1. Found the old blocking stack by querying CloudTrail for the stack events
2. Deleted the old `surfalytics-ingestion` stack by its ARN
3. Re-deployed `surfalytics-03-lambda` successfully

**Lesson:** Named IAM resources (roles, policies) are global in an account. If you hard-code a name like `RoleName: surfalytics-lambda-github-role` in a CloudFormation template, only one stack can own it at a time. When you delete a stack and re-create it with the same named resources, always wait for the old stack to fully delete before deploying the new one.

---

### Issue 4 — All CloudFormation checks appeared to fail (wrong region)

**What happened:** After deploying stacks 01, 02, and 03, every `describe-stacks` and `list-stacks` call returned "stack does not exist" or an empty list. It looked like nothing had deployed.

**Why:** The `local` AWS CLI profile has `us-west-2` as its default region. The deploy script explicitly uses `--region us-east-1`, so stacks were deployed there. But the verification commands omitted `--region`, so they were hitting the wrong region.

**Fix:** Always include `--region us-east-1` in every CLI verification command when using the `local` profile.

**Lesson:** Always be explicit about region in CLI commands, especially when your profile's default region differs from where your infrastructure lives. A missing `--region` flag is one of the most common sources of "resource not found" confusion in AWS.

---

### Issue 5 — KMS decryption error after recreating the Lambda role

**What happened:** After the Lambda execution role was deleted and recreated (with a new IAM Role ID), invoking the function failed with:

```
KMSAccessDeniedException: User ... is not authorized to perform kms:Decrypt
on resource arn:aws:kms:us-east-1:.../key/5c8f09c5-...
```

**Why:** The Lambda function's environment variables were encrypted with a Customer Managed KMS Key (CMK). When Lambda encrypts env vars with a CMK, it creates a **KMS grant** tied to the specific IAM Role ID of the execution role. The Role ID changes every time you delete and recreate a role — even if the role name stays the same. The new role had a different ID, so it could not use the old grant.

**Fix:**
1. Looked up the old KMS grant with `aws kms list-grants`
2. Retired it with `aws kms retire-grant`
3. Cleared the function's environment variables and re-added them (Lambda re-encrypts them under the default AWS-managed key since the CMK was no longer configured)

**Lesson:** IAM Role Names are human-readable labels. The **Role ID** (starting with `AROA...`) is the actual unique identifier AWS services use internally. Deleting and recreating a role always produces a new Role ID. Any KMS grants, resource-based policies, or trust relationships that were scoped to the old Role ID will silently break. This is a hidden cost of manually deleting named IAM roles.

---

## 11. Troubleshooting reference

| Symptom | Cause | Fix |
|---|---|---|
| `Reserved keys used in this request: AWS_REGION` | Tried to set a Lambda-reserved env var | Remove `AWS_REGION` from `--environment` in `deploy.sh` |
| `iam:GetRole` access denied during deploy | Ingestion user has no IAM read permissions | Pass `ROLE_ARN=... bash deploy.sh` directly |
| `surfalytics-lambda-github-role already exists in stack ...` | Old CF stack still claims ownership of the role | Delete the old stack by ARN, then redeploy |
| `Stack does not exist` when you know it was just deployed | Wrong region — `local` profile defaults to `us-west-2` | Add `--region us-east-1` to every CLI command |
| `KMSAccessDeniedException` on invoke | Lambda role was deleted/recreated; old KMS grant tied to old Role ID | Retire old grant with `aws kms retire-grant`, clear and re-add env vars |
| `Task timed out after 3.00 seconds` | Default Lambda timeout is 3s | `deploy.sh` sets it to 300s; verify with `aws lambda get-function-configuration` |
| `No module named 'pandas'` | Layer ARN is wrong for your region | Check the [AWS SDK for pandas Layer ARNs](https://aws-sdk-pandas.readthedocs.io/en/stable/install.html) |
| `No module named 'requests'` | ZIP build failed silently | Re-run `deploy.sh`; check for pip errors in output |
| `AccessDenied` on S3 | Lambda role missing S3 policy | Verify `surfalytics-03-lambda` CF stack is deployed and its outputs show the role ARN |

---

## 12. Success checklist

- [ ] `surfalytics-03-lambda` CF stack is `CREATE_COMPLETE` in `us-east-1`
- [ ] `aws iam get-role --role-name surfalytics-lambda-github-role --profile local` returns the role
- [ ] `deploy.sh` completes without errors and prints the function ARN
- [ ] `aws lambda get-function-configuration` shows `State: Active` and `Timeout: 300`
- [ ] CLI invocation returns `{"statusCode": 200, "body": "Uploaded ... rows to s3://..."}`
- [ ] `aws s3 ls s3://surfalytics-raw-csv-180795190369/github-data/` shows a new timestamped CSV
- [ ] CloudWatch log group `/aws/lambda/surfalytics-github-ingest` exists and has log events from the run
