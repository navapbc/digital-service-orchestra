#!/usr/bin/env bash
# review-defense-store.sh
# Source-able bash library: DefenseStore interface + TrackerDefenseStore backend.
# Usage: source this file; use TICKET_CMD env var to inject a test stub.

set -euo pipefail

# Default ticket CLI — injectable via TICKET_CMD for tests
_TICKET_CMD="${TICKET_CMD:-.claude/scripts/dso ticket}"

# ---------------------------------------------------------------------------
# _defense_store_require_ticket_binding
# Guard: ensures DSO_SESSION_TICKET_ID is set before any store operation.
# Uses return 1 (not exit 1) because this file is sourced, not executed.
# ---------------------------------------------------------------------------
_defense_store_require_ticket_binding() {
  if [[ -z "${DSO_SESSION_TICKET_ID:-}" ]]; then
    echo 'ticket-binding required' >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# defense_store_write defense_json
# Validate and persist a defense record as a ticket comment.
# ---------------------------------------------------------------------------
defense_store_write() {
  local defense_json="$1"

  _defense_store_require_ticket_binding || return 1

  # Validate defense_text length (≤ 4096 Unicode codepoints)
  local defense_text
  defense_text=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('defense_text',''))" "$defense_json" 2>/dev/null) || true
  if [[ ${#defense_text} -gt 4096 ]]; then
    echo 'defense_text exceeds 4096 Unicode codepoints' >&2
    return 1
  fi

  # Validate severity_history present and non-empty
  local severity_history_len
  severity_history_len=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('severity_history',[])))" "$defense_json" 2>/dev/null) || true
  if [[ -z "$severity_history_len" || "$severity_history_len" -eq 0 ]]; then
    echo 'severity_history is required and must not be empty' >&2
    return 1
  fi

  # Post the record as a ticket comment
  $_TICKET_CMD comment "$DSO_SESSION_TICKET_ID" "DEFENSE_RECORD: $defense_json"
}

# ---------------------------------------------------------------------------
# defense_store_load finding_id
# Load the defense record matching a given prior_finding_id.
# Outputs the JSON record, or "null" if not found.
# ---------------------------------------------------------------------------
defense_store_load() {
  local finding_id="${1:-}"

  _defense_store_require_ticket_binding || return 1

  local ticket_json
  ticket_json=$($_TICKET_CMD show "$DSO_SESSION_TICKET_ID" 2>/dev/null) || true

  if [[ -z "$ticket_json" ]]; then
    echo 'null'
    return 0
  fi

  local result
  result=$(python3 - "$finding_id" <<'PYEOF'
import json, sys

finding_id = sys.argv[1]
raw = sys.stdin.read()

try:
    ticket = json.loads(raw)
except json.JSONDecodeError:
    print("null")
    sys.exit(0)

# Comments may be under 'comments' key as a list of strings or dicts
comments = ticket.get("comments", [])
for comment in comments:
    # Comment may be a string or a dict with a 'body'/'text' field
    if isinstance(comment, str):
        text = comment
    elif isinstance(comment, dict):
        text = comment.get("body") or comment.get("text") or comment.get("content") or ""
    else:
        continue

    if not text.startswith("DEFENSE_RECORD: "):
        continue

    record_json = text[len("DEFENSE_RECORD: "):]
    try:
        record = json.loads(record_json)
    except json.JSONDecodeError:
        continue

    if not finding_id or record.get("prior_finding_id") == finding_id:
        print(json.dumps(record))
        sys.exit(0)

print("null")
PYEOF
) || true

  echo "${result:-null}"
}

# ---------------------------------------------------------------------------
# defense_store_load_for_region region_files...
# Load all defense records whose file paths intersect with region_files.
# Outputs newline-delimited JSON records.
# ---------------------------------------------------------------------------
defense_store_load_for_region() {
  local region_files=("$@")

  _defense_store_require_ticket_binding || return 1

  local ticket_json
  ticket_json=$($_TICKET_CMD show "$DSO_SESSION_TICKET_ID" 2>/dev/null) || true

  if [[ -z "$ticket_json" ]]; then
    return 0
  fi

  python3 - "${region_files[@]}" <<'PYEOF'
import json, sys

region_files = set(sys.argv[1:])
raw = sys.stdin.read()

try:
    ticket = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)

comments = ticket.get("comments", [])
for comment in comments:
    if isinstance(comment, str):
        text = comment
    elif isinstance(comment, dict):
        text = comment.get("body") or comment.get("text") or comment.get("content") or ""
    else:
        continue

    if not text.startswith("DEFENSE_RECORD: "):
        continue

    record_json = text[len("DEFENSE_RECORD: "):]
    try:
        record = json.loads(record_json)
    except json.JSONDecodeError:
        continue

    # Filter by path intersection: record's file_paths must overlap region_files
    record_paths = set(record.get("file_paths", []))
    if record_paths & region_files:
        print(json.dumps(record))
PYEOF
}
