"""
Extract public GitHub repositories and save as CSV or upload to S3.

This script:
  1. Gets a GitHub token from environment variables or AWS Secrets Manager
  2. Fetches public repositories from the GitHub API
  3. Picks the fields we care about from each repository
  4. Saves the results as a CSV file locally or uploads to S3

Usage:
  python extract_github_data.py --dry-run                          # save locally
  python extract_github_data.py --dry-run --target-rows 100        # fewer rows
  python extract_github_data.py                                    # upload to S3
"""

import argparse
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone

import boto3
import pandas as pd
import requests
from rich.logging import RichHandler
from rich.console import Console
from rich import print_json

# --- Settings ---

GITHUB_API = "https://api.github.com/repositories"
DEFAULT_SECRET_NAME = "surfalytics/data-ingestion/github-token"
DEFAULT_REGION = "us-east-1"
DEFAULT_PROFILE = "surfalytics-lab"
DEFAULT_BUCKET = "surfalytics-raw-csv-180795190369"
DEFAULT_S3_PREFIX = "github-data"
DEFAULT_TARGET_ROWS = 1000

# --- Logging with colors (via rich) ---

console = Console()
logging.basicConfig(
    level=logging.INFO,
    format="%(message)s",
    datefmt="[%Y-%m-%d %H:%M:%S]",
    handlers=[RichHandler(console=console, rich_tracebacks=True, show_path=False)],
)
logger = logging.getLogger(__name__)


# --- GitHub Token ---


def get_github_token():
    """
    Get the GitHub API token.

    Checks two places in order:
      1. Environment variables: GITHUB_TOKEN or GH_TOKEN
      2. AWS Secrets Manager: reads the secret named in DEFAULT_SECRET_NAME

    Returns:
        str or None: The token string, or None if no token was found.
    """
    # 1. Check environment variables
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        logger.debug("Found token in environment variable")
        return token.strip()

    # 2. Try AWS Secrets Manager
    secret_name = os.environ.get("GITHUB_TOKEN_SECRET_NAME", DEFAULT_SECRET_NAME)
    region = os.environ.get("AWS_REGION", DEFAULT_REGION)
    logger.debug("Looking for token in Secrets Manager: %s (%s)", secret_name, region)

    try:
        client = boto3.client("secretsmanager", region_name=region)
        resp = client.get_secret_value(SecretId=secret_name)
        secret = resp["SecretString"].strip()
    except Exception as e:
        logger.warning("Could not get token from Secrets Manager: %s", e)
        return None

    # The secret might be a plain token string or a JSON object
    if secret.startswith("{"):
        try:
            data = json.loads(secret)
            for key in ("github_token", "token", "GITHUB_TOKEN", "gh_token"):
                if key in data:
                    return data[key].strip()
        except json.JSONDecodeError:
            pass

    logger.debug("Got token from Secrets Manager")
    return secret


# --- GitHub API ---


def create_session(token):
    """
    Create a reusable HTTP session for the GitHub API.

    Sets the required Accept header. If a token is provided, adds it as
    a Bearer token so we get 5,000 requests/hour instead of 60.

    Args:
        token (str or None): GitHub personal access token.

    Returns:
        requests.Session: Configured session ready to make API calls.
    """
    session = requests.Session()
    session.headers["Accept"] = "application/vnd.github+json"
    if token:
        session.headers["Authorization"] = f"Bearer {token}"
    return session


def fetch_repos_page(session, since_id):
    """
    Fetch one page of repositories from the GitHub API.

    Uses the /repositories endpoint with `since` pagination. Each call
    returns up to 100 repos. Pass the last repo's ID as since_id to get
    the next page.

    If we hit a rate limit (HTTP 403), waits until the limit resets and
    retries once.

    Args:
        session (requests.Session): HTTP session from create_session().
        since_id (int or None): Fetch repos with ID greater than this.
                                 Pass None for the first page.

    Returns:
        list[dict]: List of raw repository JSON objects from GitHub.
    """
    params = {"per_page": 100}
    if since_id is not None:
        params["since"] = since_id

    logger.debug("Fetching repos page (since_id=%s)", since_id)
    response = session.get(GITHUB_API, params=params, timeout=30)

    # If rate limited, wait and retry once
    if response.status_code == 403 and "rate limit" in response.text.lower():
        reset_time = float(response.headers.get("X-RateLimit-Reset", time.time() + 60))
        wait = max(reset_time - time.time(), 0) + 2
        logger.warning("Rate limited. Waiting %.0f seconds...", wait)
        time.sleep(wait)
        response = session.get(GITHUB_API, params=params, timeout=30)

    response.raise_for_status()

    # Log rate limit info
    remaining = response.headers.get("X-RateLimit-Remaining")
    limit = response.headers.get("X-RateLimit-Limit")
    if remaining and limit:
        logger.debug("Rate limit: %s/%s remaining", remaining, limit)

    return response.json()


