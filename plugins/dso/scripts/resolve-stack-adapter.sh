#!/usr/bin/env bash
set -uo pipefail
# scripts/resolve-stack-adapter.sh
# Resolves the stack adapter file path for a project based on dso-config.conf.
#
# Usage:
#   ADAPTER_FILE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-stack-adapter.sh")
#
# Output:
#   stdout — absolute path to the matching adapter YAML file, or empty string if not found
#   exit 0 always (empty output = no adapter found, which is a valid/expected outcome)
#
# Environment:
#   REPO_ROOT — optional; if not set, derived from BASH_SOURCE location
#
# The script reads `stack` and `design.template_engine` from dso-config.conf via
# read-config.sh, then scans config/stack-adapters/*.yaml for a file
# whose selector.stack and selector.template_engine fields match the project config.

set -uo pipefail

# ── Resolve REPO_ROOT ─────────────────────────────────────────────────────────
if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
fi

READ_CONFIG="${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh"

# ── Read stack and template engine from dso-config.conf ──────────────────────
STACK=$("$READ_CONFIG" stack 2>/dev/null || echo "")
TEMPLATE_ENGINE=$("$READ_CONFIG" design.template_engine 2>/dev/null || echo "")

# ── Resolve the adapter file ──────────────────────────────────────────────────
ADAPTER_DIR="${CLAUDE_PLUGIN_ROOT}/config/stack-adapters"
ADAPTER_FILE=""

if [[ -n "$TEMPLATE_ENGINE" ]]; then
    # Try stack-specific adapter first (e.g. flask-jinja2.yaml)
    for candidate in "$ADAPTER_DIR"/*.yaml; do
        [ -f "$candidate" ] || continue
        # Match selector.stack and selector.template_engine in the YAML
        candidate_stack=$(python3 -c "import yaml; d=yaml.safe_load(open('$candidate')); print(d.get('selector',{}).get('stack',''))" 2>/dev/null)
        candidate_engine=$(python3 -c "import yaml; d=yaml.safe_load(open('$candidate')); print(d.get('selector',{}).get('template_engine',''))" 2>/dev/null)
        if [[ "$candidate_stack" == "$STACK" && "$candidate_engine" == "$TEMPLATE_ENGINE" ]]; then
            ADAPTER_FILE="$candidate"
            break
        fi
    done
fi

# ── Output the resolved adapter path (or empty string) to stdout ──────────────
printf '%s' "$ADAPTER_FILE"
