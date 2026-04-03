# Week 1: Local Python Development — Setup and execution

This document walks through accounts, local tooling, running the extractor, and what to expect from the GitHub API and output data.

---

## 1. Prerequisites (accounts and services)

### 1.1 Snowflake (for the wider program)

1. Sign up for a [Snowflake trial](https://signup.snowflake.com/) (or use your organization’s Coursera-linked extended trial if applicable).
2. Complete any trial activation steps in the Snowflake UI.
3. **Save connection details** (you will use them in later weeks): account identifier, user, role, warehouse, database/schema as needed.

> Week 1 does not require Snowflake to run the Python script; it is listed so your accounts are ready for the full pipeline.

### 1.2 AWS

1. Create an AWS account (or use an existing one).
2. Create an **IAM user** (programmatic access) with a policy that allows writing to your target bucket, for example:
   - `s3:PutObject`, `s3:GetObject` (optional), `s3:ListBucket` on `arn:aws:s3:::YOUR_BUCKET` and `arn:aws:s3:::YOUR_BUCKET/*`.
3. Create an **S3 bucket** for raw CSV (choose a globally unique name; pick a region and note it).
4. Configure **AWS CLI** locally (`aws configure`) **or** rely on environment variables / instance role. The Python script uses **boto3**, which reads the [standard AWS credential chain](https://boto3.amazonaws.com/v1/documentation/api/latest/guide/credentials.html).

### 1.3 GitHub repository

1. On GitHub, create a repository named **`data-ingestion-github-to-snowflake`** (or match your org naming).
2. Initialize with a **README** (this folder’s `README.md` can be pushed as a starting point).
3. **Branching (recommended)**:
   - `main` — release / stable
   - `develop` — day-to-day integration  
   Create `develop` from `main`, then use feature branches off `develop` if you like.

---

## 2. Local Python environment

### 2.1 Why a virtual environment (venv)?

A venv isolates this project’s packages from your system Python so versions do not clash and `requirements.txt` reproduces the same stack for teammates and CI.

Alternatives: **Poetry**, **uv**, **pipenv** — same idea, different UX and lockfile formats.

### 2.2 Commands (macOS / Linux)

```bash
cd local_python_development
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

Windows (PowerShell):

```powershell
python -m venv venv
.\venv\Scripts\activate
pip install --upgrade pip
pip install -r requirements.txt
```

### 2.3 Requirements file

`requirements.txt` is the “shopping list” of packages. This repo’s file was generated after installing `requests`, `boto3`, and `pandas` and running `pip freeze > requirements.txt`.

To refresh after you add packages:

```bash
pip freeze > requirements.txt
```

---

## 3. GitHub API: rate limits and design choices

### 3.1 Which endpoint?

- **Search API** (`/search/repositories`) returns at most **1,000 results per query** and has its own throttling. That complicates “1000+” in a single stream.
- This project uses **`GET /repositories`** with the **`since`** cursor (repository `id`), which returns public repositories in creation order and supports collecting **more than 1,000** rows across pages.

### 3.2 Rate limits (summary)

| Client | REST API (typical) | Notes |
|--------|--------------------|--------|
| **Unauthenticated** | **60 requests per hour** per IP | Enough for 10+ pages at 100 repos/page → 1,000+ repos if each call returns 100 items. |
| **Authenticated** (`GITHUB_TOKEN` or `GH_TOKEN`) | **5,000 requests per hour** | Personal access token (classic) with at least `public_repo` scope, or fine-grained token with read access to public repos as documented by GitHub. |

The script reads `X-RateLimit-Remaining` / `X-RateLimit-Reset` and **waits** when GitHub reports exhaustion (403 or remaining = 0).

**Recommendation:** export a token for demos and reliability:

```bash
export GITHUB_TOKEN=ghp_xxxxxxxx   # or GH_TOKEN
```

### 3.3 Response shape (high level)

Each item from `/repositories` is a JSON object. The script **requires** `id`, `full_name`, and `node_id` and **validates** numeric fields where used. It then **flattens** a subset into CSV columns (see section 5).

---

## 4. Running the extraction script

### 4.1 Dry run (no S3)

Writes a timestamped CSV in the current directory and skips upload:

```bash
source venv/bin/activate
python src/extract_github_data.py --dry-run --target-rows 1000
```

Optional: choose output path:

```bash
python src/extract_github_data.py --dry-run --target-rows 1000 --local-csv ./out/sample.csv
```

### 4.2 Upload to S3

Set bucket and region (region should match the bucket):

```bash
export S3_BUCKET=your-unique-bucket-name
export AWS_REGION=us-east-1          # or AWS_DEFAULT_REGION
export S3_PREFIX=github-data        # optional; default is github-data
python src/extract_github_data.py --target-rows 1000
```

Object key pattern:

`{S3_PREFIX}/github_repos_YYYYMMDD_HHMMSS.csv` (UTC timestamp)

### 4.3 Useful flags

| Flag / env | Meaning |
|------------|---------|
| `--target-rows` / `TARGET_ROWS` | How many **valid** rows to collect (default 1000) |
| `--per-page` / `PER_PAGE` | Page size for `/repositories` (max **100**) |
| `--s3-bucket` / `S3_BUCKET` | Destination bucket |
| `--s3-prefix` / `S3_PREFIX` | Key prefix |
| `--aws-region` / `AWS_REGION` | Region for boto3 S3 client |
| `--dry-run` | No S3; write local CSV |

---

## 5. Data quality and CSV schema

### 5.1 Checks performed

- JSON must decode to a **list** of objects for each page.
- Each kept record must include **`id`**, **`full_name`**, **`node_id`**.
- **`id`** must be an integer.
- **`stargazers_count`**, **`forks_count`**, **`open_issues_count`**, **`size`** (if present) must be integers **≥ 0**.

Invalid rows are **logged and skipped** (not uploaded).

### 5.2 CSV columns (flattened)

| Column | Description |
|--------|-------------|
| `id` | Numeric repository id (cursor for pagination) |
| `node_id` | GitHub GraphQL node id |
| `name` | Short name |
| `full_name` | `owner/repo` |
| `private` | Boolean |
| `owner_login` | Owner login |
| `html_url` | Web URL |
| `description` | Truncated to 2000 characters |
| `fork` | Boolean |
| `created_at` / `updated_at` / `pushed_at` | ISO timestamps from API |
| `size` | Size on disk (GitHub field) |
| `stargazers_count` / `watchers_count` | Counts |
| `language` | Primary language |
| `forks_count` / `open_issues_count` | Counts |
| `archived` | Boolean |
| `default_branch` | Branch name |

---

## 6. Success criteria checklist

- [ ] **1000+ repositories** in one CSV (use `--target-rows 1000` or higher; with a token, runs complete faster).
- [ ] **CSV in S3** with timestamped key under your prefix.
- [ ] **Rate limiting**: script sleeps until `X-RateLimit-Reset` when limited (watch logs).
- [ ] **Logging**: INFO lines for page progress; WARNING for skipped bad rows or short runs.
- [ ] **Repo structure**: `src/extract_github_data.py`, `requirements.txt`, this doc, `README.md`.

---

## 7. Troubleshooting

| Symptom | What to try |
|---------|--------------|
| `Only collected N rows` | Unauthenticated hourly cap or network issues; set `GITHUB_TOKEN` and retry, or wait for reset. |
| S3 `AccessDenied` | IAM policy on bucket/prefix; confirm bucket name and region. |
| `SSL` / proxy errors | Corporate proxy: configure `HTTP_PROXY`/`HTTPS_PROXY` or system trust store. |
| Empty CSV | Check logs for validation failures; GitHub outage rare but possible — retry. |

---

## 8. Findings to record (for your own notes)

After your first successful run, jot down:

1. Approximate **duration** and whether you used a token.
2. **Final row count** and S3 **URI** of the uploaded object.
3. Any **rate-limit** waits (from logs) and **reset time**.
4. **Snowflake** account locator (for later ingestion steps).

This completes the Week 1 local execution path from “venv + requirements” through “validated CSV on S3.”
