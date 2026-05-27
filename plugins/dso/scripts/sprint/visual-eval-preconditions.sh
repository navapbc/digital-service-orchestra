#!/usr/bin/env bash
# Shared precondition gates for visual evaluator integration.
# Checks: enabled flag, project_type, playwright, local-env, route-map freshness.
# On failure: prints reason code to stdout, exits 1.
# On success: exits 0.
#
# Flags:
#   --route-map-required  Also check route-map existence and freshness

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"

ROUTE_MAP_REQUIRED=false
for arg in "$@"; do
  case "$arg" in
    --route-map-required) ROUTE_MAP_REQUIRED=true ;;
  esac
done

# Gate 0: visual_evaluator.enabled
ENABLED=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.enabled 2>/dev/null || echo "false")
if [[ "$ENABLED" != "true" ]]; then
  echo "not_enabled"
  exit 1
fi

# Gate 1: project_type=web
PROJECT_TYPE=$(bash "$PLUGIN_SCRIPTS/read-config.sh" project.type 2>/dev/null || echo "")
if [[ "$PROJECT_TYPE" != "web" ]]; then
  echo "not_web_project"
  exit 1
fi

# Gate 2: playwright_available
if ! command -v npx >/dev/null 2>&1 || ! npx --no-install playwright --version >/dev/null 2>&1; then
  echo "playwright_unavailable"
  exit 1
fi

# Gate 3: check-local-env.sh
if [[ -f "$PLUGIN_SCRIPTS/check-local-env.sh" ]]; then
  if ! bash "$PLUGIN_SCRIPTS/check-local-env.sh" >/dev/null 2>&1; then
    echo "local_env_check_failed"
    exit 1
  fi
fi

# Gate 4: route_map (only when --route-map-required)
if [[ "$ROUTE_MAP_REQUIRED" == "true" ]]; then
  ROUTE_MAP=".ui-discovery-cache/route-map.json"
  MAX_AGE_HOURS=$(bash "$PLUGIN_SCRIPTS/read-config.sh" visual_evaluator.route_map_max_age_hours 2>/dev/null || echo "24")
  [[ -z "$MAX_AGE_HOURS" ]] && MAX_AGE_HOURS=24

  if [[ ! -f "$ROUTE_MAP" ]]; then
    echo "route_map_missing"
    exit 1
  fi

  if [[ "$(uname)" == "Darwin" ]]; then
    map_mtime=$(stat -f %m "$ROUTE_MAP")
  else
    map_mtime=$(stat -c %Y "$ROUTE_MAP")
  fi
  now=$(date +%s)
  age_hours=$(( (now - map_mtime) / 3600 ))
  if [[ $age_hours -ge $MAX_AGE_HOURS ]]; then
    echo "route_map_stale"
    exit 1
  fi
fi

exit 0
