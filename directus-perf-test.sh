#!/usr/bin/env bash
set -euo pipefail

# ── 1. CONFIGURATION ────────────────────────────────────────────────
DIRECTUS_URL="${DIRECTUS_URL:-http://127.0.0.1:8055}"
DIRECTUS_USER="${DIRECTUS_USER:-admin@example.com}"
DIRECTUS_PASS="${DIRECTUS_PASS:-admin}"
MAX_VU="${DIRECTUS_MAX_VU:-0}"
START_VU="${DIRECTUS_START_VU:-1}"
MAX_P95="${DIRECTUS_MAX_P95:-750}"
MAX_ERR="${DIRECTUS_MAX_ERR:-0.0}"

[ "$START_VU" -lt 1 ] && START_VU=1

WORK_DIR=""
TOKEN=""
TOKEN_TIME=0
HAS_JQ=""

# ── 2. UTILITIES ─────────────────────────────────────────────────────
log() { echo "[perf] $*" >&2; }
die() { log "ERROR: $*"; exit 1; }

json_extract() {
  local json="$1" path="$2"
  if [ -n "$HAS_JQ" ]; then
    printf '%s' "$json" | jq -r ".$path"
  else
    printf '%s' "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for k in '$path'.split('.'):
    d = d[k]
print(d)
"
  fi
}

check_pass() {
  local p95="$1" err_rate="$2"
  awk "BEGIN { exit !(($p95 < $MAX_P95) && ($err_rate <= $MAX_ERR)) }"
}

# ── 3. PREREQUISITES ────────────────────────────────────────────────
check_prereqs() {
  command -v docker &>/dev/null || die "docker not found"
  command -v curl &>/dev/null || die "curl not found"
  if command -v jq &>/dev/null; then
    HAS_JQ=1
  elif command -v python3 &>/dev/null; then
    HAS_JQ=""
  else
    die "jq or python3 required for JSON parsing"
  fi
  log "Ensuring grafana/k6 image is available..."
  if ! docker image inspect grafana/k6 &>/dev/null; then
    docker pull grafana/k6 > /dev/null 2>&1 || die "Failed to pull grafana/k6 image"
  fi
}

