#!/usr/bin/env bash
# commit-override.sh — writes override token and appends to audit log.
# Contract: docs/contracts/commit-override-token.md (relative to plugin root)
set -uo pipefail

# ── Parse arguments ──
_reason=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --reason=*)
            _reason="${1#--reason=}"
            shift
            ;;
        --reason)
            if [[ $# -gt 1 ]]; then
                _reason="$2"
                shift 2
            else
                shift
            fi
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -z "$_reason" ]]; then
    echo "ERROR: --reason=<text> is required" >&2
    echo "Usage: $(basename "$0") --reason=\"<reason text>\"" >&2
    exit 1
fi

# ── TTY check ──
if [ -t 0 ] || [[ -n "${DSO_FORCE_INTERACTIVE:-}" ]]; then
    : # interactive or forced — allowed
else
    echo "ERROR: commit-override must be invoked interactively" >&2
    exit 1
fi

# ── Autonomous mode check ──
if [[ -n "${DSO_FBKY_AUTONOMOUS_MODE:-}" ]]; then
    echo "ERROR: commit-override unavailable in autonomous mode" >&2
    exit 1
fi

# ── Resolve plugin root and source deps.sh ──
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${_SCRIPT_DIR}/..}"
_DEPS_PATH="${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
if [[ -f "$_DEPS_PATH" ]]; then
    # shellcheck source=hooks/lib/deps.sh
    source "$_DEPS_PATH"
else
    echo "ERROR: deps.sh not found at $_DEPS_PATH" >&2
    exit 1
fi

# ── Resolve artifacts dir ──
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"

# ── Compute diff hash ──
_diff_hash=$(git diff --cached 2>/dev/null | sha256sum | cut -c1-12)

# ── Build timestamp (ISO 8601 UTC) ──
_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# ── Write override.token atomically ──
_token_file="$ARTIFACTS_DIR/override.token"
_token_tmp=$(mktemp "${ARTIFACTS_DIR}/override.token.tmp.XXXXXX")

python3 -c "
import json, sys
data = {
    'diff_hash': sys.argv[1],
    'reason': sys.argv[2],
    'timestamp': sys.argv[3],
    'attribution': {'skill_name': None, 'agent_id': None}
}
print(json.dumps(data, indent=2))
" "$_diff_hash" "$_reason" "$_timestamp" > "$_token_tmp" || {
    echo "ERROR: failed to write override token" >&2
    rm -f "$_token_tmp"
    exit 1
}

mv "$_token_tmp" "$_token_file"

# ── Append JSON Lines entry to commit-overrides.log ──
_log_file="$ARTIFACTS_DIR/commit-overrides.log"
python3 -c "
import json, sys
entry = {
    'diff_hash': sys.argv[1],
    'reason': sys.argv[2],
    'timestamp': sys.argv[3],
    'attribution': {'skill_name': None, 'agent_id': None}
}
print(json.dumps(entry))
" "$_diff_hash" "$_reason" "$_timestamp" >> "$_log_file" || {
    echo "ERROR: failed to append to commit-overrides.log" >&2
    exit 1
}

echo "Override token written: $_token_file"
echo "Override log updated: $_log_file"
