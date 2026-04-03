# extract_github_data.py — Guide

This script fetches public GitHub repositories and saves them as a CSV file (locally or to S3).

## What the script does

1. **Gets a GitHub token** — checks `GITHUB_TOKEN` env var first, then pulls it from AWS Secrets Manager
2. **Fetches repositories** — calls the GitHub API page by page (100 repos per page)
3. **Picks the fields we need** — id, name, owner, language, stars, forks, etc.
4. **Saves the output** — writes a CSV file locally (`--dry-run`) or uploads to S3

## Prerequisites

- Python 3.10+
- Install dependencies: `pip install boto3 pandas requests`
- AWS profile `surfalytics-lab` configured (see `infrastructure/scripts/configure-lab-ingestion-profile.sh`)
- GitHub token stored in AWS Secrets Manager (see `infrastructure/scripts/push-github-token-to-secrets-manager.sh`)

## Quick start

```bash
cd 01_local_python_development

# Save 1000 repos to a local CSV
python src/extract_github_data.py --dry-run

# Save to a custom path
python src/extract_github_data.py --dry-run --local-csv ./out/sample.csv

# Collect only 100 repos
python src/extract_github_data.py --dry-run --target-rows 100

# Upload directly to S3 (no --dry-run)
python src/extract_github_data.py
```

## Command-line options

| Flag | Default | Description |
|---|---|---|
| `--target-rows` | `1000` | Number of repositories to collect |
| `--dry-run` | off | Save CSV locally instead of uploading to S3 |
| `--local-csv` | `./out/github_repos.csv` | Local file path (used with `--dry-run`) |
| `--s3-bucket` | `surfalytics-raw-csv-180795190369` | S3 bucket name |
| `--s3-prefix` | `github-data` | Folder prefix inside the S3 bucket |
| `--aws-region` | `us-east-1` | AWS region |
| `--aws-profile` | `surfalytics-lab` | AWS CLI profile for boto3 credentials |

## How the functions work

The script has 7 functions. Here is what each one does:

### `get_github_token()`
Finds the GitHub token. First it checks if `GITHUB_TOKEN` or `GH_TOKEN` is set as an environment variable. If not, it calls AWS Secrets Manager to get the token from the secret named `surfalytics/data-ingestion/github-token`.

### `create_session(token)`
Creates a reusable HTTP connection to the GitHub API. If a token is provided, it adds it to every request so we get higher rate limits (5,000 requests/hour instead of 60).

### `fetch_repos_page(session, since_id)`
Fetches one page of repositories (up to 100) from the GitHub API. The `since_id` parameter tells GitHub to return repos with an ID greater than that number — this is how we paginate through all repos.

### `pick_fields(repo)`
Takes a raw GitHub repository JSON object and returns a clean dictionary with only the 17 fields we care about: id, name, full_name, owner_login, html_url, description, fork, language, stargazers_count, forks_count, open_issues_count, size, created_at, updated_at, pushed_at, archived, default_branch.

### `collect_repos(session, target_rows)`
Calls `fetch_repos_page()` in a loop until we have enough rows. Each loop fetches 100 repos, picks the fields, and adds them to the list. Stops when we reach the target or GitHub runs out of repos.

### `save_csv(rows, path)`
Takes the list of repos and saves it as a CSV file on your computer. Creates the output folder if it does not exist.

### `upload_to_s3(rows, bucket, prefix, region)`
Takes the list of repos, converts to CSV, and uploads the file to an S3 bucket. The file name includes a timestamp like `github_repos_20260403_120000.csv`.

## GitHub token setup

The script needs a GitHub Personal Access Token (PAT) to avoid the 60 requests/hour limit.

1. Create a fine-grained PAT at GitHub > Settings > Developer settings > Fine-grained tokens
2. Push it to AWS Secrets Manager:
   ```bash
   ./infrastructure/scripts/push-github-token-to-secrets-manager.sh "ghp_your_token_here"
   ```
3. The script will automatically find it — no env vars needed

## CSV output columns

| Column | Example |
|---|---|
| id | 1 |
| name | grit |
| full_name | mojombo/grit |
| owner_login | mojombo |
| html_url | https://github.com/mojombo/grit |
| description | Grit gives you object oriented... |
| fork | False |
| language | Ruby |
| stargazers_count | 1953 |
| forks_count | 531 |
| open_issues_count | 40 |
| size | 7954 |
| created_at | 2007-10-29T14:37:16Z |
| updated_at | 2024-01-15T09:51:27Z |
| pushed_at | 2023-09-04T09:39:10Z |
| archived | False |
| default_branch | master |
