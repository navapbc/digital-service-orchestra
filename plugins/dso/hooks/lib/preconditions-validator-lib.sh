#!/usr/bin/env bash
# preconditions-validator-lib.sh
# Shared library for stage-boundary preconditions validation.
# Sourced (not executed) by skill/workflow orchestrators and agents.
#
# Provides:
#   _dso_pv_entry_check(stage_name, upstream_stage_name, ticket_id)
#     Reads the latest upstream PRECONDITIONS event via _read_latest_preconditions,
#     validates the minimal-tier required fields (depth-agnostic: unknown fields ignored),
#     emits a diagnostic to stderr on failure, returns exit 1 on invalid/missing.
#
#   _dso_pv_exit_write(stage_name, upstream_event_id, spec_hash, ticket_id)
#     Writes a new PRECONDITIONS event for stage_name, sets upstream_event_id for
#     cross-stage chain linking, runs a schema roundtrip self-check, returns exit 1
#     if roundtrip fails.
#
# Design constraints:
#   - Uses _PLUGIN_ROOT_PV_LIB resolved from BASH_SOURCE[0] — never hardcodes plugin path
#   - Depth-agnostic: validates only minimal-tier fields; extra fields silently accepted
#   - Fail-open callers: both functions return non-zero on error; callers apply || true
#   - ZERO user interaction: no prompts, no stdin reads
#   - Idempotent guard: only loaded once per shell context

# Guard: only load once
[[ "${_DSO_PV_LIB_LOADED:-}" == "1" ]] && return 0
_DSO_PV_LIB_LOADED=1

# Resolve plugin root from this lib file's location:
# This file lives at <plugin_root>/hooks/lib/ — so go two levels up to reach plugin root.
_PLUGIN_ROOT_PV_LIB="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" && cd ../.. && pwd)"

# Source ticket-lib.sh for _read_latest_preconditions and _write_preconditions.
# Use _PLUGIN_ROOT_PV_LIB so no literal plugin path appears here.
# shellcheck source=/dev/null
source "${_PLUGIN_ROOT_PV_LIB}/scripts/ticket-lib.sh" 2>/dev/null || true

# ── Minimal-tier required fields (depth-agnostic: extra fields silently pass) ─
# From preconditions-schema-v2.md: minimal tier must have these fields present
_DSO_PV_MINIMAL_REQUIRED_FIELDS=(
    "event_type"
    "gate_name"
    "session_id"
    "worktree_id"
    "tier"
    "timestamp"
    "data"
)

# _dso_pv_validate_minimal_fields <json_string>
# Returns exit 0 if all minimal-tier required fields are present and event_type==PRECONDITIONS.
# Returns exit 1 on missing/invalid fields, prints diagnostic to stderr.
_dso_pv_validate_minimal_fields() {
    local json_content="$1"
    python3 - "$json_content" <<'PYEOF'
import json, sys

json_content = sys.argv[1]

required_fields = [
    "event_type", "gate_name", "session_id", "worktree_id",
    "tier", "timestamp", "data"
]

try:
    data = json.loads(json_content)
except (ValueError, json.JSONDecodeError) as e:
    print(f"[DSO PRECONDITIONS] validation error: could not parse JSON: {e}", file=sys.stderr)
    sys.exit(1)

# Check event_type is PRECONDITIONS (case-insensitive)
event_type = data.get("event_type", "")
if str(event_type).upper() != "PRECONDITIONS":
    print(
        f"[DSO PRECONDITIONS] validation error: expected event_type=PRECONDITIONS, got {event_type!r}",
        file=sys.stderr
    )
    sys.exit(1)

# Check all required fields are present (depth-agnostic: unknown extras silently pass)
missing = [f for f in required_fields if f not in data]
if missing:
    print(
        f"[DSO PRECONDITIONS] validation error: missing required minimal-tier fields: {', '.join(missing)}",
        file=sys.stderr
    )
    sys.exit(1)

# Validation passed — unknown extra fields are silently ignored (depth-agnostic)
sys.exit(0)
PYEOF
}