# ── 4. TEMP DIR + K6 HEREDOC ────────────────────────────────────────
setup_k6() {
  WORK_DIR=$(mktemp -d)
  cat > "$WORK_DIR/test.js" << 'K6_SCRIPT_EOF'
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const AUTH_TOKEN = __ENV.AUTH_TOKEN;
const AUTH_HDR = { Authorization: 'Bearer ' + AUTH_TOKEN };
const JSON_AUTH_HDR = { Authorization: 'Bearer ' + AUTH_TOKEN, 'Content-Type': 'application/json' };

export const options = {
  vus: parseInt(__ENV.K6_VUS || '1'),
  duration: __ENV.K6_DURATION || '1s',
  summaryTrendStats: ['avg', 'p(95)', 'p(99)'],
};

// Per-VU state for write tracking
let createdIds = [];

export default function () {
  const roll = Math.random() * 100;

  if (roll < 35) {
    // 35% — List articles with relations (paginated, sorted)
    const r = http.get(
      BASE_URL + '/items/perf_test_articles?fields=*,category.*,author.*&limit=25&sort=-publish_date'
    );
    check(r, { 'list 2xx': (r) => r.status >= 200 && r.status < 300 });

  } else if (roll < 55) {
    // 20% — Single article detail with nested fields
    const id = Math.floor(Math.random() * 100) + 1;
    const r = http.get(
      BASE_URL + '/items/perf_test_articles/' + id + '?fields=*,category.*,author.*'
    );
    check(r, { 'detail 2xx': (r) => r.status >= 200 && r.status < 300 });

  } else if (roll < 72) {
    // 17% — Filtered article list
    const filters = [
      'filter[status][_eq]=published',
      'filter[category][_eq]=' + (Math.floor(Math.random() * 10) + 1),
      'filter[publish_date][_gte]=2025-01-15',
    ];
    const f = filters[Math.floor(Math.random() * filters.length)];
    const r = http.get(
      BASE_URL + '/items/perf_test_articles?' + f + '&fields=id,title,status&limit=25'
    );
    check(r, { 'filter 2xx': (r) => r.status >= 200 && r.status < 300 });

  } else if (roll < 75) {
    // 3% — Create article
    const payload = JSON.stringify({
      title: 'PerfTest ' + Date.now(),
      body: '<p>Generated during perf test</p>',
      status: 'draft',
      publish_date: '2025-06-01T12:00:00',
      category: Math.floor(Math.random() * 10) + 1,
      author: Math.floor(Math.random() * 20) + 1,
    });
    const r = http.post(BASE_URL + '/items/perf_test_articles', payload, { headers: JSON_AUTH_HDR });
    if (r.status === 200 || r.status === 201) {
      try {
        const id = JSON.parse(r.body).data.id;
        if (id) createdIds.push(id);
      } catch (e) {}
    }
    check(r, { 'create 2xx': (r) => r.status >= 200 && r.status < 300 });

  } else if (roll < 78) {
    // 3% — Update article
    const id = Math.floor(Math.random() * 100) + 1;
    const r = http.patch(
      BASE_URL + '/items/perf_test_articles/' + id,
      JSON.stringify({ title: 'Updated ' + Date.now() }),
      { headers: JSON_AUTH_HDR }
    );
    check(r, { 'update 2xx': (r) => r.status >= 200 && r.status < 300 });

  } else if (roll < 80) {
    // 2% — Delete article (test-created only, fallback to read)
    if (createdIds.length > 0) {
      const id = createdIds.pop();
      const r = http.del(
        BASE_URL + '/items/perf_test_articles/' + id, null, { headers: AUTH_HDR }
      );
      check(r, { 'delete 2xx': (r) => r.status >= 200 && r.status < 300 });
    } else {
      const r = http.get(BASE_URL + '/items/perf_test_articles?fields=id,title&limit=25');
      check(r, { 'fallback-list 2xx': (r) => r.status >= 200 && r.status < 300 });
    }

  } else if (roll < 90) {
    // 10% — GraphQL query with nested relations
    const r = http.post(BASE_URL + '/graphql', JSON.stringify({
      query: '{ perf_test_articles(limit: 25, sort: ["-publish_date"]) { id title body status publish_date category { id name } author { id name } } }'
    }), { headers: { 'Content-Type': 'application/json' } });
    check(r, { 'graphql 2xx': (r) => r.status >= 200 && r.status < 300 });

  } else if (roll < 95) {
    // 5% — Studio (authenticated system endpoints)
    http.get(BASE_URL + '/collections', { headers: AUTH_HDR });
    http.get(BASE_URL + '/fields', { headers: AUTH_HDR });
    http.get(BASE_URL + '/settings', { headers: AUTH_HDR });

  } else {
    // 5% — Login page (static)
    const r = http.get(BASE_URL + '/admin/login');
    check(r, { 'login 2xx': (r) => r.status >= 200 && r.status < 300 });
  }
}

export function handleSummary(data) {
  const reqs = data.metrics.http_reqs.values.count;
  const fails = data.metrics.http_req_failed.values.passes;
  return {
    stdout: JSON.stringify({
      p95: data.metrics.http_req_duration.values['p(95)'],
      p99: data.metrics.http_req_duration.values['p(99)'],
      avg: data.metrics.http_req_duration.values.avg,
      reqs: reqs,
      error_rate: reqs > 0 ? (fails / reqs) * 100 : 0,
    }),
  };
}
K6_SCRIPT_EOF
}

# ── 5. AUTH ──────────────────────────────────────────────────────────
get_token() {
  local resp
  resp=$(curl -sf "$DIRECTUS_URL/auth/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$DIRECTUS_USER\",\"password\":\"$DIRECTUS_PASS\"}") \
    || die "Authentication failed (check DIRECTUS_USER/DIRECTUS_PASS)"
  TOKEN=$(json_extract "$resp" "data.access_token")
  [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ] || die "Authentication failed (invalid response)"
  TOKEN_TIME=$(date +%s)
}

ensure_token() {
  local now
  now=$(date +%s)
  if [ -z "$TOKEN" ] || [ $((now - TOKEN_TIME)) -gt 600 ]; then
    get_token
  fi
}

