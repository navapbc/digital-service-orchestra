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

# _defense_compute_fingerprint content path lineno [pr_number]
# Returns 64-char hex SHA-256.
# When pr_number is non-empty and non-zero, incorporates it into the hash:
#   "pr_number:path:lineno:<whitespace-collapsed content>"
# When pr_number is 0 or absent (sentinel / legacy path), uses legacy format:
#   "path:lineno:<whitespace-collapsed content>"
_defense_compute_fingerprint() {
    local content="$1" path="$2" lineno="$3" pr_number="${4:-0}"
    local collapsed
    collapsed=$(printf '%s' "$content" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')
    if [[ -n "$pr_number" && "$pr_number" != "0" ]]; then
        printf '%s:%s:%s:%s' "$pr_number" "$path" "$lineno" "$collapsed" | $_DSO_HASH_CMD | cut -c1-64
    else
        printf '%s:%s:%s' "$path" "$lineno" "$collapsed" | $_DSO_HASH_CMD | cut -c1-64
    fi
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
# defense_store_write [--pr-number <int>] defense_json
# Validate and persist a defense record as a ticket comment.
#
# Flag disambiguation:
#   --pr-number  (key-shape flag) — the PR number for (pr_number, commit_sha)
#                tuple keying. Used by defense_store_list_by_pr for filtering.
#                Sentinel value 0 means "match any pr_number" (legacy records
#                and records written without --pr-number use sentinel=0).
#   --pr         (file-list filter flag on defense_store_list) — unrelated flag
#                used by defense_store_list to scope to a PR's changed-file set.
#                Both --pr and --pr-number coexist without collision.
# ---------------------------------------------------------------------------
defense_store_write() {
  # Parse --pr-number flag (key-shape); default to sentinel 0 for backward compat
  local _write_pr_number=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr-number)
        _write_pr_number="${2:-0}"
        shift 2
        ;;
      --pr-number=*)
        _write_pr_number="${1#--pr-number=}"
        shift
        ;;
      *)
        break
        ;;
    esac
  done

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
    # Incorporate pr_number into fingerprint when non-sentinel (preserves legacy hash for pr_number=0)
    fingerprint=$(_defense_compute_fingerprint "$fp_content" "$fp_path" "$fp_lineno" "$_write_pr_number")
    enriched_json=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
# Remove temp fields
d.pop('_fp_path', None)
d.pop('_fp_lineno', None)
d.pop('_fp_content', None)
d['cited_lines_fingerprint'] = sys.argv[2]
d['pr_number'] = int(sys.argv[3])
print(json.dumps(d))
" "$enriched_json" "$fingerprint" "$_write_pr_number" 2>/dev/null) || enriched_json="$defense_json"
  else
    # Strip temp fields if present but no path found; embed pr_number
    enriched_json=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d.pop('_fp_path', None)
