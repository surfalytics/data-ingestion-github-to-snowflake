"""
Fetch public GitHub repositories via REST API, validate rows, write CSV, upload to S3.

Uses GET /repositories with `since` pagination (not Search), so you can collect 1000+ repos.
Unauthenticated REST rate limit: 60 requests/hour per IP. Set GITHUB_TOKEN for 5,000/hour.
"""

from __future__ import annotations

import argparse
import io
import logging
import os
import sys
import time
from datetime import datetime, timezone
from typing import Any

import boto3
import pandas as pd
import requests
from botocore.exceptions import BotoCoreError, ClientError

GITHUB_API = "https://api.github.com"
DEFAULT_PER_PAGE = 100
REQUIRED_FIELDS = ("id", "full_name", "node_id")
OPTIONAL_NUMERIC_NON_NEGATIVE = ("stargazers_count", "forks_count", "open_issues_count", "size")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


def parse_rate_limit_reset(response: requests.Response) -> float | None:
    reset = response.headers.get("X-RateLimit-Reset")
    if not reset:
        return None
    try:
        return float(reset)
    except ValueError:
        return None


def sleep_until_rate_limit_reset(response: requests.Response) -> None:
    reset_ts = parse_rate_limit_reset(response)
    if reset_ts is None:
        time.sleep(60)
        return
    now = time.time()
    wait = max(reset_ts - now, 0) + 2
    logger.warning("Rate limited; sleeping %.0f seconds until reset", wait)
    time.sleep(wait)


def github_session(token: str | None) -> requests.Session:
    s = requests.Session()
    s.headers["Accept"] = "application/vnd.github+json"
    s.headers["X-GitHub-Api-Version"] = "2022-11-28"
    if token:
        s.headers["Authorization"] = f"Bearer {token}"
    return s


def fetch_repositories_page(
    session: requests.Session,
    since_id: int | None,
    per_page: int,
) -> list[dict[str, Any]]:
    params: dict[str, Any] = {"per_page": min(per_page, 100)}
    if since_id is not None:
        params["since"] = since_id

    url = f"{GITHUB_API}/repositories"
    for attempt in range(5):
        try:
            r = session.get(url, params=params, timeout=60)
        except requests.RequestException as e:
            logger.warning("Request error (attempt %s): %s", attempt + 1, e)
            time.sleep(2**attempt)
            continue

        remaining = r.headers.get("X-RateLimit-Remaining")
        if remaining is not None:
            logger.debug("Rate limit remaining: %s", remaining)

        if r.status_code == 403 and (
            remaining == "0"
            or "rate limit" in (r.text or "").lower()
            or "secondary rate limit" in (r.text or "").lower()
        ):
            sleep_until_rate_limit_reset(r)
            continue

        if r.status_code in (502, 503, 504):
            logger.warning("HTTP %s; retrying in %s s", r.status_code, 2**attempt)
            time.sleep(2**attempt)
            continue

        r.raise_for_status()
        data = r.json()
        if not isinstance(data, list):
            raise ValueError(f"Expected list from /repositories, got {type(data)}")
        return data

    raise RuntimeError("Failed to fetch repositories after retries")


def validate_repo_record(row: dict[str, Any]) -> tuple[bool, str]:
    for field in REQUIRED_FIELDS:
        if field not in row or row[field] is None:
            return False, f"missing required field: {field}"

    if not isinstance(row.get("id"), int):
        return False, "id must be integer"

    for field in OPTIONAL_NUMERIC_NON_NEGATIVE:
        if field in row and row[field] is not None:
            try:
                v = int(row[field])
            except (TypeError, ValueError):
                return False, f"{field} must be numeric"
            if v < 0:
                return False, f"{field} must be >= 0"

    return True, ""