def pick_fields(repo):
    """
    Pick the fields we want from a single GitHub repository.

    Takes the full JSON object that GitHub returns and extracts only
    the 17 columns we need for our CSV. Truncates description to
    2000 characters.

    Args:
        repo (dict): Raw repository JSON from the GitHub API.

    Returns:
        dict: Clean dictionary with only the fields we care about.
    """
    owner = repo.get("owner") or {}
    return {
        "id": repo["id"],
        "name": repo.get("name"),
        "full_name": repo.get("full_name"),
        "owner_login": owner.get("login"),
        "html_url": repo.get("html_url"),
        "description": (repo.get("description") or "")[:2000],
        "fork": repo.get("fork"),
        "language": repo.get("language"),
        "stargazers_count": repo.get("stargazers_count"),
        "forks_count": repo.get("forks_count"),
        "open_issues_count": repo.get("open_issues_count"),
        "size": repo.get("size"),
        "created_at": repo.get("created_at"),
        "updated_at": repo.get("updated_at"),
        "pushed_at": repo.get("pushed_at"),
        "archived": repo.get("archived"),
        "default_branch": repo.get("default_branch"),
    }


def collect_repos(session, target_rows):
    """
    Fetch repositories page by page until we reach the target count.

    Calls fetch_repos_page() in a loop. Each iteration gets up to 100
    repos, extracts the fields with pick_fields(), and adds them to the
    list. Prints a sample of the first repo's JSON on the first page.

    Args:
        session (requests.Session): HTTP session from create_session().
        target_rows (int): How many repositories to collect.

    Returns:
        list[dict]: List of cleaned repository dictionaries.
    """
    rows = []
    since_id = None
    first_page = True

    while len(rows) < target_rows:
        repos = fetch_repos_page(session, since_id)
        if not repos:
            logger.warning("No more repositories returned")
            break

        # Print a sample of raw JSON from the first repo on the first page
        if first_page and repos:
            logger.info("Sample raw JSON from GitHub API (first repo):")
            print_json(data=repos[0])
            first_page = False

        for repo in repos:
            rows.append(pick_fields(repo))

        since_id = repos[-1]["id"]
        logger.info(
            "Collected [bold green]%s[/] rows (target %s)",
            len(rows),
            target_rows,
            extra={"markup": True},
        )

    return rows[:target_rows]


# --- Output ---


