#!/usr/bin/env bash
# review-defense-store.sh
# Source-able bash library: DefenseStore interface + TrackerDefenseStore backend.
# Usage: source this file; use TICKET_CMD env var to inject a test stub.

set -euo pipefail

# Default ticket CLI — injectable via TICKET_CMD for tests
_TICKET_CMD="${TICKET_CMD:-.claude/scripts/dso ticket}"

# ---------------------------------------------------------------------------
# sha256sum/shasum portability shim
if command -v sha256sum >/dev/null 2>&1; then
    _DSO_HASH_CMD='sha256sum'
else
    _DSO_HASH_CMD='shasum -a 256'
fi

# _defense_compute_fingerprint content path lineno
# Returns 64-char hex SHA-256 of "path:lineno:<whitespace-collapsed content>"
_defense_compute_fingerprint() {
    local content="$1" path="$2" lineno="$3"
    local collapsed
    collapsed=$(printf '%s' "$content" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')
    printf '%s:%s:%s' "$path" "$lineno" "$collapsed" | $_DSO_HASH_CMD | cut -c1-64
}

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

  # Embed cited_lines_fingerprint when cited_lines entries include content
  local enriched_json
  enriched_json=$(python3 - "$defense_json" <<'PYEOF'
import json, sys

record = json.loads(sys.argv[1])
cited_lines = record.get("cited_lines", [])
if cited_lines:
    first = cited_lines[0]
    # Expected format: "path:lineno:content" — split on first two colons only
    parts = first.split(":", 2)
    if len(parts) == 3:
        record["_fp_path"] = parts[0]
        record["_fp_lineno"] = parts[1]
        record["_fp_content"] = parts[2]
print(json.dumps(record))
PYEOF
) || enriched_json="$defense_json"

  # Compute fingerprint if the parse succeeded and fields were extracted
  local fp_path fp_lineno fp_content fingerprint
  fp_path=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('_fp_path',''))" "$enriched_json" 2>/dev/null) || fp_path=""
  if [[ -n "$fp_path" ]]; then
    fp_lineno=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('_fp_lineno',''))" "$enriched_json" 2>/dev/null) || fp_lineno=""
    fp_content=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('_fp_content',''))" "$enriched_json" 2>/dev/null) || fp_content=""
    fingerprint=$(_defense_compute_fingerprint "$fp_content" "$fp_path" "$fp_lineno")
    enriched_json=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
# Remove temp fields
d.pop('_fp_path', None)
d.pop('_fp_lineno', None)
d.pop('_fp_content', None)
d['cited_lines_fingerprint'] = sys.argv[2]
print(json.dumps(d))
" "$enriched_json" "$fingerprint" 2>/dev/null) || enriched_json="$defense_json"
  else
    # Strip temp fields if present but no path found
    enriched_json=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d.pop('_fp_path', None)
d.pop('_fp_lineno', None)
d.pop('_fp_content', None)
print(json.dumps(d))
" "$enriched_json" 2>/dev/null) || enriched_json="$defense_json"
  fi

  # Post the record as a ticket comment; redirect ticket cmd stdout to suppress noise
  $_TICKET_CMD comment "$DSO_SESSION_TICKET_ID" "DEFENSE_RECORD: $enriched_json" >/dev/null
  # Emit the enriched record to stdout for callers and test inspection
  printf '%s\n' "$enriched_json"
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