d.pop('_fp_lineno', None)
d.pop('_fp_content', None)
d['pr_number'] = int(sys.argv[2])
print(json.dumps(d))
" "$enriched_json" "$_write_pr_number" 2>/dev/null) || enriched_json="$defense_json"
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
  # Pass ticket_json as argv[2] so the Python -c program can access it via
  # sys.argv without consuming stdin (which python3 -c does not use for source).
  # The heredoc approach (python3 - <<PYEOF) cannot be used here because the
  # heredoc provides the program source via stdin, leaving sys.stdin empty at
  # runtime — meaning sys.stdin.read() would return an empty string and
  # json.loads would fail on every ticket.  Using python3 -c with sys.argv[2]
  # mirrors the pattern already established in defense_store_load_for_region.
  result=$(python3 -c "
import json, sys

finding_id = sys.argv[1]
ticket_raw = sys.argv[2]

try:
    ticket = json.loads(ticket_raw)
except json.JSONDecodeError:
    print('null')
    sys.exit(0)

# Comments may be under 'comments' key as a list of strings or dicts
comments = ticket.get('comments', [])
for comment in comments:
    # Comment may be a string or a dict with a 'body'/'text' field
    if isinstance(comment, str):
        text = comment
    elif isinstance(comment, dict):
        text = comment.get('body') or comment.get('text') or comment.get('content') or ''
    else:
        continue

    if not text.startswith('DEFENSE_RECORD: '):
        continue

    record_json = text[len('DEFENSE_RECORD: '):]
    try:
        record = json.loads(record_json)
    except json.JSONDecodeError:
        continue

    # Forward-compat: defense_type is treated as an opaque string.
    # Unknown/future values are passed through without validation so that
    # records written by a newer agent version remain readable by this one.
    if not finding_id or record.get('prior_finding_id') == finding_id:
        print(json.dumps(record))
        sys.exit(0)

print('null')
" "$finding_id" "$ticket_json") || true

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

      if [[ -z "$tip_sha" || -z "$base_sha" ]]; then
        # tip/base fields present but empty — malformed record; fail-closed
        echo "WARNING: defense_store_load_for_region: sha fields present but empty (malformed record), excluding fail-closed" >&2
        continue
      fi
      if [[ -z "$effective_query_sha" ]]; then
        # No query SHA to check against — cannot validate, fail-closed
        echo "WARNING: defense_store_load_for_region: no effective_query_sha to check ancestry, excluding fail-closed" >&2
        continue
      fi

      # TRUST MODEL — SHA resolution failure policy
      #
      # This function enforces an asymmetric fail-closed policy for SHA validation:
      #
      # • query_sha (caller-supplied input): unresolvable → EXCLUDE (fail-closed).
      #   The caller controls this value; an unknown SHA means the caller's context
      #   is not in this repo — we cannot validate ancestry, so we exclude the record.
      #
      # • tip_sha / base_sha (STORED data from the defense record): unresolvable →
      #   ALSO EXCLUDE (fail-closed). Although these come from the store rather than
      #   the caller, an unresolvable stored SHA indicates a foreign-repo or corrupt
      #   record. Allowing it to pass through would let foreign records suppress
      #   findings — a trust-boundary violation.
      #
      # • Ancestry check unexpected failure (git merge-base exit > 1): EXCLUDE
      #   (fail-closed) for the same reason — we cannot make a safe inclusion decision.
      #
      # • LEGACY records (without tip/base fields): the only FAIL-OPEN case, and only
      #   via diff_hash equality. This preserves backward compatibility with records
      #   written before the SHA-range feature was introduced.
      #
      # Reference: SC6 of epic f61f-7e0a-36d3-4e7d and PR #98 cycle-2 finding 8.
      #
      # Verify that effective_query_sha exists in this repo.
      # If it is an unknown object (exit 128 from git cat-file), the query SHA
      # is foreign to this repo — exclude the record rather than fail-open.
      # This is distinct from tip_sha/base_sha being unresolvable (corrupt store).
      local ec_query_resolve
      git cat-file -t "$effective_query_sha" >/dev/null 2>&1 && ec_query_resolve=0 || ec_query_resolve=$?
      if [[ "$ec_query_resolve" -ne 0 ]]; then
        # query_sha is not a known object in this repo — record is not reachable; exclude
        continue
      fi

      # Verify that tip_sha and base_sha are resolvable; if not, fail-open (store may be corrupt).
      local ec_tip_resolve ec_base_resolve
      git cat-file -t "$tip_sha" >/dev/null 2>&1 && ec_tip_resolve=0 || ec_tip_resolve=$?
      git cat-file -t "$base_sha" >/dev/null 2>&1 && ec_base_resolve=0 || ec_base_resolve=$?
      if [[ "$ec_tip_resolve" -ne 0 || "$ec_base_resolve" -ne 0 ]]; then
        echo "WARNING: defense_store_load_for_region: stored sha not resolvable (corrupt store?), excluding record fail-closed" >&2
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
        # git merge-base command failed unexpectedly: fail-closed
        echo "WARNING: defense_store_load_for_region: git ancestry check failed unexpectedly, excluding record fail-closed" >&2
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

# ---------------------------------------------------------------------------
# defense_store_list_by_pr <pr_number>
#
# Read all DEFENSE_RECORD ticket comments from the current DSO_SESSION_TICKET_ID
# and return those that match the given pr_number using sentinel semantics:
#
#   record.pr_number == <pr_number>   → include (exact keyed match)
#   record.pr_number == 0             → include (sentinel: matches ANY pr_number)
#   record has no pr_number field     → include (legacy: treated as sentinel=0)
#   record.pr_number is another value → exclude (belongs to a different PR)
#
# Output: newline-delimited JSON records (one per line), filtered per above.
#
# Flag disambiguation:
#   This function uses the pr_number argument for key-shape filtering.
#   The separate --pr flag on defense_store_list is for file-list filtering
#   against PR changed-files. Both flags coexist without collision.
#
# Usage: defense_store_list_by_pr <pr_number>
# Requires: DSO_SESSION_TICKET_ID to be set.
# ---------------------------------------------------------------------------
defense_store_list_by_pr() {
  local query_pr_number="${1:-}"

  if [[ -z "$query_pr_number" ]]; then
    echo "defense_store_list_by_pr: pr_number argument is required" >&2
    return 2
  fi

  _defense_store_require_ticket_binding || return 1

  local ticket_json
  ticket_json=$($_TICKET_CMD show "$DSO_SESSION_TICKET_ID" 2>/dev/null) || true

  if [[ -z "$ticket_json" ]]; then
    return 0
  fi

  python3 -c "
import json, sys

query_pr = int(sys.argv[1])
ticket_raw = sys.argv[2]

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

    # Sentinel semantics: pr_number=0 or absent matches any query_pr.
    record_pr = record.get('pr_number', 0)
    if record_pr == query_pr or record_pr == 0:
        print(json.dumps(record))
" "$query_pr_number" "$ticket_json" || true
}

# ---------------------------------------------------------------------------
# defense_store_list --pr <pr_number> [--ref <git-ref>] [--all-no-pr-filter]
#
# Emits the subset of DEFENSE_RECORD lines stored on the tickets orphan branch
# that are RELEVANT to the given PR — meaning at least one path cited by the
# record matches a file in the PR's diff. Output format matches what
# mirror-defenses-to-pr.sh consumes:
#
#     DEFENSE_RECORD: {"defense_text": "...", ...}
#
# Path normalization: cited paths from prior sessions are stored as absolute
# paths (e.g. HOME/<repo>-worktrees/worktree-*/... or HOME/<repo>/...). The
# normalizer strips everything up to and including the repo root so the
# result is repo-relative (e.g. <plugin-dir>/scripts/foo.sh). Filtering then
# intersects with the PR changed-files set.
#
# Arguments:
#   --pr <pr_number>     REQUIRED. PR number used to fetch the changed-file
#                        set. Defenses whose normalized paths don't intersect
#                        that set are skipped — prevents cross-PR pollution.
#   --ref <git-ref>      Override the git ref to read from (default: tickets,
#                        or origin/tickets if tickets is not present locally).
#   --all-no-pr-filter   Emit ALL defenses without PR filtering. Manual-debug
#                        escape hatch — never use this in CI.
#
# Exit codes:
#   0 — success (zero or more records emitted)
#   1 — git ref unavailable (no tickets branch reachable)
#   2 — argument error (e.g., --pr missing without --all-no-pr-filter)
#   3 — PR file fetch failed (fail-safe: emits zero records)
# ---------------------------------------------------------------------------
defense_store_list() {
  local pr_number=""
  local git_ref=""
  local all_no_pr_filter=0
  local head_sha=""
  local base_sha=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pr)
        if [[ $# -lt 2 ]]; then
          echo "review-defense-store.sh list: --pr requires a value" >&2
          return 2
        fi
        pr_number="$2"
        shift 2
        ;;
      --ref)
        if [[ $# -lt 2 ]]; then
          echo "review-defense-store.sh list: --ref requires a value" >&2
          return 2
        fi
        git_ref="$2"
        shift 2
        ;;
      --head-sha)
        # ADR/diff-hunk scoping: the PR head SHA. With --base-sha, the mirror
        # scopes defenses to lines THIS PR actually changed (±5 proximity), not
        # merely files it touches — bounding cross-PR/over-time accumulation.
        head_sha="${2:-}"
        shift 2
        ;;
      --base-sha)
        base_sha="${2:-}"
        shift 2
        ;;
      --all-no-pr-filter)
        all_no_pr_filter=1
        shift
        ;;
      *)
        # Ignore unknown args silently — keep the CLI forgiving so a future
        # caller adding a new flag does not regress mirror-to-pr in CI.
        shift
        ;;
    esac
  done

  # PR scoping is mandatory in CI to avoid cross-PR comment pollution.
  if [[ -z "$pr_number" && "$all_no_pr_filter" -ne 1 ]]; then
    echo "review-defense-store.sh list: --pr <pr_number> is required (or --all-no-pr-filter for manual debugging)" >&2
    return 2
  fi

  # Build the PR changed-files set into a temp file (one path per line).
  # Fail-safe: if the fetch fails, emit zero records and exit 3 so the CI
  # mirror step is a no-op rather than dumping every defense in the repo.
  local pr_files_file=""
  # Cleanup helper — called on every return path so the mktemp never leaks.
  _defense_list_cleanup() {
    [[ -n "${pr_files_file:-}" ]] && rm -f "$pr_files_file"
  }
  if [[ -n "$pr_number" ]]; then
    pr_files_file=$(mktemp /tmp/defense-pr-files.XXXXXX)
    if ! gh pr view "$pr_number" --json files -q '.files[].path' > "$pr_files_file" 2>/dev/null; then
      echo "review-defense-store.sh list: failed to fetch PR #${pr_number} file list — emitting zero records" >&2
      _defense_list_cleanup
      return 3
    fi
    # Empty file list (e.g. PR with no diff) → no defenses can match.
    if ! [[ -s "$pr_files_file" ]]; then
      _defense_list_cleanup
      return 0
    fi
  fi

  # Resolve git ref. Try local 'tickets' first, then 'origin/tickets'.
  if [[ -z "$git_ref" ]]; then
    if git rev-parse --verify --quiet 'tickets' >/dev/null 2>&1; then
      git_ref='tickets'
    elif git rev-parse --verify --quiet 'origin/tickets' >/dev/null 2>&1; then
      git_ref='origin/tickets'
    else
      echo "defense_store_list: no 'tickets' or 'origin/tickets' ref available" >&2
      _defense_list_cleanup
      return 1
    fi
  fi

  # List every *-COMMENT.json blob on the tickets ref, read it, and emit any
  # data.body line that starts with "DEFENSE_RECORD: ".
  # Read via git ls-tree from the orphan ref so we never touch the worktree
  # tracker dir — keeps the bash pre-hook tracker guard out of this path.
  local comment_files
  comment_files=$(git ls-tree -r --name-only "$git_ref" 2>/dev/null | grep -E '/[0-9]+-[a-f0-9-]+-COMMENT\.json$' || true)

  if [[ -z "$comment_files" ]]; then
    _defense_list_cleanup
    return 0
  fi

  # Stream each blob through python to extract data.body and filter by prefix.
  # Pass file list via stdin to a python script body kept in a heredoc-fed
  # variable (so we can avoid `python3 - <<EOF` which would consume stdin for
  # the program source itself).
  local py_program
  # shellcheck disable=SC2016  # Python source intentionally not expanded by bash.
  py_program='