# ── 6. SEED ──────────────────────────────────────────────────────────
seed_data() {
  ensure_token
  local auth="Authorization: Bearer $TOKEN"
  local ct="Content-Type: application/json"

  # Remove existing test collections (idempotent)
  log "Removing existing test collections (if any)..."
  curl -sf -X DELETE "$DIRECTUS_URL/collections/perf_test_articles" -H "$auth" > /dev/null 2>&1 || true
  curl -sf -X DELETE "$DIRECTUS_URL/collections/perf_test_authors" -H "$auth" > /dev/null 2>&1 || true
  curl -sf -X DELETE "$DIRECTUS_URL/collections/perf_test_categories" -H "$auth" > /dev/null 2>&1 || true

  log "Creating perf_test_categories..."
  curl -sf "$DIRECTUS_URL/collections" -H "$auth" -H "$ct" -d '{
    "collection": "perf_test_categories",
    "meta": { "icon": "category" },
    "schema": {},
    "fields": [
      { "field": "id", "type": "integer", "meta": { "hidden": true, "interface": "input", "readonly": true }, "schema": { "is_primary_key": true, "has_auto_increment": true } },
      { "field": "name", "type": "string", "meta": { "interface": "input" }, "schema": { "is_nullable": false } },
      { "field": "description", "type": "text", "meta": { "interface": "input-multiline" }, "schema": {} }
    ]
  }' > /dev/null || die "Failed to create perf_test_categories"

  log "Creating perf_test_authors..."
  curl -sf "$DIRECTUS_URL/collections" -H "$auth" -H "$ct" -d '{
    "collection": "perf_test_authors",
    "meta": { "icon": "person" },
    "schema": {},
    "fields": [
      { "field": "id", "type": "integer", "meta": { "hidden": true, "interface": "input", "readonly": true }, "schema": { "is_primary_key": true, "has_auto_increment": true } },
      { "field": "name", "type": "string", "meta": { "interface": "input" }, "schema": { "is_nullable": false } },
      { "field": "bio", "type": "text", "meta": { "interface": "input-multiline" }, "schema": {} }
    ]
  }' > /dev/null || die "Failed to create perf_test_authors"

  log "Creating perf_test_articles..."
  curl -sf "$DIRECTUS_URL/collections" -H "$auth" -H "$ct" -d '{
    "collection": "perf_test_articles",
    "meta": { "icon": "article" },
    "schema": {},
    "fields": [
      { "field": "id", "type": "integer", "meta": { "hidden": true, "interface": "input", "readonly": true }, "schema": { "is_primary_key": true, "has_auto_increment": true } },
      { "field": "title", "type": "string", "meta": { "interface": "input" }, "schema": { "is_nullable": false } },
      { "field": "body", "type": "text", "meta": { "interface": "input-rich-text-html" }, "schema": {} },
      { "field": "status", "type": "string", "meta": { "interface": "select-dropdown", "options": { "choices": [{"text":"Draft","value":"draft"},{"text":"Published","value":"published"}] } }, "schema": { "default_value": "draft" } },
      { "field": "publish_date", "type": "timestamp", "meta": { "interface": "datetime" }, "schema": {} },
      { "field": "category", "type": "integer", "meta": { "interface": "select-dropdown-m2o" }, "schema": {} },
      { "field": "author", "type": "integer", "meta": { "interface": "select-dropdown-m2o" }, "schema": {} }
    ]
  }' > /dev/null || die "Failed to create perf_test_articles"

  log "Creating relations..."
  curl -sf "$DIRECTUS_URL/relations" -H "$auth" -H "$ct" \
    -d '{ "collection": "perf_test_articles", "field": "category", "related_collection": "perf_test_categories" }' > /dev/null \
    || die "Failed to create category relation"
  curl -sf "$DIRECTUS_URL/relations" -H "$auth" -H "$ct" \
    -d '{ "collection": "perf_test_articles", "field": "author", "related_collection": "perf_test_authors" }' > /dev/null \
    || die "Failed to create author relation"

  # Public read access
  log "Setting public access..."
  local public_policy
  if [ -n "$HAS_JQ" ]; then
    public_policy=$(curl -sf "$DIRECTUS_URL/policies" -H "$auth" \
      | jq -r '.data[] | select(.name == "$t:public_label") | .id')
  else
    public_policy=$(curl -sf "$DIRECTUS_URL/policies" -H "$auth" \
      | python3 -c '
import sys, json
data = json.load(sys.stdin)["data"]
for p in data:
    if p["name"] == "$t:public_label":
        print(p["id"])
        break
')
  fi

  if [ -n "$public_policy" ] && [ "$public_policy" != "null" ]; then
    for col in perf_test_categories perf_test_authors perf_test_articles; do
      curl -sf "$DIRECTUS_URL/permissions" -H "$auth" -H "$ct" \
        -d "{\"policy\":\"$public_policy\",\"collection\":\"$col\",\"action\":\"read\",\"fields\":[\"*\"]}" > /dev/null
    done
  else
    log "Warning: could not find public policy, skipping public access"
  fi

  # Seed categories
  log "Seeding 10 categories..."
  local cats='['
  for i in $(seq 1 10); do
    [ "$i" -gt 1 ] && cats+=','
    cats+="{\"name\":\"Category $i\",\"description\":\"Description for category $i\"}"
  done
  cats+=']'
  curl -sf "$DIRECTUS_URL/items/perf_test_categories" -H "$auth" -H "$ct" -d "$cats" > /dev/null \
    || die "Failed to seed categories"

  # Seed authors
  log "Seeding 20 authors..."
  local authors='['
  for i in $(seq 1 20); do
    [ "$i" -gt 1 ] && authors+=','
    authors+="{\"name\":\"Author $i\",\"bio\":\"Biography for author $i. An experienced writer.\"}"
  done
  authors+=']'
  curl -sf "$DIRECTUS_URL/items/perf_test_authors" -H "$auth" -H "$ct" -d "$authors" > /dev/null \
    || die "Failed to seed authors"

  # Seed articles
  log "Seeding 100 articles..."
  local articles='['
  for i in $(seq 1 100); do
    [ "$i" -gt 1 ] && articles+=','
    local cat_id=$(( (i % 10) + 1 ))
    local author_id=$(( (i % 20) + 1 ))
    local status="published"
    [ $((i % 5)) -eq 0 ] && status="draft"
    articles+="{\"title\":\"Article $i\",\"body\":\"<p>Body content for article $i. Lorem ipsum.</p>\",\"status\":\"$status\",\"publish_date\":\"2025-01-$(printf '%02d' $((i % 28 + 1)))T12:00:00\",\"category\":$cat_id,\"author\":$author_id}"
  done
  articles+=']'
  curl -sf "$DIRECTUS_URL/items/perf_test_articles" -H "$auth" -H "$ct" -d "$articles" > /dev/null \
    || die "Failed to seed articles"

  log "Seed complete: 10 categories, 20 authors, 100 articles"
}

