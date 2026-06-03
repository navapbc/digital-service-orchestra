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
#   get_max_remediation_cycles()
#     → prints the integer value of planning.max_remediation_cycles (default: 3)
#     → exits non-zero with stderr error if value < 2 (never silently clamps)
#   get_call_site_threshold()
#     → prints the integer value of migration.call_site_threshold (default: 3)
#     → exits non-zero with stderr error if value < 1 (never silently clamps)
#
# Environment:
#   WORKFLOW_CONFIG_FILE — override config file path (used for test isolation)
#
# Config keys:
#   planning.external_dependency_block_enabled — boolean (default: false)
#   planning.max_remediation_cycles — integer >= 2 (default: 3)
#   migration.call_site_threshold — integer >= 1 (default: 3)

# Note: no `set` directives here — this is a sourced library; imposing shell
# options would modify the caller's environment.  Callers manage their own
# errexit / nounset posture.

# Locate read-config.sh relative to this file.
# Guard BASH_SOURCE[0]: the variable is unset in non-bash contexts (e.g. zsh)
# and array-index access triggers "parameter not set" under nounset.
_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
_READ_CONFIG="$_PLUGIN_ROOT/scripts/read-config.sh"

# Flag audit (S7 2026-05-18): 1 active flag, 0 legacy flags removed.
# is_external_dep_block_enabled: active — used by preplanning skill.
# get_max_remediation_cycles: active — used by story-decomposer remediation loop.

# is_external_dep_block_enabled
# Returns exit 0 if planning.external_dependency_block_enabled=true, exit 1 otherwise.
# Default is false when the key is absent.
is_external_dep_block_enabled() {
    local _val
    _val=$("$_READ_CONFIG" "planning.external_dependency_block_enabled" 2>/dev/null) || true
    [[ "$_val" == "true" ]]
}

# get_max_remediation_cycles
# Prints the integer value of planning.max_remediation_cycles.
# Default: 3 when key is absent or value is empty.
# Rejection: exits non-zero with a clear stderr message when value < 2.
#            Never silently clamps — callers must catch the error.
# Stderr error format: "planning.max_remediation_cycles must be >= 2 (got: <value>)"
get_max_remediation_cycles() {
    local _val
    _val=$(WORKFLOW_CONFIG_FILE="${WORKFLOW_CONFIG_FILE:-}" "$_READ_CONFIG" "planning.max_remediation_cycles" 2>/dev/null) || true

    # Treat absent or empty as default
    if [[ -z "$_val" ]]; then
        echo "3"
        return 0
    fi

    # Validate: must be an integer >= 2
    if ! [[ "$_val" =~ ^[0-9]+$ ]] || [[ "$_val" -lt 2 ]]; then
        printf "planning.max_remediation_cycles must be >= 2 (got: %s)\n" "$_val" >&2
        return 1
    fi

    echo "$_val"
    return 0
}

# get_call_site_threshold
# Prints the integer value of migration.call_site_threshold.
# Default: 3 when key is absent or value is empty.
# Floor: 1 (minimum accepted value).
# Rejection: exits non-zero with a clear stderr message when value < 1.
#            Never silently clamps — callers must catch the error.
# Stderr error format: "migration.call_site_threshold must be >= 1 (got: <value>)"
get_call_site_threshold() {
    local _val
    _val=$(WORKFLOW_CONFIG_FILE="${WORKFLOW_CONFIG_FILE:-}" "$_READ_CONFIG" "migration.call_site_threshold" 2>/dev/null) || true

    # Treat absent or empty as default
    if [[ -z "$_val" ]]; then
        echo "3"
        return 0
    fi

    # Validate: must be an integer >= 1
    if ! [[ "$_val" =~ ^[0-9]+$ ]] || [[ "$_val" -lt 1 ]]; then
        printf "migration.call_site_threshold must be >= 1 (got: %s)\n" "$_val" >&2
        return 1
    fi

    echo "$_val"
    return 0
}
