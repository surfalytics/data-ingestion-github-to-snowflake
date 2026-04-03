# Week 2: Docker Container — Setup and execution

This document walks through prerequisites, building the Docker image, and running the GitHub extractor inside a container that uploads directly to S3.

---

## 1. Prerequisites

### 1.1 Docker

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Mac/Windows) or Docker Engine (Linux).

Verify it is running:

```bash
docker --version
docker info
```

### 1.2 AWS credentials

The container has no `~/.aws` directory, so credentials must be passed as environment variables:

| Variable | Description |
|----------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `AWS_REGION` | Region of your S3 bucket (e.g. `us-east-1`) |
| `S3_BUCKET` | Target bucket name |

The IAM user needs `s3:PutObject` on `arn:aws:s3:::YOUR_BUCKET/*`.

Use your existing AWS profile to get the values:

```bash
aws configure get aws_access_key_id     --profile surfalytics-lab
aws configure get aws_secret_access_key --profile surfalytics-lab
aws configure get region                --profile surfalytics-lab
```

### 1.3 GitHub token (via AWS Secrets Manager)

Without a token the GitHub API allows 60 requests/hour (enough for 1,000 repos but slow). With a token you get 5,000 requests/hour.

The script fetches the token automatically from AWS Secrets Manager using the secret named `surfalytics/data-ingestion/github-token`. As long as your AWS credentials in `.env` have `secretsmanager:GetSecretValue` permission on that secret, no extra configuration is needed.

---

## 2. Project layout

| Path | Purpose |
|------|---------|
| `Dockerfile` | Image definition — Python 3.11-slim, installs deps, copies `src/` |
| `requirements.txt` | Pinned dependencies (same as Week 1 + `rich`) |
| `src/extract_github_data.py` | Same extraction script as Week 1 |
| `WEEK2_DOCKER_SETUP_AND_EXECUTION.md` | This document |

---

## 3. Why Docker?

| Local venv (Week 1) | Docker container (Week 2) |
|---------------------|--------------------------|
| Tied to your machine's Python version | Reproducible across any host with Docker |
| Manual `source venv/bin/activate` | Single `docker run` command |
| AWS profile read from `~/.aws` | Credentials injected as env vars |
| Hard to hand off to CI/CD | Drop-in for GitHub Actions, ECS, Lambda containers |

---

## 4. Build the image

From the `02_docker_container/` directory:

```bash
docker build -t surfalytics-github-ingest .
```

Expected output ends with:

```
Successfully built <sha>
Successfully tagged surfalytics-github-ingest:latest
```

You only need to rebuild when `Dockerfile`, `requirements.txt`, or `src/` files change.

---

## 5. Running the container

### 5.1 Upload to S3 (standard run)

**Recommended: use a `.env` file** so secrets stay out of your shell history.

Copy the example and fill in your values:

```bash
cp .env.example .env
# edit .env with your actual credentials
```

`.env` contents:

```
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=your-secret
AWS_REGION=us-east-1
S3_BUCKET=surfalytics-raw-csv-180795190369
```

> Do **not** include `AWS_PROFILE` in `.env`. If it is present (even as an empty string), boto3 tries to resolve the profile name and fails with `ProfileNotFound`. Omitting it entirely lets boto3 fall back to `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` directly.

Then run with `--env-file`:

```bash
docker run --rm --env-file .env surfalytics-github-ingest --target-rows 1000
```

`.env` is listed in `.gitignore` — it will never be committed. `.env.example` (no real values) is committed as a template.

Object key written to S3:

```
github-data/github_repos_YYYYMMDD_HHMMSS.csv
```

### 5.2 Dry run (save CSV locally)

Mount a host directory to `/app/out` and use `--dry-run`:

```bash
docker run --rm \
  -v $(pwd)/out:/app/out \
  surfalytics-github-ingest --dry-run --target-rows 1000 --local-csv /app/out/github_repos.csv --aws-profile ""
```

The CSV appears at `./out/github_repos.csv` on your host.

### 5.3 Useful flags

| Flag / env var | Meaning |
|----------------|---------|
| `--target-rows` / `TARGET_ROWS` | Number of valid rows to collect (default 1000) |
| `--s3-bucket` / `S3_BUCKET` | Destination bucket |
| `--s3-prefix` / `S3_PREFIX` | Key prefix (default `github-data`) |
| `--aws-region` / `AWS_REGION` | AWS region |
| `--aws-profile ""` | Must be empty string in Docker (no profile file) |
| `--dry-run` | Skip S3; write local CSV |
| `--local-csv` | Local CSV path (used with `--dry-run`) |
| `--verbose` / `-v` | Enable DEBUG-level logging |

---

## 6. What to expect in the logs

```
INFO  Settings: target_rows=1000, region=us-east-1, profile=
INFO  Mode: S3 upload (bucket=surfalytics-raw-csv-...)
INFO  GitHub token found — 5,000 requests/hour
INFO  Sample raw JSON from GitHub API (first repo): ...
INFO  Collected 100 rows (target 1000)
...
INFO  Collected 1000 rows (target 1000)
INFO  Collected 1000 rows total
INFO  Uploading to s3://surfalytics-raw-csv-.../github-data/github_repos_....csv ...
INFO  Uploaded s3://surfalytics-raw-csv-.../github-data/github_repos_....csv (162426 bytes)
INFO  Done!
```

---

## 7. Differences from Week 1

| Topic | Week 1 (local) | Week 2 (Docker) |
|-------|---------------|-----------------|
| Python environment | `venv` activated manually | Baked into image |
| `rich` in requirements | Missing (installed ad-hoc) | Pinned at `13.9.4` |
| AWS credentials | Read from `~/.aws` via named profile | Env vars passed to container |
| `--aws-profile` | `surfalytics-lab` | Must be `""` (empty) |
| Output | Local CSV or S3 | Local CSV (via volume mount) or S3 |

---

## 8. Troubleshooting

| Symptom | What to try |
|---------|-------------|
| `ProfileNotFound: surfalytics-lab` or `ProfileNotFound: ` | Remove `AWS_PROFILE` from `.env` entirely — even an empty value triggers this error |
| `AccessDenied` on S3 upload | Check `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` are exported; verify IAM policy has `s3:PutObject` |
| `Cannot connect to the Docker daemon` | Start Docker Desktop |
| `Only collected N rows` with no token | Secrets Manager fetch failed — check IAM has `secretsmanager:GetSecretValue` on the secret |
| CSV missing on host after dry-run | Confirm `-v $(pwd)/out:/app/out` is in the command and `--local-csv /app/out/github_repos.csv` |

---

## 9. Success criteria checklist

- [ ] `docker build` completes without errors.
- [ ] Container runs and logs show `Done!`.
- [ ] S3 object visible at `s3://<bucket>/github-data/github_repos_<timestamp>.csv`.
- [ ] CSV contains 1,000+ rows with correct column headers.