# ── 7. WARMUP ────────────────────────────────────────────────────────
warmup() {
  log "Warming up..."
  ensure_token
  local auth="Authorization: Bearer $TOKEN"

  for _ in $(seq 1 10); do
    curl -sf "$DIRECTUS_URL/admin/login" > /dev/null 2>&1 &
    curl -sf "$DIRECTUS_URL/items/perf_test_articles?fields=*,category.*,author.*&limit=25" > /dev/null 2>&1 &
    curl -sf "$DIRECTUS_URL/graphql" -H "Content-Type: application/json" \
      -d '{"query":"{ perf_test_articles(limit:25) { id title category { name } author { name } } }"}' > /dev/null 2>&1 &
    curl -sf "$DIRECTUS_URL/settings" -H "$auth" > /dev/null 2>&1 &
    curl -sf "$DIRECTUS_URL/collections" -H "$auth" > /dev/null 2>&1 &
    curl -sf "$DIRECTUS_URL/fields" -H "$auth" > /dev/null 2>&1 &
  done
  wait

  # k6 warmup run
  ensure_token
  run_k6 1 "5s" > /dev/null 2>&1 || true
  log "Warmup complete"
}

# ── 8. K6 RUNNER ─────────────────────────────────────────────────────
run_k6() {
  local vus="$1" duration="$2"
  local output
  output=$(docker run --rm --network host \
    -e BASE_URL="$DIRECTUS_URL" \
    -e AUTH_TOKEN="$TOKEN" \
    -e K6_VUS="$vus" \
    -e K6_DURATION="$duration" \
    -v "$WORK_DIR/test.js:/test.js:ro" \
    grafana/k6 run --quiet /test.js 2>/dev/null) || true

  if [ -z "$output" ]; then
    echo '{"p95":99999,"p99":99999,"avg":99999,"reqs":0,"error_rate":100}'
  else
    echo "$output"
  fi
}

