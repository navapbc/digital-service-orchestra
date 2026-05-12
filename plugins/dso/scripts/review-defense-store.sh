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

  # Validate SHA range fields: both must be present if either is present
  local has_tip_sha has_base_sha
  has_tip_sha=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('1' if 'story_branch_tip_sha' in d else '0')" "$defense_json" 2>/dev/null) || has_tip_sha="0"
  has_base_sha=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('1' if 'story_branch_base_sha' in d else '0')" "$defense_json" 2>/dev/null) || has_base_sha="0"
  if [[ "$has_tip_sha" == "1" && "$has_base_sha" == "0" ]]; then
    echo 'story_branch_base_sha is required when story_branch_tip_sha is present (both sha fields must appear together)' >&2
    return 1
  fi
  if [[ "$has_tip_sha" == "0" && "$has_base_sha" == "1" ]]; then
    echo 'story_branch_base_sha is present but story_branch_tip_sha is missing (both sha fields must appear together)' >&2
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
# defense_store_load_for_region [--query-sha <sha>] [--diff-hash <hash>] region_files...
# Load all defense records whose file paths intersect with region_files.
# When records contain story_branch_tip_sha / story_branch_base_sha fields,
# perform git ancestry-path membership check using --query-sha.
# For legacy records (no sha fields), fall back to diff_hash equality using --diff-hash.
# Outputs newline-delimited JSON records.
# ---------------------------------------------------------------------------
defense_store_load_for_region() {
  local query_sha="" diff_hash_filter=""

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --query-sha)
        query_sha="${2:-}"
        shift 2
        ;;
      --diff-hash)
        diff_hash_filter="${2:-}"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  local region_files=("$@")

  _defense_store_require_ticket_binding || return 1

  local ticket_json
  ticket_json=$($_TICKET_CMD show "$DSO_SESSION_TICKET_ID" 2>/dev/null) || true

  if [[ -z "$ticket_json" ]]; then
    return 0
  fi

  # Resolve query_sha: use DSO_QUERY_SHA env var or git rev-parse HEAD as fallback
  local effective_query_sha="$query_sha"
  if [[ -z "$effective_query_sha" ]]; then
    effective_query_sha="${DSO_QUERY_SHA:-$(git rev-parse HEAD 2>/dev/null || true)}"
  fi

  # Parse the ticket JSON and collect matching defense records.
  # ticket_json is passed as argv[1] (not stdin) because python3 with a heredoc
  # consumes stdin for the program source, leaving sys.stdin empty at runtime.
  local candidate_records
  candidate_records=$(python3 -c "
import json, sys

ticket_raw = sys.argv[1]
region_files = set(sys.argv[2:])

try:
    ticket = json.loads(ticket_raw)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

comments = ticket.get('comments', [])
for comment in comments:
    if isinstance(comment, str):
        text = comment
    elif isinstance(comment, dict):
        text = comment.get('body') or comment.get('text') or comment.get('content') or ''
    else:
        continue

    if not text.startswith('DEFENSE_RECORD: '):
        continue

    record_json_str = text[len('DEFENSE_RECORD: '):]
    try:
        record = json.loads(record_json_str)
    except (json.JSONDecodeError, ValueError):
        continue

    # Filter by path intersection: record's file_paths must overlap region_files
    record_paths = set(record.get('file_paths', []))
    if record_paths & region_files:
        print(json.dumps(record))
" "$ticket_json" "${region_files[@]}") || true

  if [[ -z "$candidate_records" ]]; then
    return 0
  fi

  # Apply SHA-range or legacy filtering per record
  while IFS= read -r record_line; do
    [[ -z "$record_line" ]] && continue

    local has_tip has_base tip_sha base_sha
    has_tip=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('1' if 'story_branch_tip_sha' in d else '0')" "$record_line" 2>/dev/null) || has_tip="0"
    has_base=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('1' if 'story_branch_base_sha' in d else '0')" "$record_line" 2>/dev/null) || has_base="0"

    if [[ "$has_tip" == "1" && "$has_base" == "1" ]]; then
      # SHA-range record: check git ancestry membership
      tip_sha=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('story_branch_tip_sha',''))" "$record_line" 2>/dev/null) || tip_sha=""
      base_sha=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('story_branch_base_sha',''))" "$record_line" 2>/dev/null) || base_sha=""

      if [[ -z "$effective_query_sha" || -z "$tip_sha" || -z "$base_sha" ]]; then
        # Fail-open: cannot check ancestry, include the record
        echo "WARNING: defense_store_load_for_region: cannot check ancestry (missing sha), including record fail-open" >&2
        printf '%s\n' "$record_line"
        continue
      fi

      # Check ancestry using two complementary conditions (OR logic):
      #   Condition A: QUERY_SHA is within the story range BASE..TIP
      #                i.e., BASE is an ancestor of QUERY_SHA AND QUERY_SHA is an ancestor of TIP
      #   Condition B: TIP is an ancestor of QUERY_SHA
      #                i.e., QUERY_SHA comes after TIP (e.g., a merge commit on the session branch)
      #
      # git merge-base --is-ancestor exits 0=true, 1=false, 128=error (bad object / not a repo).
      # Capture exit codes safely without triggering set -e on non-zero exits.
      local ec_tip_anc_query ec_base_anc_query ec_query_anc_tip
      git merge-base --is-ancestor "$tip_sha" "$effective_query_sha" 2>/dev/null && ec_tip_anc_query=0 || ec_tip_anc_query=$?
      git merge-base --is-ancestor "$base_sha" "$effective_query_sha" 2>/dev/null && ec_base_anc_query=0 || ec_base_anc_query=$?
      git merge-base --is-ancestor "$effective_query_sha" "$tip_sha" 2>/dev/null && ec_query_anc_tip=0 || ec_query_anc_tip=$?

      if [[ "$ec_tip_anc_query" -gt 1 || "$ec_base_anc_query" -gt 1 || "$ec_query_anc_tip" -gt 1 ]]; then
        # git merge-base command failed (e.g., bad SHA, not a git repo): fail-open
        echo "WARNING: defense_store_load_for_region: git ancestry check failed, including record fail-open" >&2
        printf '%s\n' "$record_line"
      elif [[ "$ec_tip_anc_query" -eq 0 ]]; then
        # Condition B: TIP is an ancestor of QUERY_SHA — QUERY_SHA comes after TIP (e.g., merge commit)
        printf '%s\n' "$record_line"
      elif [[ "$ec_base_anc_query" -eq 0 && "$ec_query_anc_tip" -eq 0 ]]; then
        # Condition A: QUERY_SHA is within the story range BASE..TIP
        printf '%s\n' "$record_line"
      fi
      # else: QUERY_SHA is not in range and TIP is not its ancestor — exclude (silent)

    else
      # Legacy record: fall back to diff_hash equality check
      local record_diff_hash
      record_diff_hash=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('diff_hash',''))" "$record_line" 2>/dev/null) || record_diff_hash=""
      echo "legacy attestation: falling back to diff_hash equality for $record_line" >&2

      if [[ -n "$diff_hash_filter" && "$record_diff_hash" == "$diff_hash_filter" ]]; then
        printf '%s\n' "$record_line"
      elif [[ -z "$diff_hash_filter" ]]; then
        # No diff_hash filter supplied — include legacy records (backward compat)
        printf '%s\n' "$record_line"
      fi
    fi
  done <<< "$candidate_records"
}
