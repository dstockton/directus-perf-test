#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESULTS_DIR="$PROJECT_DIR/results"
RESULTS_FILE="$RESULTS_DIR/results.md"

# Mode: "local" (default) spins up Docker Compose per version
#        "remote" tests a pre-existing instance
MODE="${MODE:-local}"

# Remote config (only used when MODE=remote)
REMOTE_URL="${REMOTE_URL:-}"
REMOTE_ADMIN_EMAIL="${REMOTE_ADMIN_EMAIL:-}"
REMOTE_ADMIN_PASSWORD="${REMOTE_ADMIN_PASSWORD:-}"
VERSION_LABEL="${VERSION_LABEL:-remote}"

# Versions to test (local mode only)
VERSIONS=(
  "11.15.4"
  "11.16.0"
)

# Test config — all overridable via env
TESTS=("login-page" "rest-api" "graphql" "studio")
P95_THRESHOLD="${P95_THRESHOLD:-300}"
STEP_DURATION="${STEP_DURATION:-5s}"

# Per-test start/step/max — overridable via env
LOGIN_START="${LOGIN_START:-118}"
LOGIN_STEP="${LOGIN_STEP:-1}"
LOGIN_MAX="${LOGIN_MAX:-500}"
OTHER_START="${OTHER_START:-11}"
OTHER_STEP="${OTHER_STEP:-1}"
OTHER_MAX="${OTHER_MAX:-60}"

get_test_start() { case "$1" in login-page) echo "$LOGIN_START" ;; *) echo "$OTHER_START" ;; esac; }
get_test_step()  { case "$1" in login-page) echo "$LOGIN_STEP"  ;; *) echo "$OTHER_STEP" ;; esac; }
get_test_max()   { case "$1" in login-page) echo "$LOGIN_MAX"   ;; *) echo "$OTHER_MAX" ;; esac; }

mkdir -p "$RESULTS_DIR"

# Regenerate results file from existing data
cat > "$RESULTS_FILE" << EOF
# Directus Performance Test Results

Max concurrent VUs where p95 < ${P95_THRESHOLD}ms. Stops after 3 consecutive failures. Higher is better.

Login page: start ${LOGIN_START}, +${LOGIN_STEP}/${STEP_DURATION}, max ${LOGIN_MAX}. Others: start ${OTHER_START}, +${OTHER_STEP}/${STEP_DURATION}, max ${OTHER_MAX}.
Directus: 0.5 CPU / 1GB RAM. Postgres: 2 CPU / 4GB RAM. Warmup: 20 parallel request batches before testing.

| Version | Login Page | REST API | GraphQL | Studio |
|---------|-----------|----------|---------|--------|
EOF

