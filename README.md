# directus-perf-test

Automated performance testing of Directus Docker images (v11.15.0+).

## What it tests

Finds max concurrent users (VUs) where p95 response time stays under 300ms.
Steps up in 1 VU increments (5s per step). Stops after 3 consecutive failures.
Includes warmup phase (seed data + k6 warmup run) before testing.

Four test types:
- **Login Page** — GET /admin/login (static asset)
- **REST API** — GET /items/articles with relations (25 rows, nested category + author)
- **GraphQL** — articles query with nested relations
- **Studio** — authenticated requests simulating studio page load (settings, collections, fields, articles)

## Requirements

- Docker + Docker Compose
- ~6GB free RAM (1GB Directus + 4GB Postgres + k6)
- Port 8056 available (configurable via HOST_PORT env)

## Usage

```bash
# Local (Docker Compose per version)
bash scripts/run-tests.sh

# Remote (pre-existing instance, custom thresholds)
MODE=remote \
REMOTE_URL="https://example.com" \
REMOTE_ADMIN_EMAIL="admin@example.com" \
REMOTE_ADMIN_PASSWORD="password" \
P95_THRESHOLD=750 \
LOGIN_START=15 LOGIN_STEP=1 \
OTHER_START=2 OTHER_STEP=1 \
bash scripts/run-tests.sh
```

All test parameters (start VU, step, max, threshold) are configurable via env vars.

Results are written to `results/results.md`. Versions with existing results are skipped.
Per-version CSV detail files (p99/p95/avg/reqs per VU level) saved to `results/<version>/`.

## Resource Limits

| Service  | CPU | Memory |
|----------|-----|--------|
| Directus | 0.5 | 1 GB  |
| Postgres | 2   | 4 GB   |