# ── 9. PHASE 1 — Multi-Resolution Narrowing ─────────────────────────
phase1() {
  local last_pass=0
  local first_fail=0
  local vus=$START_VU

  # Round 1: Exponential doubling
  log "Phase 1 Round 1: Exponential scan"
  while true; do
    if [ "$MAX_VU" -gt 0 ] && [ "$vus" -gt "$MAX_VU" ]; then
      vus=$MAX_VU
    fi

    ensure_token
    local result p95 error_rate
    result=$(run_k6 "$vus" "1s")
    p95=$(json_extract "$result" "p95")
    error_rate=$(json_extract "$result" "error_rate")
    { [ -z "$p95" ] || [ "$p95" = "null" ]; } && p95=99999
    { [ -z "$error_rate" ] || [ "$error_rate" = "null" ]; } && error_rate=100

    if check_pass "$p95" "$error_rate"; then
      last_pass=$vus
      log "  ${vus} VUs: p95=$(printf '%.1f' "$p95")ms err=$(printf '%.1f' "$error_rate")% ✓"
      if [ "$MAX_VU" -gt 0 ] && [ "$vus" -ge "$MAX_VU" ]; then
        log "Reached MAX_VU cap ($MAX_VU) without failure"
        echo "$last_pass 0"
        return
      fi
      vus=$((vus * 2))
    else
      first_fail=$vus
      log "  ${vus} VUs: p95=$(printf '%.1f' "$p95")ms err=$(printf '%.1f' "$error_rate")% ✗"
      break
    fi
  done

  # Round 2+: Subdivide until range ≤ 20
  while true; do
    local range=$((first_fail - last_pass))
    if [ "$range" -le 20 ]; then
      break
    fi

    local step=$(( (range + 7) / 8 ))
    log "Phase 1 Subdivide: range=[$last_pass, $first_fail] step=$step"

    vus=$((last_pass + step))
    local new_last_pass=$last_pass
    while [ "$vus" -lt "$first_fail" ]; do
      if [ "$MAX_VU" -gt 0 ] && [ "$vus" -gt "$MAX_VU" ]; then
        vus=$MAX_VU
      fi

      ensure_token
      local result p95 error_rate
      result=$(run_k6 "$vus" "1s")
      p95=$(json_extract "$result" "p95")
      error_rate=$(json_extract "$result" "error_rate")
      { [ -z "$p95" ] || [ "$p95" = "null" ]; } && p95=99999
      { [ -z "$error_rate" ] || [ "$error_rate" = "null" ]; } && error_rate=100

      if check_pass "$p95" "$error_rate"; then
        new_last_pass=$vus
        log "  ${vus} VUs: p95=$(printf '%.1f' "$p95")ms err=$(printf '%.1f' "$error_rate")% ✓"
        vus=$((vus + step))
      else
        first_fail=$vus
        log "  ${vus} VUs: p95=$(printf '%.1f' "$p95")ms err=$(printf '%.1f' "$error_rate")% ✗"
        break
      fi
    done
    last_pass=$new_last_pass
  done

  log "Phase 1 result: range=[$last_pass, $first_fail]"
  echo "$last_pass $first_fail"
}

