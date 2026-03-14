#!/usr/bin/env bash
# lockpick-workflow/scripts/read-config.sh
# Pure-bash reader for flat KEY=VALUE config files (workflow-config.conf).
#
# Usage (key-first):  read-config.sh [--list] <key> [config-file]
# Usage (config-first): read-config.sh <config-file> <key>
#
# Exit codes:
#   0 — success, missing file, or missing key (scalar mode)
#   1 — missing key in --list mode (distinguishes "empty" from "absent")

set -uo pipefail
list_mode=""; [[ "${1:-}" == "--list" ]] && { list_mode=1; shift; }

# Detect config-first form: first arg contains '/' or ends with .conf/.yaml/.yml
arg1="${1:-}"
if [[ "$arg1" == *"/"* || "$arg1" == *.conf || "$arg1" == *.yaml || "$arg1" == *.yml ]]; then
    config_file="$arg1"; key="${2:-}"
else
    key="$arg1"; config_file="${2:-}"
fi

# Resolve config file when not specified (.conf preferred, .yaml fallback)
if [[ -z "$config_file" ]]; then
    root="${CLAUDE_PLUGIN_ROOT:-$(pwd)}"
    if [[ -f "$root/workflow-config.conf" ]]; then config_file="$root/workflow-config.conf"
    elif [[ -f "$root/workflow-config.yaml" ]]; then config_file="$root/workflow-config.yaml"
    else exit 0; fi
fi
# Missing file: try swapping extension, else exit 0
if [[ ! -f "$config_file" ]]; then
    alt="${config_file%.yaml}.conf"; [[ "$alt" == "$config_file" ]] && alt="${config_file%.conf}.yaml"
    [[ -f "$alt" ]] && config_file="$alt" || exit 0
fi
# Prefer .conf sibling over .yaml when both exist
if [[ "$config_file" == *.yaml || "$config_file" == *.yml ]]; then
    sib="${config_file%.yaml}.conf"; [[ "$config_file" == *.yml ]] && sib="${config_file%.yml}.conf"
    [[ -f "$sib" ]] && config_file="$sib"
fi

# Emit flat KEY=VALUE lines (awk flattens YAML during transition)
# REVIEW-DEFENSE: The awk YAML parser intentionally handles only 2-level scalar YAML.
# .conf is the primary format (takes precedence when both exist); YAML is a transition
# fallback. Callers passing .yaml explicitly get auto-redirected to .conf sibling (lines 36-38).
# Inline lists and 3-level nesting are not needed — real config uses .conf format.
_lines() {
    if [[ "$config_file" == *.yaml || "$config_file" == *.yml ]]; then
        awk '/^\s*#/{next}/^[^ ][^:]*:$/{sub(/:$/,"");p=$0;next}/^[^ ][^:]*: /{k=$0;sub(/: .*/,"",k);v=$0;sub(/^[^:]*: /,"",v);gsub(/"/,"",v);print k"="v;next}/^  [^ ]/{l=$0;sub(/^  /,"",l);k=l;sub(/: .*/,"",k);v=l;sub(/^[^:]*: /,"",v);gsub(/"/,"",v);print p"."k"="v}' "$config_file"
    else grep -v '^\s*#' "$config_file"; fi
}

# Extract value(s) for the requested key
if [[ -n "$list_mode" ]]; then
    results=$(_lines | grep "^${key}=" | cut -d= -f2-)
    [[ -n "$results" ]] && { printf '%s\n' "$results"; exit 0; }; exit 1
else
    printf '%s' "$(_lines | grep -m1 "^${key}=" | cut -d= -f2-)"; exit 0
fi