for d in "$RESULTS_DIR"/*/; do
  [ -d "$d" ] || continue
  avg_file="$d/averages.txt"
  [ -f "$avg_file" ] && cat "$avg_file" >> "$RESULTS_FILE"
done

get_network_name() {
  docker compose -f "$PROJECT_DIR/docker-compose.yml" ps --format json 2>/dev/null \
    | head -1 | python3 -c "import sys,json; print(json.load(sys.stdin)['Networks'])" 2>/dev/null \
    || echo "directus-perf-test_default"
}

run_k6_step() {
  local test_name="$1"
  local vus="$2"
  local base_url="$3"
  local network="${4:-}"

  local network_flag=""
  if [ -n "$network" ]; then
    network_flag="--network $network"
  fi

  local admin_flags=""
  if [ -n "$REMOTE_ADMIN_EMAIL" ]; then
    admin_flags="-e ADMIN_EMAIL=$REMOTE_ADMIN_EMAIL -e ADMIN_PASSWORD=$REMOTE_ADMIN_PASSWORD"
  fi

  # shellcheck disable=SC2086
  docker run --rm -q \
    $network_flag \
    -e BASE_URL="$base_url" \
    -e K6_VUS="$vus" \
    -e K6_DURATION="$STEP_DURATION" \
    $admin_flags \
    -v "$PROJECT_DIR/k6:/scripts:ro" \
    grafana/k6 run --quiet "/scripts/${test_name}.js" 2>/dev/null
}

# Single run: find max VUs for a test
# Stops after 3 consecutive failures at the same VU level
find_max_vus() {
  local test_name="$1"
  local base_url="$2"
  local network="$3"
  local csv_file="$4"
  local start_vu step_vu max_vu
  start_vu=$(get_test_start "$test_name")
  step_vu=$(get_test_step "$test_name")
  max_vu=$(get_test_max "$test_name")
  local max_vus=0
  local consecutive_fails=0

  echo "vus,p99,p95,avg,reqs,fails" > "$csv_file"

  local vus="$start_vu"
  while [ "$vus" -le "$max_vu" ]; do
    echo -n "    ${vus} VUs: " >&2

    local output
    output=$(run_k6_step "$test_name" "$vus" "$base_url" "$network") || true

    if [ -z "$output" ]; then
      echo "ERROR: no output" >&2
      break
    fi

    local p99 p95 avg reqs fails
    p99=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['p99'])")
    p95=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['p95'])")
    avg=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['avg'])")
    reqs=$(echo "$output" | python3 -c "import sys,json; print(json.load(sys.stdin)['reqs'])")
    fails=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fails',0))")

    echo "${vus},${p99},${p95},${avg},${reqs},${fails}" >> "$csv_file"
    printf "p99=%.0fms p95=%.0fms avg=%.0fms reqs=%s" "$p99" "$p95" "$avg" "$reqs" >&2

    local exceeded
    exceeded=$(python3 -c "print(1 if $p95 >= $P95_THRESHOLD else 0)")

    if [ "$exceeded" = "1" ]; then
      consecutive_fails=$((consecutive_fails + 1))
      if [ "$consecutive_fails" -ge 3 ]; then
        echo " ← EXCEEDED (3/3, stopping)" >&2
        break
      else
        echo " ← EXCEEDED ($consecutive_fails/3, retrying)" >&2
      fi
    else
      consecutive_fails=0
      max_vus=$vus
      echo " ✓" >&2
      vus=$((vus + step_vu))
    fi
  done

  echo "$max_vus"
}

# k6 warmup: hit each endpoint type briefly to prime JIT/caches
k6_warmup() {
  local base_url="$1"
  local network="${2:-}"
  echo "  Running k6 warmup..." >&2
  for test in login-page rest-api graphql studio; do
    run_k6_step "$test" 10 "$base_url" "$network" > /dev/null || true
  done
  echo "  Warmup complete" >&2
}

# Run all tests for a given version/label, writing to version_dir
run_all_tests() {
  local base_url="$1"
  local network="$2"
  local version_dir="$3"

  k6_warmup "$base_url" "$network"

  local RESULT_LOGIN="" RESULT_REST="" RESULT_GQL="" RESULT_STUDIO=""

  for TEST in "${TESTS[@]}"; do
    echo "  [$TEST]:" >&2
    local MAX_VUS
    MAX_VUS=$(find_max_vus "$TEST" "$base_url" "$network" "$version_dir/${TEST}.csv")
    echo "  [$TEST] Result: $MAX_VUS VUs" >&2
    echo "" >&2

    case "$TEST" in
      login-page) RESULT_LOGIN="$MAX_VUS" ;;
      rest-api)   RESULT_REST="$MAX_VUS" ;;
      graphql)    RESULT_GQL="$MAX_VUS" ;;
      studio)     RESULT_STUDIO="$MAX_VUS" ;;
    esac
  done

  echo "| ${5:-$4} | $RESULT_LOGIN | $RESULT_REST | $RESULT_GQL | $RESULT_STUDIO |"
}

if [ "$MODE" = "remote" ]; then
  # Remote mode: test a single pre-existing instance
  if [ -z "$REMOTE_URL" ]; then
    echo "ERROR: REMOTE_URL required in remote mode"
    exit 1
  fi

  VERSION_DIR="$RESULTS_DIR/$VERSION_LABEL"

  if [ -f "$VERSION_DIR/averages.txt" ]; then
    echo "Skipping $VERSION_LABEL (already tested)"
    exit 0
  fi

  mkdir -p "$VERSION_DIR"

  echo "========================================"
  echo "Testing remote: $REMOTE_URL ($VERSION_LABEL)"
  echo "========================================"

  ROW=$(run_all_tests "$REMOTE_URL" "" "$VERSION_DIR" "$VERSION_LABEL")
  echo "$ROW" > "$VERSION_DIR/averages.txt"
  echo "$ROW" >> "$RESULTS_FILE"

  echo ""
  echo "Remote tests complete. Results:"
  echo "$ROW"

else
  # Local mode: spin up Docker Compose per version
  for VERSION in "${VERSIONS[@]}"; do
    VERSION_DIR="$RESULTS_DIR/$VERSION"

    if [ -f "$VERSION_DIR/averages.txt" ]; then
      echo "Skipping v$VERSION (already tested)"
      continue
    fi

    echo "========================================"
    echo "Testing Directus v$VERSION"
    echo "========================================"

    mkdir -p "$VERSION_DIR"

    echo "Starting Directus v$VERSION..."
    cd "$PROJECT_DIR"
    DIRECTUS_VERSION="$VERSION" docker compose up -d --wait --quiet-pull 2>&1 || {
      echo "ERROR: Failed to start Directus v$VERSION"
      docker compose down -v 2>/dev/null
      rm -rf "$VERSION_DIR"
      continue
    }

    echo "Waiting for Directus to be healthy..."
    for i in $(seq 1 60); do
      if curl -sf http://localhost:8056/server/health > /dev/null 2>&1; then
        echo "Directus is healthy"
        break
      fi
      if [ "$i" -eq 60 ]; then
        echo "ERROR: Directus did not become healthy"
        docker compose down -v
        rm -rf "$VERSION_DIR"
        continue 2
      fi
      sleep 2
    done

    echo "Seeding data..."
    if ! bash "$PROJECT_DIR/seed/seed.sh"; then
      echo "ERROR: Seeding failed for v$VERSION"
      docker compose down -v
      rm -rf "$VERSION_DIR"
      continue
    fi

    NETWORK=$(get_network_name)

    ROW=$(run_all_tests "http://directus:8055" "$NETWORK" "$VERSION_DIR" "$VERSION")
    echo "$ROW" > "$VERSION_DIR/averages.txt"
    echo "$ROW" >> "$RESULTS_FILE"

    echo "Results for v$VERSION: $ROW"

    echo "Tearing down..."
    docker compose down -v

    echo "v$VERSION complete"
    echo ""
  done

  echo ""
  echo "All tests complete. Results:"
  echo ""
  cat "$RESULTS_FILE"
fi
