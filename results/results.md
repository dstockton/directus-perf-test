# Directus Performance Test Results

## Local (p95 < 300ms)

Max concurrent VUs where p95 < 300ms. Stops after 3 consecutive failures. Higher is better.

Login page: start 118, +1/5s, max 500. Others: start 11, +1/5s, max 60.
Directus: 0.5 CPU / 1GB RAM. Postgres: 2 CPU / 4GB RAM.

| Version | Login Page | REST API | GraphQL | Studio |
|---------|-----------|----------|---------|--------|
| 11.15.4 | 118 | 17 | 14 | 14 |
| 11.16.0 | 122 | 15 | 13 | 13 |

## Remote (p95 < 750ms)

Max concurrent VUs where p95 < 750ms. Same retry methodology.

Login page: start 15, +1/5s, max 60. Others: start 2, +1/5s, max 60.

| Version | Login Page | REST API | GraphQL | Studio |
|---------|-----------|----------|---------|--------|
| remote | 15 | 2 | 3 | 2 |
