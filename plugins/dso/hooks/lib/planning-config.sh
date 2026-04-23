#!/usr/bin/env bash
# hooks/lib/planning-config.sh
# Planning feature-flag helpers for hooks and scripts.
#
# Usage (source into scripts):
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/planning-config.sh"
#
# Provides:
#   is_external_dep_block_enabled()
#     → exit 0 if planning.external_dependency_block_enabled=true, exit 1 otherwise
#
# Environment:
#   WORKFLOW_CONFIG_FILE — override config file path (used for test isolation)
#
# Config key:
#   planning.external_dependency_block_enabled — boolean (default: false)

set -uo pipefail

# Locate read-config.sh relative to this file
_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_READ_CONFIG="$_PLUGIN_ROOT/scripts/read-config.sh"

# is_external_dep_block_enabled
# Returns exit 0 if planning.external_dependency_block_enabled=true, exit 1 otherwise.
# Default is false when the key is absent.
is_external_dep_block_enabled() {
    local _val
    _val=$("$_READ_CONFIG" "planning.external_dependency_block_enabled" 2>/dev/null) || true
    [[ "$_val" == "true" ]]
}
