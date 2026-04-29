# Week 7 — Amazon EventBridge schedule → Step Functions

This exercise adds a **scheduled EventBridge rule** that calls **`states:StartExecution`** on the same state machine as Week 6 (`surfalytics-github-ingest-pipeline`), so the GitHub ingest workflow runs on a timer without manual `start-execution`.

Infrastructure lives in [`infrastructure/cloudformation/eventbridge-github-ingest-schedule.yaml`](../infrastructure/cloudformation/eventbridge-github-ingest-schedule.yaml).

## Do you use only EventBridge?

For a **recurring time-based** trigger, yes: on AWS you normally use **Amazon EventBridge** (a rule with `ScheduleExpression`: `cron(...)` or `rate(...)`) **or** the newer **EventBridge Scheduler** API. **Step Functions does not include a built-in cron scheduler**; something has to call `StartExecution` (EventBridge, Scheduler, another workflow, an app, etc.). This stack uses the classic **EventBridge rule + target** pattern.

## Prerequisites

1. The **Step Functions** stack is deployed so the state machine exists ([Week 6 `06_aws_step_function_run_lambda`](../06_aws_step_function_run_lambda/)).
2. Deploy with the same account and region as that state machine (default `us-east-1` in the deploy script).

## Deploy

```bash
AWS_PROFILE=local bash infrastructure/scripts/deploy-stack.sh eventbridge
```

By default the template targets the state machine **name** `surfalytics-github-ingest-pipeline` in the **current account and region** (ARN built automatically). That matches `arn:aws:states:us-east-1:180795190369:stateMachine:surfalytics-github-ingest-pipeline` when you deploy from account `180795190369` in `us-east-1`.

To pass an explicit ARN (cross-account is possible with extra IAM trust; not configured here):

```bash
STATE_MACHINE_ARN=arn:aws:states:us-east-1:180795190369:stateMachine:surfalytics-github-ingest-pipeline \
  AWS_PROFILE=local bash infrastructure/scripts/deploy-stack.sh eventbridge
```

Change schedule or input (UTC cron; input must match the state machine):

```bash
SCHEDULE_EXPRESSION='cron(0 14 * * ? *)' \
SCHEDULE_INPUT='{"target_rows":500}' \
  AWS_PROFILE=local bash infrastructure/scripts/deploy-stack.sh eventbridge
```

## Verify

- **EventBridge** console → **Rules** → `surfalytics-github-ingest-pipeline-schedule` → confirm target and schedule.
- After the next run, **Step Functions** → state machine → **Executions** for runs started by `events.amazonaws.com`.

## Cleanup

```bash
AWS_PROFILE=local aws cloudformation delete-stack \
  --stack-name surfalytics-eventbridge-github-ingest --region us-east-1
```
