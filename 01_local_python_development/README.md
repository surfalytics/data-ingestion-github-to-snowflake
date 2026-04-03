# data-ingestion-github-to-snowflake — Week 1 (local Python)

This folder is the **Week 1** slice: extract public GitHub repository metadata with Python, validate it, and upload CSV to Amazon S3.

## Quick start

1. Create and activate a virtual environment (see [WEEK1_SETUP_AND_EXECUTION.md](WEEK1_SETUP_AND_EXECUTION.md)).
2. Install dependencies: `pip install -r requirements.txt`
3. Dry run (no AWS):  
   `python src/extract_github_data.py --dry-run --target-rows 1000`
4. Upload to S3: set `S3_BUCKET` (and AWS credentials), then run the same command without `--dry-run`.

Full prerequisites (Snowflake, AWS, GitHub), branching notes, API limits, and CSV schema are documented in **WEEK1_SETUP_AND_EXECUTION.md**.

## Layout

| Path | Purpose |
|------|---------|
| `src/extract_github_data.py` | GitHub REST client, validation, CSV, S3 upload |
| `requirements.txt` | Pinned dependencies from `pip freeze` |
| `WEEK1_SETUP_AND_EXECUTION.md` | Step-by-step execution and findings |

Suggested Git branches after you create the remote repo: `main` (stable), `develop` (integration).
