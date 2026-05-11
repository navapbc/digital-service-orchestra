#!/usr/bin/env bash
set -uo pipefail

# Usage:
#   preconditions-ack.sh <story_id> <decision_id> --if-skipped "<rationale>"
#   preconditions-ack.sh <story_id> --sample-ack --class=<degradation_class> --if-skipped "<rationale>"
# Writes an ACK event JSON acknowledging a degradation decision from a PRECONDITIONS event.

story_id="${1:-}"
if_skipped=""
sample_ack=false
degradation_class=""

# Detect --sample-ack mode (no decision_id arg)
if [[ "${2:-}" == --sample-ack ]] || [[ "${2:-}" == --class=* ]] || [[ "${2:-}" == --if-skipped* ]]; then
    decision_id=""
    shift 1 2>/dev/null || true
else
    decision_id="${2:-}"
    shift 2 2>/dev/null || { echo "Usage: preconditions-ack.sh <story_id> <decision_id> --if-skipped <rationale>" >&2; exit 1; }
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sample-ack) sample_ack=true; shift ;;
        --class=*) degradation_class="${1#*=}"; shift ;;
        --class) degradation_class="${2:-}"; shift 2 ;;
        --if-skipped) if_skipped="${2:-}"; shift 2 ;;
        --if-skipped=*) if_skipped="${1#*=}"; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$story_id" || -z "$if_skipped" ]]; then
    echo "Usage: preconditions-ack.sh <story_id> <decision_id> --if-skipped <rationale>" >&2
    exit 1
fi

if [[ "$sample_ack" == false && -z "$decision_id" ]]; then
    echo "Usage: preconditions-ack.sh <story_id> <decision_id> --if-skipped <rationale>" >&2
    exit 1
fi

if [[ "$sample_ack" == true && -z "$degradation_class" ]]; then
    echo "ERROR: --sample-ack requires --class=<degradation_class>" >&2
    exit 1
fi

# Resolve tickets tracker dir
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
_TRACKER_DIR="${DSO_TICKETS_TRACKER_DIR:-${_REPO_ROOT:+$_REPO_ROOT/.tickets-tracker}}"

if [[ -z "$_TRACKER_DIR" || ! -d "$_TRACKER_DIR/$story_id" ]]; then
    echo "ERROR: ticket directory not found: ${_TRACKER_DIR:-<unresolved>}/$story_id" >&2
    exit 1
fi

_VALIDATOR="${_SCRIPT_DIR}/validate-ack-rationale.sh"
if [[ ! -x "$_VALIDATOR" ]]; then
    echo "ERROR: validate-ack-rationale.sh not found at $_VALIDATOR" >&2
    exit 1
fi

# ── Sample-ack mode ───────────────────────────────────────────────────────────
if [[ "$sample_ack" == true ]]; then
    # Collect all decision_ids from PRECONDITIONS events matching the degradation_class
    mapfile -t _all_ids < <(
        find "$_TRACKER_DIR/$story_id" -maxdepth 1 -name '*-PRECONDITIONS.json' 2>/dev/null | sort | while read -r _f; do
            python3 - "$_f" "$degradation_class" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    data = d.get('data', {})
    if data.get('degradation_type') == sys.argv[2]:
        for did in data.get('decision_ids', []):
            print(did)
except Exception:
    pass
PYEOF
        done | sort -u
    )

    _N="${#_all_ids[@]}"
    if (( _N < 4 )); then
        echo "ERROR: class $degradation_class has $_N entries; sample-ack requires >=4 (use regular preconditions-ack for smaller classes)" >&2
        exit 1
    fi

    # SHA256 deterministic selection
    mapfile -t _sorted < <(printf '%s\n' "${_all_ids[@]}" | sort)
    _digest=$(printf '%s\n' "${_sorted[@]}" | sha256sum | awk '{print $1}')
    _seed=$(printf '%d' "0x${_digest:0:8}")

    _i1=$(( _seed % _N ))
    _id1="${_sorted[_i1]}"
    mapfile -t _remaining < <(printf '%s\n' "${_sorted[@]}" | grep -vxF "$_id1")

    _i2=$(( (_seed >> 8) % (_N - 1) ))
    _id2="${_remaining[_i2]}"
    mapfile -t _remaining2 < <(printf '%s\n' "${_remaining[@]}" | grep -vxF "$_id2")

    _i3=$(( (_seed >> 16) % (_N - 2) ))
    _id3="${_remaining2[_i3]}"

    # Validate rationale against each of the 3 sampled decision_ids
    # Find condition_text for a given decision_id from PRECONDITIONS events
    _get_condition_text() {
        local _did="$1"
        find "$_TRACKER_DIR/$story_id" -maxdepth 1 -name '*-PRECONDITIONS.json' 2>/dev/null | sort | while read -r _pf; do
            python3 - "$_pf" "$_did" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
    data = d.get('data', {})
    if sys.argv[2] in data.get('decision_ids', []):
        ct = data.get('condition_text', '')
        if ct:
            print(ct)
            import sys as _sys; _sys.exit(0)
except Exception:
    pass
PYEOF
        done | head -1
    }

    for _sampled_id in "$_id1" "$_id2" "$_id3"; do
        _ct=$(_get_condition_text "$_sampled_id")
        if [[ -z "$_ct" ]]; then
            _ct="$_sampled_id"
        fi
        "$_VALIDATOR" "$if_skipped" "$_ct"
        _v_exit=$?
        if (( _v_exit == 2 )); then
            echo "Rationale validation requires human review (non-Latin precondition). Ack cannot be written automatically." >&2
            exit 1
        elif (( _v_exit != 0 )); then
            exit 1
        fi
    done

    # Write one ACK JSON with sampled_set
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    _ts_file=$(date -u +%Y%m%dT%H%M%SZ)
    _class_lower=$(echo "$degradation_class" | tr '[:upper:]' '[:lower:]')
    _ack_file="$_TRACKER_DIR/$story_id/${_ts_file}-sample-${_class_lower}-ACK.json"

    python3 - "$_ack_file" "$_ts" "$if_skipped" "$_id1" "$_id2" "$_id3" "${_all_ids[@]}" <<'PYEOF'
import json, sys
ack_file, ts, if_skipped = sys.argv[1], sys.argv[2], sys.argv[3]
sampled = [sys.argv[4], sys.argv[5], sys.argv[6]]
all_ids = list(sys.argv[7:])
ack = {
    "decision_ids": all_ids,
    "if_skipped": if_skipped,
    "timestamp": ts,
    "sampled_set": sampled,
    "schema_version": 1,
}
with open(ack_file, "w") as f:
    json.dump(ack, f, indent=2)
PYEOF

    echo "ACK written: $_ack_file"
    exit 0
fi

# ── Regular single-decision mode ──────────────────────────────────────────────

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

python3 - "$_ack_file" "$decision_id" "$if_skipped" "$_ts" <<'PYEOF'
import json, sys
ack_file, decision_id, if_skipped, ts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ack = {
    "decision_ids": [decision_id],
    "if_skipped": if_skipped,
    "timestamp": ts,
    "sampled_set": None,
    "schema_version": 1,
}
with open(ack_file, "w") as f:
    json.dump(ack, f, indent=2)
PYEOF

echo "ACK written: $_ack_file"