# _dso_pv_read_latest_by_gate ticket_id gate_name
# Session-agnostic reader: finds the lexicographically latest *-PRECONDITIONS.json
# in the ticket dir matching gate_name, ignoring session_id (cross-stage reads
# may cross session boundaries). Prints JSON content to stdout; exits 0 on success,
# exits 1 if no matching event found.
#
# Test injection: define _dso_pv_read_latest_by_gate AFTER sourcing this lib to
# override the production scanner with a fixture provider.
_dso_pv_read_latest_by_gate() {
    local ticket_id="$1"
    local gate_name="$2"

    # Production path: scan ticket dir directly for matching gate_name (session-agnostic)
    # TICKETS_TRACKER_DIR env var overrides tracker location (used in tests and CI)
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
    local tracker_dir_raw="${TICKETS_TRACKER_DIR:-${repo_root}/.tickets-tracker}"

    python3 - "$tracker_dir_raw" "$ticket_id" "$gate_name" <<'PYEOF'
import json, os, sys

try:
    tracker_dir = os.path.realpath(sys.argv[1])
except OSError:
    tracker_dir = sys.argv[1]

ticket_id = sys.argv[2]
gate_name = sys.argv[3]
ticket_dir = os.path.join(tracker_dir, ticket_id)

if not os.path.isdir(ticket_dir):
    sys.exit(1)

candidates = []
try:
    entries = os.listdir(ticket_dir)
except OSError:
    sys.exit(1)

for fname in entries:
    if not fname.endswith("-PRECONDITIONS.json"):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        continue
    if data.get("gate_name") == gate_name:
        candidates.append((fname, fpath, data))

if not candidates:
    sys.exit(1)

candidates.sort(key=lambda x: x[0])
_, latest_path, _ = candidates[-1]

with open(latest_path, encoding="utf-8") as f:
    print(f.read(), end="")

sys.exit(0)
PYEOF
}

# _dso_pv_entry_check stage_name upstream_stage_name ticket_id
# Reads the latest PRECONDITIONS event for upstream_stage_name and validates it.
# On success (valid event found): returns exit 0.
# On missing event: emits diagnostic to stderr, returns exit 1.
# On schema-invalid event: emits diagnostic to stderr, returns exit 1.
# Depth-agnostic: unknown extra fields in the event are silently ignored.
_dso_pv_entry_check() {
    local stage_name="${1:-}"
    local upstream_stage_name="${2:-}"
    local ticket_id="${3:-}"

    if [[ -z "$upstream_stage_name" ]]; then
        printf "[DSO PRECONDITIONS] entry_check(%s): upstream_stage_name is required\n" \
            "$stage_name" >&2
        return 1
    fi

    # Read the latest upstream PRECONDITIONS event (session-agnostic)
    local event_json=""
    event_json=$(_dso_pv_read_latest_by_gate "$ticket_id" "$upstream_stage_name" 2>/dev/null) || true

    if [[ -z "$event_json" ]]; then
        printf "[DSO PRECONDITIONS] entry_check(%s): no upstream PRECONDITIONS event found for ticket=%s stage=%s\n" \
            "$stage_name" "$ticket_id" "$upstream_stage_name" >&2
        return 1
    fi

    # Validate minimal-tier fields (depth-agnostic)
    if ! _dso_pv_validate_minimal_fields "$event_json"; then
        printf "[DSO PRECONDITIONS] entry_check(%s): upstream PRECONDITIONS event failed validation (ticket=%s stage=%s)\n" \
            "$stage_name" "$ticket_id" "$upstream_stage_name" >&2
        return 1
    fi

    return 0
}