import json
import re
import subprocess
import sys

ref = sys.argv[1]
pr_files_path = sys.argv[2] if len(sys.argv) > 2 else ""
head_sha = sys.argv[3] if len(sys.argv) > 3 else ""
base_sha = sys.argv[4] if len(sys.argv) > 4 else ""
prefix = "DEFENSE_RECORD: "
PROX = 5  # line proximity, matching runner.py suppression (compute_proximity_overlap)


def build_diff_map(base, head):
    # {normalized_path -> set(changed line numbers)} from the PR net diff
    # (base...head, 3-dot = merge-base..head = the PR changed lines). Returns
    # None if the diff cannot be computed (caller falls back to file-overlap).
    if not base or not head:
        return None
    try:
        res = subprocess.run(
            ["git", "diff", "{}...{}".format(base, head), "--unified=0"],
            capture_output=True, text=True, check=False, timeout=120,
        )
    except Exception:
        return None
    if res.returncode != 0:
        return None
    m = {}
    cur = None
    for ln in res.stdout.splitlines():
        if ln.startswith("+++ b/"):
            cur = ln[6:].strip()
            m.setdefault(cur, set())
        elif ln.startswith("+++ "):
            cur = None  # +++ /dev/null (deletion) -> no new lines
        elif ln.startswith("@@") and cur is not None:
            mm = re.search(r"\+(\d+)(?:,(\d+))?", ln)
            if mm:
                start = int(mm.group(1))
                cnt = int(mm.group(2)) if mm.group(2) is not None else 1
                for k in range(start, start + (cnt if cnt > 0 else 1)):
                    m[cur].add(k)
    return m