# ── 10. PHASE 2 — Sustained Confirmation ────────────────────────────
phase2() {
  local vus="$1"
  local confirmed=0
  local consecutive_fails=0

  log "Phase 2: Sustained confirmation from $vus VUs (30s/step)"

  while true; do
    if [ "$vus" -le 0 ]; then
      confirmed=0
      break
    fi
    if [ "$MAX_VU" -gt 0 ] && [ "$vus" -gt "$MAX_VU" ]; then
      break
    fi

    ensure_token
    local result p95 error_rate
    result=$(run_k6 "$vus" "30s")
    p95=$(json_extract "$result" "p95")
    error_rate=$(json_extract "$result" "error_rate")
    { [ -z "$p95" ] || [ "$p95" = "null" ]; } && p95=99999
    { [ -z "$error_rate" ] || [ "$error_rate" = "null" ]; } && error_rate=100

    if check_pass "$p95" "$error_rate"; then
      log "  ${vus} VUs 30s: p95=$(printf '%.1f' "$p95")ms err=$(printf '%.1f' "$error_rate")% ✓"
      confirmed=$vus
      consecutive_fails=0
      vus=$((vus + 1))
    else
      consecutive_fails=$((consecutive_fails + 1))
      log "  ${vus} VUs 30s: p95=$(printf '%.1f' "$p95")ms err=$(printf '%.1f' "$error_rate")% ✗ ($consecutive_fails/3)"

      if [ "$consecutive_fails" -ge 3 ]; then
        if [ "$confirmed" -gt 0 ]; then
          break
        fi
        vus=$((vus - 1))
        consecutive_fails=0
        log "  Decrementing to $vus VUs"
      fi
    fi
  done

  echo "$confirmed"
}

# ── 11. CLEANUP ──────────────────────────────────────────────────────
cleanup() {
  trap - EXIT INT TERM
  log "Cleaning up..."
  if [ -n "${TOKEN:-}" ]; then
    curl -sf -X DELETE "$DIRECTUS_URL/collections/perf_test_articles" \
      -H "Authorization: Bearer $TOKEN" > /dev/null 2>&1 || true
    curl -sf -X DELETE "$DIRECTUS_URL/collections/perf_test_authors" \
      -H "Authorization: Bearer $TOKEN" > /dev/null 2>&1 || true
    curl -sf -X DELETE "$DIRECTUS_URL/collections/perf_test_categories" \
      -H "Authorization: Bearer $TOKEN" > /dev/null 2>&1 || true
  fi
  [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  log "Done"
}

trap cleanup EXIT INT TERM

# ── 12. OUTPUT ───────────────────────────────────────────────────────
# All progress/logging → stderr (via log())
# Final max VU number → stdout (single line, CI-parseable)

# ── 13. MAIN ─────────────────────────────────────────────────────────
main() {
  log "Directus Performance Test"
  log "Target: $DIRECTUS_URL"
  log "Thresholds: p95 < ${MAX_P95}ms, errors <= ${MAX_ERR}%"
  log "Start VU: $START_VU, Max VU: $([ "$MAX_VU" -gt 0 ] && echo "$MAX_VU" || echo "unlimited")"

  check_prereqs
  setup_k6

  # Wait for Directus
  log "Waiting for Directus..."
  for i in $(seq 1 60); do
    if curl -sf "$DIRECTUS_URL/server/health" > /dev/null 2>&1; then
      log "Directus is ready"
      break
    fi
    if [ "$i" -eq 60 ]; then
      die "Directus not ready after 120s"
    fi
    sleep 2
  done

  seed_data
  warmup

  # Phase 1: find approximate breaking point
  log "═══ Phase 1: Finding approximate breaking point ═══"
  local phase1_result last_pass first_fail
  phase1_result=$(phase1)
  last_pass=$(echo "$phase1_result" | awk '{print $1}')
  first_fail=$(echo "$phase1_result" | awk '{print $2}')

  if [ "$first_fail" -eq 0 ]; then
    # Hit MAX_VU cap without failure — skip Phase 2
    log "═══ Result: $last_pass VUs (MAX_VU cap reached) ═══"
    echo "$last_pass"
    return
  fi

  # Phase 2: sustained confirmation
  log "═══ Phase 2: Sustained confirmation ═══"
  local start=$last_pass
  [ "$start" -lt 1 ] && start=1
  local confirmed
  confirmed=$(phase2 "$start")

  log "═══ Result: $confirmed VUs ═══"
  echo "$confirmed"
}

main "$@"