# _dso_pv_exit_write stage_name upstream_event_id spec_hash ticket_id
# Writes a new PRECONDITIONS event for stage_name with cross-stage chain linking.
# Sets upstream_event_id field in the emitted event.
# Runs schema-roundtrip self-check after writing.
# Returns exit 0 on success, exit 1 if write or roundtrip fails.
_dso_pv_exit_write() {
    local stage_name="${1:-}"
    local upstream_event_id="${2:-}"
    local spec_hash="${3:-}"
    local ticket_id="${4:-}"

    if [[ -z "$ticket_id" ]]; then
        printf "[DSO PRECONDITIONS] exit_write(%s): ticket_id is required\n" \
            "$stage_name" >&2
        return 1
    fi

    # Determine the tracker directory
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
    local tracker_dir_raw="${TICKETS_TRACKER_DIR:-${repo_root}/.tickets-tracker}"

    # Write the event using a simple Python writer (avoids git commit overhead in tests)
    # — falls back to _write_preconditions if available (full commit path)
    local out_file=""
    out_file=$(_dso_pv_write_preconditions_event \
        "$tracker_dir_raw" "$ticket_id" "$stage_name" "$upstream_event_id" "$spec_hash") || {
        printf "[DSO PRECONDITIONS] exit_write(%s): failed to write PRECONDITIONS event for ticket=%s\n" \
            "$stage_name" "$ticket_id" >&2
        return 1
    }

    if [[ -z "$out_file" || ! -f "$out_file" ]]; then
        printf "[DSO PRECONDITIONS] exit_write(%s): PRECONDITIONS file not found after write for ticket=%s\n" \
            "$stage_name" "$ticket_id" >&2
        return 1
    fi

    # Schema roundtrip self-check: re-read and validate the written event
    local written_json=""
    written_json=$(cat "$out_file" 2>/dev/null) || {
        printf "[DSO PRECONDITIONS] exit_write(%s): could not read written file for roundtrip check\n" \
            "$stage_name" >&2
        return 1
    }

    if ! _dso_pv_validate_minimal_fields "$written_json"; then
        printf "[DSO PRECONDITIONS] exit_write(%s): roundtrip schema validation failed for ticket=%s\n" \
            "$stage_name" "$ticket_id" >&2
        return 1
    fi

    return 0
}

# _dso_pv_write_preconditions_event tracker_dir ticket_id stage_name upstream_event_id spec_hash
# Internal helper: writes a PRECONDITIONS event JSON file to <tracker_dir>/<ticket_id>/
# without requiring the full git commit path (supports test isolation via TICKETS_TRACKER_DIR).
# Prints the path of the written file to stdout.
_dso_pv_write_preconditions_event() {
    local tracker_dir_raw="$1"
    local ticket_id="$2"
    local stage_name="$3"
    local upstream_event_id="$4"
    local spec_hash="$5"

    python3 - "$tracker_dir_raw" "$ticket_id" "$stage_name" "$upstream_event_id" "$spec_hash" <<'PYEOF'
import json, os, sys, time, uuid

tracker_dir_raw = sys.argv[1]
ticket_id       = sys.argv[2]
stage_name      = sys.argv[3]
upstream_event_id = sys.argv[4]
spec_hash       = sys.argv[5]

# Resolve tracker dir
try:
    tracker_dir = os.path.realpath(tracker_dir_raw)
except OSError:
    tracker_dir = tracker_dir_raw

ticket_dir = os.path.join(tracker_dir, ticket_id)

# Ensure ticket dir exists
try:
    os.makedirs(ticket_dir, exist_ok=True)
except OSError as e:
    print(f"[DSO PRECONDITIONS] could not create ticket dir {ticket_dir}: {e}", file=sys.stderr)
    sys.exit(1)

# Generate filename
timestamp_ms = int(time.time() * 1000)
file_uuid = str(uuid.uuid4())
filename = f"{timestamp_ms}-{file_uuid}-PRECONDITIONS.json"
out_path = os.path.join(ticket_dir, filename)

# Build event payload (minimal tier, depth-agnostic forward-compat)
payload = {
    "event_type": "PRECONDITIONS",
    "schema_version": 1,
    "manifest_depth": "minimal",
    "gate_name": f"{stage_name}_complete",
    "session_id": os.environ.get("DSO_SESSION_ID", f"pv-session-{timestamp_ms}"),
    "worktree_id": os.environ.get("DSO_WORKTREE_ID", "unknown"),
    "tier": "minimal",
    "timestamp": timestamp_ms,
    "spec_hash": spec_hash,
    "gate_verdicts": [],
    "workflow_completion_checklist": [],
    "completeness": "complete",
    "data": {},
}

# Set upstream_event_id for cross-stage chain linking (SC11)
if upstream_event_id:
    payload["upstream_event_id"] = upstream_event_id

try:
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
except OSError as e:
    print(f"[DSO PRECONDITIONS] write failed: {e}", file=sys.stderr)
    sys.exit(1)

# Print path to stdout so caller can reference it
print(out_path, end="")
PYEOF
}
