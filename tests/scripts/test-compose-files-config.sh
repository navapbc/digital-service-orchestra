#!/usr/bin/env bash
# tests/scripts/test-compose-files-config.sh
# Tests that dso-config.conf contains the infrastructure.compose_files key
# readable by read-config.sh in --list mode.
#
# Usage: bash tests/scripts/test-compose-files-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/read-config.sh"

# Create an inline fixture config instead of depending on project config
CONFIG="$(mktemp)"
trap 'rm -f "$CONFIG"' EXIT
cat > "$CONFIG" <<'FIXTURE'
infrastructure.compose_files=app/docker-compose.yml
infrastructure.compose_files=app/docker-compose.db.yml
FIXTURE

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-compose-files-config.sh ==="

# ── test_infrastructure_compose_files_config_readable ────────────────────────
# infrastructure.compose_files must return two entries via --list mode:
#   line 1: app/docker-compose.yml
#   line 2: app/docker-compose.db.yml
_snapshot_fail
cf_exit=0
cf_output=""
cf_output=$(bash "$SCRIPT" --list infrastructure.compose_files "$CONFIG" 2>&1) || cf_exit=$?
assert_eq "test_infrastructure_compose_files_config_readable: exit 0" "0" "$cf_exit"

cf_first=$(echo "$cf_output" | head -1)
cf_second=$(echo "$cf_output" | tail -1)
assert_eq "test_infrastructure_compose_files_config_readable: first entry is app/docker-compose.yml" "app/docker-compose.yml" "$cf_first"
assert_eq "test_infrastructure_compose_files_config_readable: second entry is app/docker-compose.db.yml" "app/docker-compose.db.yml" "$cf_second"
assert_pass_if_clean "test_infrastructure_compose_files_config_readable"

print_summary
