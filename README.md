# directus-perf-test

Single self-contained bash script that finds the maximum concurrent VUs a Directus instance can sustain. Only dependency: Docker + curl.

## Usage

```bash
# One-liner — no clone needed
curl -sL https://raw.githubusercontent.com/dstockton/directus-perf-test/main/directus-perf-test.sh | bash

# With env var overrides
curl -sL https://raw.githubusercontent.com/dstockton/directus-perf-test/main/directus-perf-test.sh \
  | DIRECTUS_URL=http://my-server:8055 DIRECTUS_PASS=secret bash

# Local (after cloning)
bash directus-perf-test.sh

# CI-friendly: final VU number goes to stdout, logs to stderr
MAX_VU=$(bash directus-perf-test.sh 2>/dev/null)
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DIRECTUS_URL` | `http://127.0.0.1:8055` | Target Directus instance |
| `DIRECTUS_USER` | `admin@example.com` | Admin email |
| `DIRECTUS_PASS` | `admin` | Admin password |
| `DIRECTUS_MAX_VU` | `0` (no limit) | Stop searching at this VU count |
| `DIRECTUS_START_VU` | `1` | Begin search from this VU count |
| `DIRECTUS_MAX_P95` | `750` | Max acceptable p95 in ms |
| `DIRECTUS_MAX_ERR` | `0.0` | Max acceptable error rate (%) |

## How It Works

### Phase 1: Multi-Resolution Narrowing (~1s/step)

Finds the approximate breaking point fast:

1. **Exponential doubling** — 1, 2, 4, 8, 16... until first failure. Gives a range like [32, 64].
2. **Subdivide** — splits range into ~8 steps, scans linearly. Repeats until range ≤ 20 VUs.

### Phase 2: Sustained Confirmation (30s/step)

Starting from Phase 1's last passing VU, runs each level for 30 seconds:

- On failure: retry same VU (don't increment)
- 3 consecutive failures → decrement by 1
- Result: highest VU that sustained 30s of load

### Test Workload

**80% REST API** (72% reads + 8% writes): list/detail/filtered articles, create/update/delete.
**10% GraphQL** — articles with nested relations.
**5% Studio** — GET /collections + /fields + /settings (authenticated).
**5% Login page** — GET /admin/login (static).

### Data Model

Creates `perf_test_` prefixed collections (10 categories, 20 authors, 100 articles with M2O relations). Public read access. Cleaned up automatically on exit.

## Verification

```bash
# Start a constrained Directus instance
docker network create perf-test-verify || true
docker run -d --name perf-pg --network perf-test-verify \
  -e POSTGRES_DB=directus -e POSTGRES_USER=directus -e POSTGRES_PASSWORD=directus \
  --cpus=2 --memory=4g postgres:16-alpine
docker run -d --name perf-directus --network perf-test-verify \
  -p 8077:8055 --cpus=0.25 --memory=400m \
  -e DB_CLIENT=pg -e DB_HOST=perf-pg -e DB_PORT=5432 \
  -e DB_DATABASE=directus -e DB_USER=directus -e DB_PASSWORD=directus \
  -e SECRET=test-secret -e ADMIN_EMAIL=admin@example.com -e ADMIN_PASSWORD=admin \
  -e CACHE_ENABLED=false -e TELEMETRY=false \
  directus/directus:11.16.0

# Run the test (wait ~30s for Directus to start)
DIRECTUS_URL=http://127.0.0.1:8077 DIRECTUS_PASS=admin bash directus-perf-test.sh

# Tear down
docker rm -f perf-directus perf-pg && docker network rm perf-test-verify
```
