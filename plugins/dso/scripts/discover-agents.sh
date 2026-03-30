#!/usr/bin/env bash
set -uo pipefail
# scripts/discover-agents.sh
# Agent discovery pipeline: reads enabledPlugins from .claude/settings.json,
# walks agent-routing.conf preference chains, outputs resolved routing.
#
# Usage:
#   discover-agents.sh [--settings <path>] [--routing <path>]
#
# Options:
#   --settings <path>  Path to .claude/settings.json (default: $REPO_ROOT/.claude/settings.json)
#   --routing <path>   Path to agent-routing.conf (default: ${CLAUDE_PLUGIN_ROOT}/config/agent-routing.conf)
#
# Output (stdout): <category>=<resolved-agent> pairs, one per line
# Logging (stderr): [agent-dispatch] category=<cat> routed=<type> reason=<available|fallback>
#
# Exit codes:
#   0 — success (including graceful degradation for missing/malformed settings.json)
#   1 — missing agent-routing.conf

set -uo pipefail

# ── Resolve repo root ────────────────────────────────────────────────────────
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$_script_dir" && git rev-parse --show-toplevel)"

# ── Parse arguments ──────────────────────────────────────────────────────────
settings_file="$REPO_ROOT/.claude/settings.json"
routing_file="${CLAUDE_PLUGIN_ROOT:-}/config/agent-routing.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --settings) settings_file="$2"; shift 2 ;;
        --routing)  routing_file="$2"; shift 2 ;;
        *)          echo "Error: unknown option '$1'" >&2; exit 2 ;;
    esac
done

# ── Validate routing conf ───────────────────────────────────────────────────
if [[ ! -f "$routing_file" ]]; then
    echo "Error: agent-routing.conf not found at $routing_file" >&2
    exit 1
fi

# ── Extract enabledPlugins from settings.json ────────────────────────────────
# Uses Python (no jq dependency, matching plugin conventions)
_EXTRACT_PLUGINS='
import json, sys

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plugins = data.get("enabledPlugins", {})
    for key, val in plugins.items():
        if val:
            print(key)
except Exception:
    pass  # graceful degradation: treat as no plugins
'

enabled_plugins=""
if [[ -f "$settings_file" ]]; then
    enabled_plugins=$(python3 -c "$_EXTRACT_PLUGINS" "$settings_file" 2>/dev/null) || true
fi

# Build a lookup set: extract plugin name (part before @) from each enabled key
# e.g. "unit-testing@claude-code-workflows" -> "unit-testing"
declare -A plugin_available
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    plugin_name="${line%%@*}"
    plugin_available["$plugin_name"]=1
done <<< "$enabled_plugins"

# ── Process routing conf ────────────────────────────────────────────────────
while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    # Validate format: category=chain
    if ! echo "$line" | grep -qE '^[a-z_]+=.+'; then
        echo "[agent-dispatch] skipping malformed line: $line" >&2
        continue
    fi

    category="${line%%=*}"
    chain="${line#*=}"

    # Walk preference chain left-to-right
    resolved=""
    reason=""
    IFS='|' read -ra agents <<< "$chain"
    for agent in "${agents[@]}"; do
        if [[ "$agent" == "general-purpose" ]]; then
            resolved="general-purpose"
            reason="fallback"
            break
        fi
        # Extract plugin name from agent identifier (plugin-name:agent-name)
        agent_plugin="${agent%%:*}"
        # dso: agents are local plugin agents resolved via plugins/dso/agents/<name>.md;
        # they are always available and do not require an enabledPlugins entry.
        if [[ "$agent_plugin" == "dso" ]]; then
            resolved="$agent"
            reason="available"
            break
        fi
        if [[ -n "${plugin_available[$agent_plugin]+_}" ]]; then
            resolved="$agent"
            reason="available"
            break
        fi
    done

    # Safety: if chain was exhausted without match (shouldn't happen with general-purpose sentinel)
    if [[ -z "$resolved" ]]; then
        resolved="general-purpose"
        reason="fallback"
    fi

    echo "[agent-dispatch] category=$category routed=$resolved reason=$reason" >&2
    echo "$category=$resolved"
done < "$routing_file"
