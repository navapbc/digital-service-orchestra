#!/usr/bin/env bash
set -uo pipefail
# lockpick-workflow/scripts/read-config.sh
# conf reader for workflow-config.conf files.
#
# Usage (key-first):  read-config.sh [--list] [--batch] <key> [config-file]
# Usage (config-first): read-config.sh [--list] [--batch] <config-file> <key>
#
# Supports:
#   - Flat key=value format (dot-notation keys like "tickets.sync.jira_project_key")
#   - List mode with --list flag (returns value on one line; exit 1 if absent)
#   - Batch mode with --batch flag (outputs all keys as UPPER_CASE_WITH_UNDERSCORES=value)
#   - Missing file → empty output, exit 0
#   - Absent key in scalar mode → empty output, exit 0
#   - Absent key in --list mode → exit 1
#
# Exit codes:
#   0 — success, missing file, or missing key (scalar mode)
#   1 — missing key in --list mode (distinguishes "empty" from "absent")

list_mode=""; batch_mode=""; [[ "${1:-}" == "--list" ]] && { list_mode=1; shift; }
[[ "${1:-}" == "--batch" ]] && { batch_mode=1; shift; }

# Detect config-first form: first arg contains '/' or ends with .conf
arg1="${1:-}"
if [[ "$arg1" == *"/"* || "$arg1" == *.conf ]]; then
    config_file="$arg1"; key="${2:-}"
else
    key="$arg1"; config_file="${2:-}"
fi

# Resolve config file when not specified (.conf only)
if [[ -z "$config_file" ]]; then
    root="${CLAUDE_PLUGIN_ROOT:-$(pwd)}"
    if [[ -f "$root/workflow-config.conf" ]]; then config_file="$root/workflow-config.conf"
    else exit 0; fi
fi
# Missing file: exit 0 (graceful degradation)
if [[ ! -f "$config_file" ]]; then
    exit 0
fi

# ── .conf format: flat KEY=VALUE lines ───────────────────────────────────────
_conf_lines() { grep -v '^\s*#' "$config_file"; }
if [[ -n "$batch_mode" ]]; then
    # Output all keys as UPPER_CASE_WITH_UNDERSCORES=value lines (safe for eval)
    while read -r line; do
        [[ -z "$line" ]] && continue
        raw_key="${line%%=*}"
        raw_val="${line#*=}"
        var_name="${raw_key^^}"        # uppercase
        var_name="${var_name//./_}"    # dots to underscores
        # Single-quote value for safe eval; escape any single quotes in value
        safe_val="${raw_val//\'/\'\\\'\'}"
        printf "%s='%s'\n" "$var_name" "$safe_val"
    done < <(_conf_lines | grep -E '^[^=]+=')
    exit 0
elif [[ -n "$list_mode" ]]; then
    results=$(_conf_lines | grep "^${key}=" | cut -d= -f2-)
    [[ -n "$results" ]] && { printf '%s\n' "$results"; exit 0; }; exit 1
else
    printf '%s' "$(_conf_lines | grep -m1 "^${key}=" | cut -d= -f2-)"; exit 0
fi
