# AWS Lambda in a Nutshell — and Data Engineering

## What Lambda is

**AWS Lambda** runs your code **without you managing servers**. You upload a function (or a container image); AWS runs it when something **triggers** it — an API call, a schedule, a file landing in S3, a message on a queue, and many other integrations.

In one sentence: **on-demand, short-lived compute** that scales automatically and you pay roughly for **invocation count + duration × memory**, not for idle servers.

Typical characteristics:

| Aspect | What it means |
|--------|----------------|
| **Execution model** | One invocation = one isolated run of your handler (with optional concurrency limits). |
| **Duration** | Standard functions are capped at **15 minutes** per invocation (hard limit). |
| **Scaling** | Many invocations can run in parallel; cold starts happen when a new execution environment spins up. |
| **State** | Ephemeral local disk (`/tmp`, size-limited); durable state belongs in **S3**, databases, queues, etc. |
| **Networking** | Can reach VPC resources (with configuration), public APIs, and AWS services via the SDK. |

Lambda is **not** a replacement for a 24-hour Spark cluster or a warehouse — it is a **building block** for **event-driven** and **orchestrated** work.

---

## How Data Engineering uses Lambda

Data engineers care about **ingesting**, **transforming**, **orchestrating**, and **delivering** data reliably. Lambda fits specific slots in that landscape.

### 1. **Lightweight pipelines and glue steps**

Run a small, well-defined step when something happens:

- **Ingest**: Pull from an HTTP API (like this repo’s GitHub → CSV → S3 pattern), receive a webhook, or read a bounded batch from an API.
- **Land**: Write results to **S3** as CSV, JSON, Parquet (often with layers or slim dependencies), or send records to **Kinesis** / **SQS**.
- **Notify**: On success or failure, publish to **SNS**, call another system, or record lineage in a metadata store.

Each step can be its own function, chained by **events** or **workflows** (see below).

### 2. **Transformations (when they fit)**

Lambda is suitable for **row- or file-bounded** transforms that finish within **timeout and memory** limits:

- **File-at-a-time** or **small batch**: e.g. parse a dropped JSON file, normalize fields, write Parquet to a curated prefix.
- **Streaming micro-batches**: with **Kinesis** or **DynamoDB streams**, process windows of records (still subject to time and memory).
- **Pandas / Polars-style** jobs on **moderate** inputs — often paired with an **S3 trigger** so each object gets its own invocation (natural parallelism).

Avoid putting **heavy** distributed transforms (huge joins, full-table scans) on a single Lambda unless you deliberately shard work (many Lambdas, each with a slice).

### 3. **Orchestration: pipelines without one giant script**

Lambda rarely *is* the whole pipeline; it **executes steps** while something else **coordinates**:

- **AWS Step Functions** — state machine: Lambda for step A → choice/wait → Lambda for step B → parallel branches. Good for **multi-stage DE pipelines** with retries, human approval, or long waits between steps.
- **Amazon EventBridge (CloudWatch Events) rules** — **cron** or pattern-based triggers: “every night run the ingest Lambda,” “when this event fires, run validation.”
- **S3 event notifications** — new object in `raw/` triggers a **normalize** Lambda writing to `processed/`.
- **SQS** — decouple producers and consumers; Lambda scales with queue depth (with reserved concurrency tuning to protect downstream systems).

This is how you build **maintainable pipelines**: small functions, explicit orchestration, retries at the workflow layer.

### 4. **Operational patterns that matter for DE**

- **Idempotency**: Same event twice should not corrupt data (use deterministic keys, upserts, or dedupe tables).
- **Dead-letter queues (DLQ)**: Failed async invocations can land in **SQS DLQ** for replay or inspection.
- **Observability**: **CloudWatch Logs** per invocation; metrics for errors, duration, throttles — essential for pipeline SLAs.
- **Secrets**: Pull tokens from **Secrets Manager** or **Parameter Store** (as in this lab), not hard-coded in the bundle.

---

## When to prefer something else

| Need | Often better than Lambda alone |
|------|----------------------------------|
| **> 15 min** or very large in-memory data | **AWS Glue**, **EMR**, **Batch** + containers, self-managed Spark. |
| **Complex SQL / warehouse transforms** | **Redshift**, **Snowflake**, **BigQuery**, **Athena** (engine choice depends on stack). |
| **Always-on streaming** at very high scale | **Kinesis Data Analytics**, **MSK + Flink**, managed stream processors. |
| **Heavy ML training** | **SageMaker**, dedicated GPU/training jobs. |

Lambda still pairs well: e.g. Lambda **starts** a Glue job or **passes** parameters to Step Functions that run Glue.

---

## This repository’s example

The **`surfalytics-github-ingest`** function in this folder is a minimal **DE pattern**: **scheduled or on-demand ingest** → transform in memory to a tabular shape → **write an artifact to S3** with a timestamped key. The same ideas extend to validation, partitioning, or handing off to downstream tools (Athena, dbt in CI, etc.).

---

## Further reading (AWS)

- [What is AWS Lambda?](https://docs.aws.amazon.com/lambda/latest/dg/welcome.html)
- [Lambda for data processing patterns](https://docs.aws.amazon.com/lambda/latest/dg/with-s3-example.html) (S3-trigger examples)
- [Step Functions for ETL workflows](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html)