diff_map = build_diff_map(base_sha, head_sha)

# Build the PR file set. Empty path string ⇒ no filter (escape hatch).
pr_files = set()
if pr_files_path:
    try:
        with open(pr_files_path, "r") as fh:
            for p in fh:
                p = p.strip()
                if p:
                    pr_files.add(p)
    except OSError:
        pass


def normalize_path(p):
    """Strip session/worktree absolute prefixes; return repo-relative path.

    Examples (HOME stands in for any absolute prefix; REPO is the project dir
    name; DIR is any in-repo subpath):
      HOME/REPO-worktrees/worktree-20260507-150815/DIR/foo.sh -> DIR/foo.sh
      HOME/REPO/DIR/foo.sh                                    -> DIR/foo.sh
      DIR/foo.sh                                              -> DIR/foo.sh
    """
    # Strip everything up through digital-service-orchestra(-worktrees/worktree-*)?/
    m = re.search(r"/digital-service-orchestra(?:-worktrees/worktree-[^/]+)?/(.+)$", p)
    if m:
        return m.group(1)
    return p


def _file_overlap(rec, pr_files):
    # Legacy file-LEVEL overlap (used as the fallback when no diff map is
    # available, or for records that cite no line numbers). Returns bool.
    if not pr_files:
        return True  # No filter requested — emit all.
    for cited in rec.get("cited_lines", []) or []:
        if isinstance(cited, str) and normalize_path(cited.split(":", 1)[0]) in pr_files:
            return True
    for fp in rec.get("file_paths", []) or []:
        if isinstance(fp, str) and normalize_path(fp) in pr_files:
            return True
    return False


