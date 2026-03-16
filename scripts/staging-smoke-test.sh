#!/usr/bin/env bash
set -uo pipefail
# scripts/staging-smoke-test.sh
# Staging health check and route scan (Tier 0 deterministic pre-checks).
#
# Usage:
#   STAGING_URL=https://... [HEALTH_PATH=/health] [ROUTES=/,/api] bash staging-smoke-test.sh
#   bash staging-smoke-test.sh <STAGING_URL> [HEALTH_PATH] [ROUTES]
#
# Env vars:
#   STAGING_URL    — base URL of the staging environment (required)
#   HEALTH_PATH    — health endpoint path (default: /health)
#   ROUTES         — comma-separated list of routes to scan (default: /)
#
# Exit codes:
#   0 — all checks pass
#   1 — one or more checks failed or STAGING_URL not provided

set -uo pipefail

# ── Argument / env resolution ─────────────────────────────────────────────────
STAGING_URL="${STAGING_URL:-${1:-}}"
HEALTH_PATH="${HEALTH_PATH:-${2:-/health}}"
ROUTES="${ROUTES:-${3:-/}}"

if [[ -z "$STAGING_URL" ]]; then
    echo "Error: STAGING_URL is required." >&2
    echo "Usage: STAGING_URL=https://... bash $(basename "$0") [HEALTH_PATH] [ROUTES]" >&2
    exit 1
fi

FAIL=0

# ── Health check via curl ─────────────────────────────────────────────────────
HEALTH_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "$STAGING_URL$HEALTH_PATH" 2>/dev/null || echo "error")
echo "Health endpoint ($HEALTH_PATH): $HEALTH_STATUS"

if [[ "$HEALTH_STATUS" == "error" || "$HEALTH_STATUS" == 5* ]]; then
    FAIL=1
fi

# ── Route scan (split ROUTES on commas) ──────────────────────────────────────
IFS=',' read -ra ROUTE_LIST <<< "$ROUTES"
for route in "${ROUTE_LIST[@]}"; do
    route="$(echo "$route" | xargs)"  # trim whitespace
    STATUS=$(curl -sf -o /dev/null -w "%{http_code}" "$STAGING_URL$route" 2>/dev/null || echo "error")
    echo "Route $route: $STATUS"
    if [[ "$STATUS" == "error" || "$STATUS" == 5* ]]; then
        FAIL=1
    fi
done

exit "$FAIL"
