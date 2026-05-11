#!/usr/bin/env bash
set -uo pipefail

# Usage: preconditions-ack.sh <story_id> <decision_id> --if-skipped "<rationale>"
# Writes an ACK event JSON acknowledging a degradation decision from a PRECONDITIONS event.

story_id="${1:-}"
decision_id="${2:-}"
if_skipped=""

shift 2 2>/dev/null || { echo "Usage: preconditions-ack.sh <story_id> <decision_id> --if-skipped <rationale>" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --if-skipped) if_skipped="${2:-}"; shift 2 ;;
        --if-skipped=*) if_skipped="${1#*=}"; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$story_id" || -z "$decision_id" || -z "$if_skipped" ]]; then
    echo "Usage: preconditions-ack.sh <story_id> <decision_id> --if-skipped <rationale>" >&2
    exit 1
fi

# Resolve tickets tracker dir
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"
_REPO_ROOT="$(git -C "$_PLUGIN_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "")"
_TRACKER_DIR="${DSO_TICKETS_TRACKER_DIR:-${_REPO_ROOT:+$_REPO_ROOT/.tickets-tracker}}"

if [[ -z "$_TRACKER_DIR" || ! -d "$_TRACKER_DIR/$story_id" ]]; then
    echo "ERROR: ticket directory not found: ${_TRACKER_DIR:-<unresolved>}/$story_id" >&2
    exit 1
fi

# Find latest PRECONDITIONS event
_prec_file=$(find "$_TRACKER_DIR/$story_id" -maxdepth 1 -name '*-PRECONDITIONS.json' 2>/dev/null | sort -r | head -1)
if [[ -z "$_prec_file" ]]; then
    echo "ERROR: no PRECONDITIONS event found for story $story_id" >&2
    exit 1
fi

# Extract condition_text
_condition_text=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('data',{}).get('condition_text',''))" "$_prec_file" 2>/dev/null || echo "")
if [[ -z "$_condition_text" ]]; then
    _condition_text=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('gate_name','unknown'))" "$_prec_file" 2>/dev/null || echo "unknown")
fi

# Validate rationale
_VALIDATOR="${_SCRIPT_DIR}/validate-ack-rationale.sh"
if [[ ! -x "$_VALIDATOR" ]]; then
    echo "ERROR: validate-ack-rationale.sh not found at $_VALIDATOR" >&2
    exit 1
fi

"$_VALIDATOR" "$if_skipped" "$_condition_text"
_v_exit=$?
if (( _v_exit == 2 )); then
    echo "Rationale validation requires human review (non-Latin precondition). Ack cannot be written automatically." >&2
    exit 1
elif (( _v_exit != 0 )); then
    exit 1
fi

# Write ACK JSON
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
_ts_file=$(date -u +%Y%m%dT%H%M%SZ)
_safe_id=$(echo "$decision_id" | tr ':/' '_')
_ack_file="$_TRACKER_DIR/$story_id/${_ts_file}-${_safe_id}-ACK.json"

python3 - <<PYEOF
import json
ack = {
    "decision_ids": ["$decision_id"],
    "if_skipped": "$if_skipped",
    "timestamp": "$_ts",
    "sampled_set": None,
    "schema_version": 1,
}
with open("$_ack_file", "w") as f:
    json.dump(ack, f, indent=2)
PYEOF

echo "ACK written: $_ack_file"
