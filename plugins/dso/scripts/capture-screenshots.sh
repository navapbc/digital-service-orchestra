#!/usr/bin/env bash
# Screenshot capture pipeline for visual evaluator.
# Reads route-map.json, resolves local server, captures PNGs via Playwright.
# Outputs the temp directory path containing captured screenshots on stdout.
#
# Flags:
#   --skip-preconditions  Skip precondition gates (caller already checked)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"

SKIP_PRECONDITIONS=false
for arg in "$@"; do
  case "$arg" in
    --skip-preconditions) SKIP_PRECONDITIONS=true ;;
  esac
done

ROUTE_MAP=".ui-discovery-cache/route-map.json"
SCREENSHOT_WAIT_MS="${VISUAL_EVAL_SCREENSHOT_WAIT_MS:-3000}"
VIEWPORT_WIDTH="${VISUAL_EVAL_VIEWPORT_WIDTH:-1280}"
VIEWPORT_HEIGHT="${VISUAL_EVAL_VIEWPORT_HEIGHT:-800}"
CAPTURE_TIMEOUT="${VISUAL_EVAL_CAPTURE_TIMEOUT:-15}"

# Read config values if read-config.sh is available
if [[ -f "$PLUGIN_SCRIPTS/read-config.sh" ]]; then
  BASE_URL=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.base_url 2>/dev/null || echo "")
  WAIT_MS_CFG=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.screenshot_wait_ms 2>/dev/null || echo "")
  TIMEOUT_CFG=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.capture_timeout 2>/dev/null || echo "")
  [[ -n "$WAIT_MS_CFG" ]] && SCREENSHOT_WAIT_MS="$WAIT_MS_CFG"
  [[ -n "$TIMEOUT_CFG" ]] && CAPTURE_TIMEOUT="$TIMEOUT_CFG"
fi

# Precondition gates (skipped when called from integration scripts)
if [[ "$SKIP_PRECONDITIONS" != "true" ]]; then
  # Gate: route-map exists
  if [[ ! -f "$ROUTE_MAP" ]]; then
    echo "visual_eval_inapplicable:route_map_missing" >&2
    exit 1
  fi

  # Gate: route-map freshness
  MAX_AGE_HOURS="${VISUAL_EVAL_ROUTE_MAP_MAX_AGE_HOURS:-24}"
  if [[ -f "$PLUGIN_SCRIPTS/read-config.sh" ]]; then
    MAX_AGE_CFG=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.route_map_max_age_hours 2>/dev/null || echo "")
    [[ -n "$MAX_AGE_CFG" ]] && MAX_AGE_HOURS="$MAX_AGE_CFG"
  fi
  if command -v stat >/dev/null 2>&1; then
    if [[ "$(uname)" == "Darwin" ]]; then
      map_mtime=$(stat -f %m "$ROUTE_MAP")
    else
      map_mtime=$(stat -c %Y "$ROUTE_MAP")
    fi
    now=$(date +%s)
    age_hours=$(( (now - map_mtime) / 3600 ))
    if [[ $age_hours -ge $MAX_AGE_HOURS ]]; then
      echo "visual_eval_inapplicable:route_map_stale" >&2
      exit 1
    fi
  fi

  # Gate: Playwright available
  if ! command -v npx >/dev/null 2>&1 || ! npx --no-install playwright --version >/dev/null 2>&1; then
    echo "visual_eval_inapplicable:playwright_unavailable" >&2
    exit 1
  fi
fi

# Resolve BASE_URL
resolve_base_url() {
  if [[ -n "${BASE_URL:-}" ]]; then
    if curl -sf --max-time 2 "$BASE_URL" >/dev/null 2>&1; then
      echo "$BASE_URL"
      return 0
    fi
  fi
  for port in 3000 8000 5000; do
    local url="http://localhost:$port"
    if curl -sf --max-time 2 "$url" >/dev/null 2>&1; then
      echo "$url"
      return 0
    fi
  done
  return 1
}

RESOLVED_URL=$(resolve_base_url) || {
  echo "visual_eval_inapplicable:no_local_server" >&2
  exit 1
}

# Create output directory with trap cleanup
OUTPUT_DIR=$(mktemp -d /tmp/visual-eval-capture.XXXXXX)
trap '[[ -d "${OUTPUT_DIR:-}" ]] && rm -rf "$OUTPUT_DIR"' EXIT

# Extract routes using helper script
ROUTES=$(python3 "$PLUGIN_SCRIPTS/visual-eval-routes.py" --route-map "$ROUTE_MAP" 2>/dev/null)

if [[ -z "$ROUTES" ]]; then
  echo "visual_eval_inapplicable:route_map_empty" >&2
  exit 1
fi

capture_count=0
while IFS= read -r route; do
  [[ -z "$route" ]] && continue
  safe_name=$(echo "$route" | sed 's|^/||; s|/|__|g; s|[^a-zA-Z0-9_-]|_|g')
  [[ -z "$safe_name" ]] && safe_name="index"

  full_url="${RESOLVED_URL}${route}"
  output_file="${OUTPUT_DIR}/${safe_name}.png"

  timeout "$CAPTURE_TIMEOUT" npx playwright screenshot \
    --viewport-size="${VIEWPORT_WIDTH},${VIEWPORT_HEIGHT}" \
    --wait-for-timeout="$SCREENSHOT_WAIT_MS" \
    "$full_url" "$output_file" 2>/dev/null && capture_count=$((capture_count + 1)) || true
done <<< "$ROUTES"

if [[ $capture_count -eq 0 ]]; then
  echo "visual_eval_inapplicable:capture_failed" >&2
  exit 1
fi

# Disable trap — caller owns cleanup
trap - EXIT
echo "$OUTPUT_DIR"
