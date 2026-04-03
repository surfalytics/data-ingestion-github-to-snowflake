#!/bin/bash
set -e

# ── Configuration ─────────────────────────────────────────────────────────────
AWS_PROFILE="surfalytics-lab"
AWS_REGION="us-east-1"
FUNCTION_NAME="surfalytics-github-ingest"
S3_BUCKET="surfalytics-raw-csv-180795190369"
ROLE_NAME="surfalytics-lambda-github-role"
RUNTIME="python3.11"
HANDLER="extract_github_data.lambda_handler"
TIMEOUT=300      # seconds (max 900)
MEMORY=512       # MB

# AWS managed layer: pandas + numpy for Python 3.11
PANDAS_LAYER_ARN="arn:aws:lambda:${AWS_REGION}:336392948345:layer:AWSSDKPandas-Python311:23"

export AWS_PROFILE AWS_REGION

# ── Step 1: Build ZIP ──────────────────────────────────────────────────────────
echo ">>> Building deployment ZIP..."
rm -rf package && mkdir package

# Install only what's not in the pandas layer (requests + rich)
pip install requests rich --quiet --target package/

# Copy the handler
cp src/extract_github_data.py package/

cd package && zip -r ../function.zip . -x "*.pyc" -x "*/__pycache__/*" > /dev/null
cd ..
echo "    ZIP size: $(du -sh function.zip | cut -f1)"

# ── Step 2: Resolve IAM role ──────────────────────────────────────────────────
# Set ROLE_ARN as an env var to skip this lookup, e.g.:
#   ROLE_ARN=arn:aws:iam::123456789:role/my-role bash deploy.sh
echo ">>> Resolving IAM role..."
if [ -z "$ROLE_ARN" ]; then
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.Arn' --output text 2>/dev/null || true)
fi

if [ -z "$ROLE_ARN" ]; then
  echo ""
  echo "ERROR: IAM role '$ROLE_NAME' not found and ROLE_ARN not set."
  echo ""
  echo "Create the role manually in the AWS Console:"
  echo "  1. Go to IAM → Roles → Create role"
  echo "  2. Trusted entity: AWS service → Lambda"
  echo "  3. Attach policies:"
  echo "     - AWSLambdaBasicExecutionRole"
  echo "     - AmazonS3FullAccess"
  echo "     - SecretsManagerReadWrite"
  echo "  4. Name it: $ROLE_NAME"
  echo "  5. Re-run with the ARN:"
  echo "     ROLE_ARN=arn:aws:iam::<account-id>:role/$ROLE_NAME bash deploy.sh"
  exit 1
fi
echo "    Using role: $ROLE_ARN"

# ── Step 3: Create or update Lambda function ──────────────────────────────────
echo ">>> Deploying Lambda function: $FUNCTION_NAME"
EXISTING=$(aws lambda get-function --function-name "$FUNCTION_NAME" \
  --query 'Configuration.FunctionName' --output text 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
  echo "    Creating new function..."
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime "$RUNTIME" \
    --role "$ROLE_ARN" \
    --handler "$HANDLER" \
    --zip-file fileb://function.zip \
    --timeout "$TIMEOUT" \
    --memory-size "$MEMORY" \
    --layers "$PANDAS_LAYER_ARN" \
    --environment "Variables={S3_BUCKET=$S3_BUCKET,AWS_REGION=$AWS_REGION}" \
    --output text --query 'FunctionArn'
else
  echo "    Updating existing function..."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb://function.zip \
    --output text --query 'FunctionArn'

  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout "$TIMEOUT" \
    --memory-size "$MEMORY" \
    --layers "$PANDAS_LAYER_ARN" \
    --environment "Variables={S3_BUCKET=$S3_BUCKET,AWS_REGION=$AWS_REGION}" \
    --output text --query 'FunctionArn'
fi

echo ""
echo "✓ Done. To invoke:"
echo "  aws lambda invoke --function-name $FUNCTION_NAME --payload '{\"target_rows\":1000}' response.json --profile $AWS_PROFILE && cat response.json"