def repos_to_rows(repos: list[dict[str, Any]]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for repo in repos:
        ok, reason = validate_repo_record(repo)
        if not ok:
            logger.warning("Skipping invalid repo: %s", reason)
            continue

        owner = repo.get("owner") or {}
        rows.append(
            {
                "id": repo["id"],
                "node_id": repo.get("node_id"),
                "name": repo.get("name"),
                "full_name": repo.get("full_name"),
                "private": repo.get("private"),
                "owner_login": owner.get("login"),
                "html_url": repo.get("html_url"),
                "description": (repo.get("description") or "")[:2000],
                "fork": repo.get("fork"),
                "created_at": repo.get("created_at"),
                "updated_at": repo.get("updated_at"),
                "pushed_at": repo.get("pushed_at"),
                "size": repo.get("size"),
                "stargazers_count": repo.get("stargazers_count"),
                "watchers_count": repo.get("watchers_count"),
                "language": repo.get("language"),
                "forks_count": repo.get("forks_count"),
                "open_issues_count": repo.get("open_issues_count"),
                "archived": repo.get("archived"),
                "default_branch": repo.get("default_branch"),
            }
        )
    return rows


def dataframe_from_rows(rows: list[dict[str, Any]]) -> pd.DataFrame:
    if not rows:
        return pd.DataFrame()
    return pd.DataFrame(rows)


def csv_bytes_from_dataframe(df: pd.DataFrame) -> bytes:
    buf = io.StringIO()
    df.to_csv(buf, index=False)
    return buf.getvalue().encode("utf-8")


def s3_object_key(prefix: str) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
    p = prefix.strip("/")
    if p:
        return f"{p}/github_repos_{ts}.csv"
    return f"github_repos_{ts}.csv"


def upload_to_s3(
    bucket: str,
    key: str,
    body: bytes,
    region: str | None,
) -> None:
    kwargs: dict[str, Any] = {}
    if region:
        kwargs["region_name"] = region
    client = boto3.client("s3", **kwargs)
    try:
        client.put_object(
            Bucket=bucket,
            Key=key,
            Body=body,
            ContentType="text/csv; charset=utf-8",
        )
    except (ClientError, BotoCoreError) as e:
        logger.exception("S3 upload failed")
        raise RuntimeError(f"S3 upload failed: {e}") from e
    logger.info("Uploaded s3://%s/%s (%s bytes)", bucket, key, len(body))


def collect_repositories(
    session: requests.Session,
    target_count: int,
    per_page: int,
) -> list[dict[str, Any]]:
    all_rows: list[dict[str, Any]] = []
    since_id: int | None = None
    seen_ids: set[int] = set()

    while len(all_rows) < target_count:
        repos = fetch_repositories_page(session, since_id=since_id, per_page=per_page)
        if not repos:
            logger.warning("No more repositories returned before reaching target count")
            break

        new_rows = repos_to_rows(repos)
        for r in new_rows:
            rid = r["id"]
            if rid in seen_ids:
                continue
            seen_ids.add(rid)
            all_rows.append(r)

        last = repos[-1]
        last_id = last.get("id")
        if not isinstance(last_id, int):
            raise ValueError("Last repository missing integer id")
        since_id = last_id

        logger.info("Collected %s valid rows (target %s)", len(all_rows), target_count)

        if len(repos) < per_page:
            logger.warning("Partial page; likely end of available stream for this client")
            break

    return all_rows[:target_count]


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Extract GitHub repos to CSV and upload to S3")
    p.add_argument(
        "--target-rows",
        type=int,
        default=int(os.environ.get("TARGET_ROWS", "1000")),
        help="Minimum rows to collect (default: 1000 or TARGET_ROWS)",
    )
    p.add_argument(
        "--per-page",
        type=int,
        default=min(int(os.environ.get("PER_PAGE", str(DEFAULT_PER_PAGE))), 100),
        help="Page size for /repositories (max 100)",
    )
    p.add_argument(
        "--s3-bucket",
        default=os.environ.get("S3_BUCKET", ""),
        help="S3 bucket name (or S3_BUCKET env)",
    )
    p.add_argument(
        "--s3-prefix",
        default=os.environ.get("S3_PREFIX", "github-data"),
        help="Key prefix inside bucket (default github-data)",
    )
    p.add_argument(
        "--aws-region",
        default=os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION"),
        help="AWS region for S3 client",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="Fetch and validate only; write CSV locally, skip S3",
    )
    p.add_argument(
        "--local-csv",
        default="",
        help="If set with --dry-run, write CSV to this path",
    )
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")

    if args.per_page > 100:
        logger.error("per_page cannot exceed 100")
        return 1

    session = github_session(token)
    if token:
        logger.info("Using GITHUB_TOKEN for higher rate limits")
    else:
        logger.info("No token: using unauthenticated rate limits (60 REST requests/hour per IP)")

    try:
        rows = collect_repositories(session, args.target_rows, args.per_page)
    except Exception as e:
        logger.exception("Collection failed: %s", e)
        return 1

    logger.info("Exporting %s rows (target was %s)", len(rows), args.target_rows)

    if len(rows) < args.target_rows:
        logger.warning(
            "Only collected %s rows (wanted %s). Add GITHUB_TOKEN or retry later.",
            len(rows),
            args.target_rows,
        )

    df = dataframe_from_rows(rows)
    if df.empty:
        logger.error("No valid rows to export")
        return 1

    csv_body = csv_bytes_from_dataframe(df)

    if args.dry_run:
        out = args.local_csv or f"github_repos_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}.csv"
        with open(out, "wb") as f:
            f.write(csv_body)
        logger.info("Dry run: wrote %s (%s bytes)", out, len(csv_body))
        return 0

    if not args.s3_bucket:
        logger.error("S3 bucket required (pass --s3-bucket or set S3_BUCKET), or use --dry-run")
        return 1

    key = s3_object_key(args.s3_prefix)
    try:
        upload_to_s3(args.s3_bucket, key, csv_body, args.aws_region)
    except RuntimeError:
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