def record_matches_pr(record_json, pr_files, diff_map):
    # Returns (kind, matched): kind in {"line","file"} for the summary.
    if not pr_files and diff_map is None:
        return ("file", True)  # No filter requested — emit all.
    try:
        rec = json.loads(record_json[len(prefix):])
    except (json.JSONDecodeError, ValueError):
        return ("file", False)
    cited = rec.get("cited_lines") or []
    # Preferred: LINE-level proximity scoping against the PR net diff. A defense
    # is mirrored only when one of its cited lines is within ±PROX of a line THIS
    # PR actually changed (the same axis runner.py suppression matches on). This
    # bounds cross-PR / over-time accumulation that file-overlap let through.
    if diff_map is not None and cited:
        for c in cited:
            if not isinstance(c, str):
                continue
            parts = c.split(":", 2)  # path:lineno:content (content may hold colons)
            if len(parts) < 2:
                continue
            cp = normalize_path(parts[0])
            try:
                lno = int(parts[1])
            except (ValueError, TypeError):
                continue  # malformed / range -> not a line match
            changed = diff_map.get(cp)
            if changed and any(abs(lno - m) <= PROX for m in changed):
                return ("line", True)
        return ("line", False)
    # Fallback: file-overlap (diff unavailable, or record cites no line numbers).
    return ("file", _file_overlap(rec, pr_files))


