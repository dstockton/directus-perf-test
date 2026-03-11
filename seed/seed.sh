#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8056}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-AdminPassword123}"

echo "Waiting for Directus..."
for i in $(seq 1 60); do
  if curl -sf "$BASE_URL/server/health" > /dev/null 2>&1; then
    echo "Directus is ready"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Directus did not become ready"
    exit 1
  fi
  sleep 2
done

# Authenticate
echo "Authenticating..."
TOKEN=$(curl -sf "$BASE_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASSWORD\"}" \
  | jq -r '.data.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Failed to authenticate"
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"

# Create categories collection
echo "Creating categories collection..."
curl -sf "$BASE_URL/collections" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{
    "collection": "categories",
    "meta": { "icon": "category" },
    "schema": {},
    "fields": [
      { "field": "id", "type": "integer", "meta": { "hidden": true, "interface": "input", "readonly": true }, "schema": { "is_primary_key": true, "has_auto_increment": true } },
      { "field": "name", "type": "string", "meta": { "interface": "input" }, "schema": { "is_nullable": false } },
      { "field": "description", "type": "text", "meta": { "interface": "input-multiline" }, "schema": {} }
    ]
  }' > /dev/null

# Create authors collection
echo "Creating authors collection..."
curl -sf "$BASE_URL/collections" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{
    "collection": "authors",
    "meta": { "icon": "person" },
    "schema": {},
    "fields": [
      { "field": "id", "type": "integer", "meta": { "hidden": true, "interface": "input", "readonly": true }, "schema": { "is_primary_key": true, "has_auto_increment": true } },
      { "field": "name", "type": "string", "meta": { "interface": "input" }, "schema": { "is_nullable": false } },
      { "field": "bio", "type": "text", "meta": { "interface": "input-multiline" }, "schema": {} }
    ]
  }' > /dev/null

# Create articles collection
echo "Creating articles collection..."
curl -sf "$BASE_URL/collections" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{
    "collection": "articles",
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
  }' > /dev/null

# Create relations
echo "Creating relations..."
curl -sf "$BASE_URL/relations" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{ "collection": "articles", "field": "category", "related_collection": "categories" }' > /dev/null

curl -sf "$BASE_URL/relations" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{ "collection": "articles", "field": "author", "related_collection": "authors" }' > /dev/null

# Set public read access on all custom collections
echo "Setting public access..."
# v11+ uses policies; find the public policy ID
PUBLIC_POLICY=$(curl -sf "$BASE_URL/policies" \
  -H "$AUTH" | jq -r '.data[] | select(.name == "$t:public_label") | .id')

if [ -z "$PUBLIC_POLICY" ] || [ "$PUBLIC_POLICY" = "null" ]; then
  echo "WARNING: Could not find public policy, skipping public access"
else
  for col in categories authors articles; do
    curl -sf "$BASE_URL/permissions" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"policy\":\"$PUBLIC_POLICY\",\"collection\":\"$col\",\"action\":\"read\",\"fields\":[\"*\"]}" > /dev/null
  done
fi

# Seed categories
echo "Seeding categories..."
CATEGORIES='['
for i in $(seq 1 10); do
  [ $i -gt 1 ] && CATEGORIES+=','
  CATEGORIES+="{\"name\":\"Category $i\",\"description\":\"Description for category $i\"}"
done
CATEGORIES+=']'
curl -sf "$BASE_URL/items/categories" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "$CATEGORIES" > /dev/null

# Seed authors
echo "Seeding authors..."
AUTHORS='['
for i in $(seq 1 20); do
  [ $i -gt 1 ] && AUTHORS+=','
  AUTHORS+="{\"name\":\"Author $i\",\"bio\":\"Biography for author $i. An experienced writer.\"}"
done
AUTHORS+=']'
curl -sf "$BASE_URL/items/authors" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "$AUTHORS" > /dev/null

# Seed articles
echo "Seeding articles..."
ARTICLES='['
for i in $(seq 1 100); do
  [ $i -gt 1 ] && ARTICLES+=','
  CAT=$(( (i % 10) + 1 ))
  AUTH_ID=$(( (i % 20) + 1 ))
  STATUS="published"
  [ $((i % 5)) -eq 0 ] && STATUS="draft"
  ARTICLES+="{\"title\":\"Article $i\",\"body\":\"<p>Body content for article $i. Lorem ipsum dolor sit amet.</p>\",\"status\":\"$STATUS\",\"publish_date\":\"2025-01-$(printf '%02d' $((i % 28 + 1)))T12:00:00\",\"category\":$CAT,\"author\":$AUTH_ID}"
done
ARTICLES+=']'
curl -sf "$BASE_URL/items/articles" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "$ARTICLES" > /dev/null

# Warmup — hit all endpoints to prime JIT, caches, connection pools
echo "Warming up..."
for _ in $(seq 1 20); do
  curl -sf "$BASE_URL/admin/login" > /dev/null &
  curl -sf "$BASE_URL/items/articles?fields=*,category.*,author.*&limit=25&sort=-publish_date" > /dev/null &
  curl -sf "$BASE_URL/graphql" -H "Content-Type: application/json" \
    -d '{"query":"{ articles(limit:25) { id title category { name } author { name } } }"}' > /dev/null &
  curl -sf "$BASE_URL/settings" -H "$AUTH" > /dev/null &
  curl -sf "$BASE_URL/collections" -H "$AUTH" > /dev/null &
  curl -sf "$BASE_URL/fields" -H "$AUTH" > /dev/null &
done
wait
echo "Warmup complete"

echo "Seeding complete: 10 categories, 20 authors, 100 articles"