def save_csv(rows, path):
    """
    Save a list of repository dicts to a local CSV file.

    Creates the output directory if it doesn't exist. Uses pandas
    to write the CSV with headers.

    Args:
        rows (list[dict]): Repository data from collect_repos().
        path (str): File path to write the CSV to (e.g. ./out/sample.csv).
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    df = pd.DataFrame(rows)
    df.to_csv(path, index=False)
    logger.info("Saved [bold green]%s rows[/] to %s", len(df), path, extra={"markup": True})

    # Print a sample of the first 3 rows
    logger.info("Sample output (first 3 rows):")
    console.print(df.head(3).to_string(index=False))


def upload_to_s3(rows, bucket, prefix, region):
    """
    Upload repository data as a CSV file to an S3 bucket.

    Converts the rows to CSV, generates a timestamped file name
    like github_repos_20260403_120000.csv, and uploads it.

    Args:
        rows (list[dict]): Repository data from collect_repos().
        bucket (str): S3 bucket name.
        prefix (str): Folder prefix inside the bucket (e.g. github-data).
        region (str): AWS region (e.g. us-east-1).
    """
    df = pd.DataFrame(rows)
    csv_body = df.to_csv(index=False).encode("utf-8")

    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    key = f"{prefix}/github_repos_{timestamp}.csv"

    logger.info("Uploading to s3://%s/%s ...", bucket, key)
    client = boto3.client("s3", region_name=region)
    client.put_object(Bucket=bucket, Key=key, Body=csv_body, ContentType="text/csv")
    logger.info(
        "Uploaded [bold green]s3://%s/%s[/] (%s bytes)",
        bucket, key, len(csv_body),
        extra={"markup": True},
    )


# --- Main ---


def parse_args():
    """
    Parse command-line arguments.

    Returns:
        argparse.Namespace with these fields:
            target_rows (int): Number of repos to collect.
            s3_bucket (str): S3 bucket name.
            s3_prefix (str): S3 key prefix.
            aws_region (str): AWS region.
            aws_profile (str): AWS CLI profile name.
            dry_run (bool): If True, save locally instead of S3.
            local_csv (str): Local file path for dry-run output.
            verbose (bool): If True, enable DEBUG-level logging.
    """
    p = argparse.ArgumentParser(description="Extract GitHub repos to CSV / S3")
    p.add_argument("--target-rows", type=int, default=DEFAULT_TARGET_ROWS, help="Number of repos to collect")
    p.add_argument("--s3-bucket", default=os.environ.get("S3_BUCKET", DEFAULT_BUCKET), help="S3 bucket name")
    p.add_argument("--s3-prefix", default=DEFAULT_S3_PREFIX, help="S3 key prefix")
    p.add_argument("--aws-region", default=os.environ.get("AWS_REGION", DEFAULT_REGION), help="AWS region")
    p.add_argument("--aws-profile", default=os.environ.get("AWS_PROFILE", DEFAULT_PROFILE), help="AWS profile")
    p.add_argument("--dry-run", action="store_true", help="Save locally instead of uploading to S3")
    p.add_argument("--local-csv", default="./out/github_repos.csv", help="Local CSV path (used with --dry-run)")
    p.add_argument("--verbose", "-v", action="store_true", help="Enable detailed debug logging")
    return p.parse_args()


def main():
    """
    Main entry point. Runs the full pipeline:
      1. Parse arguments and set AWS profile
      2. Get GitHub token (env var or Secrets Manager)
      3. Fetch repositories from GitHub API
      4. Save to local CSV (--dry-run) or upload to S3

    Returns:
        int: Exit code (0 = success, 1 = error).
    """
    args = parse_args()

    # Enable verbose logging if requested
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
        logger.debug("Verbose logging enabled")

    # Set AWS profile so boto3 can find credentials
    if args.aws_profile:
        os.environ["AWS_PROFILE"] = args.aws_profile
        logger.debug("Using AWS profile: %s", args.aws_profile)

    # Log settings
    logger.info("Settings: target_rows=%s, region=%s, profile=%s", args.target_rows, args.aws_region, args.aws_profile)
    if args.dry_run:
        logger.info("Mode: [bold yellow]dry-run[/] (saving to %s)", args.local_csv, extra={"markup": True})
    else:
        logger.info("Mode: [bold cyan]S3 upload[/] (bucket=%s)", args.s3_bucket, extra={"markup": True})

    # Get GitHub token
    token = get_github_token()
    if token:
        logger.info("[bold green]GitHub token found[/] — 5,000 requests/hour", extra={"markup": True})
    else:
        logger.warning("[bold yellow]No token found[/] — 60 requests/hour (unauthenticated)", extra={"markup": True})

    # Fetch repos
    session = create_session(token)
    rows = collect_repos(session, args.target_rows)
    logger.info("Collected [bold]%s rows[/] total", len(rows), extra={"markup": True})

    if not rows:
        logger.error("No rows collected")
        return 1

    # Save or upload
    if args.dry_run:
        save_csv(rows, args.local_csv)
    else:
        upload_to_s3(rows, args.s3_bucket, args.s3_prefix, args.aws_region)

    logger.info("[bold green]Done![/]", extra={"markup": True})
    return 0


if __name__ == "__main__":
    sys.exit(main())