if diff_map is None and (head_sha or base_sha):
    sys.stderr.write(
        "::warning::defense-mirror: could not compute PR diff for line-scoping "
        "(head/base unreachable?) — falling back to file-overlap\n"
    )

_candidates = 0
_emitted = 0
_line_seen = 0
_file_seen = 0

for line in sys.stdin:
    path = line.strip()
    if not path:
        continue
    try:
        blob = subprocess.run(
            ["git", "show", "{}:{}".format(ref, path)],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
    except subprocess.TimeoutExpired:
        print("WARN: git show timed out for {}; record skipped".format(path), file=sys.stderr)
        continue
    if blob.returncode != 0 or not blob.stdout:
        continue
    try:
        event = json.loads(blob.stdout)
    except (json.JSONDecodeError, ValueError):
        continue
    # Defensive: event["data"] is expected to be a dict, but guard against
    # malformed comment blobs where it may be a non-dict truthy value
    # (int / str / list) — `.get()` would raise AttributeError otherwise.
    data_field = event.get("data")
    if not isinstance(data_field, dict):
        continue
    body = data_field.get("body") or ""
    if not isinstance(body, str):
        continue
    # body may contain newlines from multi-line defenses; only the first line
    # carries the prefix marker, and mirror-defenses-to-pr.sh reads line-by-line.
    first_line = body.split("\n", 1)[0]
    if not first_line.startswith(prefix):
        continue
    _candidates += 1
    kind, matched = record_matches_pr(first_line, pr_files, diff_map)
    if kind == "line":
        _line_seen += 1
    else:
        _file_seen += 1
    if not matched:
        continue
    _emitted += 1
    # Emit just the prefix-line so the mirror-defenses-to-pr.sh
    # `while IFS= read -r line` loop sees a clean record per line.
    print(first_line)

sys.stderr.write(
    "defense-mirror: emitted {} of {} candidate records "
    "(line-scoped={}, file-fallback={}, diff-{})\n".format(
        _emitted, _candidates, _line_seen, _file_seen,
        "ok" if diff_map is not None else "unavailable",
    )
)
'
  printf '%s\n' "$comment_files" | python3 -c "$py_program" "$git_ref" "${pr_files_file:-}" "$head_sha" "$base_sha"
  local _rc=$?

  # Cleanup the PR-files temp file (no-op if --all-no-pr-filter).
  _defense_list_cleanup
  return $_rc
}

# ---------------------------------------------------------------------------
# CLI dispatcher — only runs when this script is executed directly, NOT when
# sourced. The BASH_SOURCE[0] vs $0 check is the canonical guard.
# Subcommands: list (emits DEFENSE_RECORD lines on stdout for mirror-defenses-to-pr.sh).
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _subcmd="${1:-}"
  shift || true
  case "$_subcmd" in
    list)
      defense_store_list "$@"
      exit $?
      ;;
    "" )
      echo "usage: review-defense-store.sh list [--pr <pr_number>] [--ref <git-ref>]" >&2
      exit 2
      ;;
    *)
      echo "review-defense-store.sh: unknown subcommand: $_subcmd" >&2
      echo "usage: review-defense-store.sh list [--pr <pr_number>] [--ref <git-ref>]" >&2
      exit 2
      ;;
  esac
fi
