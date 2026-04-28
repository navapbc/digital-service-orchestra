#!/usr/bin/env bash
# sprint-drift-check.sh — Detect codebase drift at sprint entry.
#
# Compares git commit history since task ticket creation against the file
# impact listed in implementation planning. Reports any files that have been
# modified externally since the task was created.
#
# Usage:
#   sprint-drift-check.sh <epic-id> [--repo=<path>]
#
# Environment:
#   TICKET_CMD  — path to ticket CLI (default: <script-dir>/ticket)
#
# Output:
#   NO_DRIFT                           — no files modified since task creation
#   DRIFT_DETECTED: file1,file2,...    — one or more files modified externally
#
# Exit codes:
#   0 — Completed (either NO_DRIFT or DRIFT_DETECTED)
#   1 — Missing arguments
#   2 — Usage error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────

EPIC_ID=""
REPO_PATH=""
STATUS_FILTER=""

for arg in "$@"; do
    case "$arg" in
        --repo=*)
            REPO_PATH="${arg#--repo=}"
            ;;
        --status=*)
            STATUS_FILTER="${arg#--status=}"
            ;;
        --*)
            echo "Unknown option: $arg" >&2
            echo "Usage: $(basename "$0") <epic-id> [--repo=<path>] [--status=<open|in_progress|closed>]" >&2
            exit 2
            ;;
        *)
            if [[ -z "$EPIC_ID" ]]; then
                EPIC_ID="$arg"
            else
                echo "Unexpected argument: $arg" >&2
                echo "Usage: $(basename "$0") <epic-id> [--repo=<path>]" >&2
                exit 2
            fi
            ;;
    esac
done

if [[ -z "$EPIC_ID" ]]; then
    echo "Usage: $(basename "$0") <epic-id> [--repo=<path>] [--status=<open|in_progress|closed>]" >&2
    echo "Error: epic-id is required" >&2
    exit 1
fi

if [[ -n "$STATUS_FILTER" ]]; then
    case "$STATUS_FILTER" in
        open|in_progress|closed) ;;
        *)
            echo "Error: invalid --status value '$STATUS_FILTER'. Must be one of: open, in_progress, closed" >&2
            exit 2
            ;;
    esac
fi

# ── Resolve repo path ─────────────────────────────────────────────────────────

if [[ -z "$REPO_PATH" ]]; then
    REPO_PATH="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -z "$REPO_PATH" ]]; then
        echo "Error: not in a git repository and --repo not specified" >&2
        exit 2
    fi
fi

# ── Resolve ticket CLI ────────────────────────────────────────────────────────

TICKET_CMD="${TICKET_CMD:-${SCRIPT_DIR}/ticket}"

# ── Helper: extract file paths from a ticket description's File Impact section ──
# Supports three formats:
#   1. ## File Impact with bullet-list paths
#   2. Markdown table: | File | Action | Task(s) |
#   3. ## Files to Create / ## Files to Modify with bullet paths
#
# Usage: _extract_impact_files <description>
# Outputs one file path per line.
_extract_impact_files() {
    local desc="$1"
    python3 - "$desc" << 'PYEOF'
import sys
import re

desc = sys.argv[1]
lines = desc.split('\n')

files = []
in_section = False
in_table = False

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()

    # Detect section headings (case-insensitive)
    heading_lower = stripped.lower()

    # Check for ## File Impact
    if re.match(r'^##\s+file\s+impact\s*$', heading_lower):
        in_section = True
        in_table = False
        i += 1
        continue

    # Check for ## Files to Create or ## Files to Modify
    if re.match(r'^##\s+files?\s+to\s+(create|modify)\s*$', heading_lower):
        in_section = True
        in_table = False
        i += 1
        continue

    # Stop at the next heading (##)
    if re.match(r'^##\s+', stripped) and in_section:
        in_section = False
        in_table = False
        i += 1
        continue

    if in_section:
        # Markdown table row: | file | action | ... |
        if stripped.startswith('|') and not re.match(r'^\|[\s\-|]+\|$', stripped):
            # Extract first column (file path)
            cols = [c.strip() for c in stripped.split('|') if c.strip()]
            if cols:
                candidate = cols[0]
                # Skip header row
                if not re.match(r'^file\s*$', candidate.lower()) and not candidate.startswith('-'):
                    # Extract just the path, strip inline code backticks
                    candidate = candidate.strip('`').strip()
                    if candidate and ('/' in candidate or '.' in candidate):
                        files.append(candidate)
            i += 1
            continue

        # Bullet list: - path or * path
        m = re.match(r'^[-*]\s+(.+)', stripped)
        if m:
            path = m.group(1).strip().strip('`').strip()
            # Skip if it looks like a description (spaces in the middle and no /)
            # Only collect if it looks like a file path
            if path and not path.startswith('#'):
                files.append(path)
            i += 1
            continue

        # Skip separator lines and empty lines
        if stripped == '' or re.match(r'^\|[\s\-|]+\|$', stripped):
            i += 1
            continue

        # Any non-empty non-heading non-bullet non-table line in a File Impact
        # section: stop section parsing to avoid capturing prose
        # (only for file_impact sections — files_create_modify sections are
        #  typically just bullets)
        i += 1
        continue

    i += 1

for f in files:
    print(f)
PYEOF
}

# ── Helper: check relates_to drift ───────────────────────────────────────────
# Detects when a related epic (via relates_to link) has closed after the
# implementation plan was created.
#
# Usage: _check_relates_to_drift <epic_id> <children_json>
# Outputs: RELATES_TO_DRIFT: <neighbor-id> <summary> for each neighbor that
#          closed after the impl plan timestamp.
# On CLI failure for a neighbor: warn to stderr, continue.
# On empty relates_to set: exits immediately with no output.
_check_relates_to_drift() {
    local epic_id="$1"
    local children_json_arg="$2"

    # Get epic's raw ticket output.
    # NOTE: The raw output may contain invalid JSON because ticket comment bodies
    # can contain unescaped JSON objects (e.g., PREPLANNING_CONTEXT payloads).
    # All extraction below uses regex-based approaches that tolerate this.
    local epic_raw
    epic_raw=$("$TICKET_CMD" show "$epic_id" 2>/dev/null) || {
        echo "WARNING: _check_relates_to_drift: could not fetch epic $epic_id; skipping relates_to check" >&2
        return 0
    }

    # Extract relates_to neighbor IDs from deps array using regex.
    # The deps array contains simple fields (no free-text) so we can extract
    # it as a substring and parse just that array with json.loads.
    local relates_to_ids
    relates_to_ids=$(python3 - "$epic_raw" << 'PYEOF'
import json, sys, re

raw = sys.argv[1]

# Extract the "deps" array value from the raw text.
# Match "deps": [ ... ] — deps entries are simple objects without nested free-text.
m = re.search(r'"deps"\s*:\s*(\[.*?\])', raw, re.DOTALL)
if not m:
    sys.exit(0)

try:
    deps = json.loads(m.group(1))
    for dep in deps:
        if dep.get('relation') == 'relates_to':
            target = dep.get('target_id', '').strip()
            if target:
                print(target)
except Exception:
    pass
PYEOF
)

    # Guard clause: empty relates_to set — exit immediately
    if [[ -z "$relates_to_ids" ]]; then
        return 0
    fi

    # Determine impl plan timestamp:
    # 1. Preferred: PREPLANNING_CONTEXT comment's generatedAt field.
    #    Use regex search on the raw epic output — avoids full JSON parse failure
    #    caused by unescaped quotes inside comment body strings.
    # 2. Fallback: earliest child created_at from children_json_arg.
    local impl_plan_ts
    impl_plan_ts=$(python3 - "$epic_raw" "$children_json_arg" << 'PYEOF'
import json, sys, re
from datetime import datetime, timezone

epic_raw = sys.argv[1]
children_json = sys.argv[2]

ts = None

# Try PREPLANNING_CONTEXT generatedAt via regex on raw epic output.
# Pattern: PREPLANNING_CONTEXT: { ... "generatedAt": "<iso>" ... }
m = re.search(r'PREPLANNING_CONTEXT:\s*\{[^}]*"generatedAt"\s*:\s*"([^"]+)"', epic_raw)
if m:
    generated_at = m.group(1)
    try:
        dt_str = generated_at.replace('Z', '+00:00')
        try:
            dt = datetime.fromisoformat(dt_str)
        except ValueError:
            dt = datetime.strptime(generated_at, '%Y-%m-%dT%H:%M:%SZ')
            dt = dt.replace(tzinfo=timezone.utc)
        ts = int(dt.timestamp())
    except (ValueError, Exception):
        pass

# Fallback: earliest child created_at
if ts is None:
    try:
        children = json.loads(children_json)
        times = [c.get('created_at', 0) for c in children if c.get('created_at', 0) > 0]
        if times:
            ts = min(times)
    except Exception:
        pass

if ts is not None:
    print(ts)
PYEOF
)

    # If we couldn't determine a timestamp, skip the check
    if [[ -z "$impl_plan_ts" ]]; then
        return 0
    fi

    # Check each relates_to neighbor for closure after impl plan timestamp.
    # Neighbor JSON is simple (no free-text in comment bodies in standard usage),
    # so json.loads works. Regex fallback handles edge cases.
    while IFS= read -r neighbor_id; do
        [[ -z "$neighbor_id" ]] && continue

        local neighbor_raw
        if ! neighbor_raw=$("$TICKET_CMD" show "$neighbor_id" 2>/dev/null); then
            echo "WARNING: _check_relates_to_drift: could not fetch neighbor $neighbor_id; skipping" >&2
            continue
        fi

        python3 - "$neighbor_raw" "$impl_plan_ts" "$neighbor_id" << 'PYEOF'
import json, sys, re

neighbor_raw = sys.argv[1]
impl_plan_ts = int(sys.argv[2])
neighbor_id = sys.argv[3]

# Try full JSON parse; fallback to regex for robustness
try:
    neighbor = json.loads(neighbor_raw)
    status = neighbor.get('status', '')
    closed_at = int(neighbor.get('closed_at', 0) or 0)
    title = neighbor.get('title', '')
except Exception:
    m_status = re.search(r'"status"\s*:\s*"([^"]+)"', neighbor_raw)
    m_closed = re.search(r'"closed_at"\s*:\s*(\d+)', neighbor_raw)
    m_title = re.search(r'"title"\s*:\s*"([^"]*)"', neighbor_raw)
    status = m_status.group(1) if m_status else ''
    closed_at = int(m_closed.group(1)) if m_closed else 0
    title = m_title.group(1) if m_title else ''

if status != 'closed':
    sys.exit(0)
if not closed_at:
    sys.exit(0)
if closed_at > impl_plan_ts:
    print('RELATES_TO_DRIFT: {} \u2014 related epic closed after impl plan (closed_at={}, impl_plan_ts={}, title={})'.format(
        neighbor_id, closed_at, impl_plan_ts, title
    ))
PYEOF

    done <<< "$relates_to_ids"
}

# ── Main logic ────────────────────────────────────────────────────────────────

# List children of the epic
children_json="$("$TICKET_CMD" list --parent="$EPIC_ID" 2>/dev/null || echo "[]")"

# Filter children by status if --status was provided
if [[ -n "$STATUS_FILTER" ]]; then
    children_json=$(python3 -c "
import json, sys
children = json.loads(sys.argv[1])
status_filter = sys.argv[2]
filtered = [c for c in children if c.get('status') == status_filter]
print(json.dumps(filtered))
" "$children_json" "$STATUS_FILTER")
fi

# Check if children list is empty
child_count=$(python3 -c "
import json, sys
try:
    children = json.loads(sys.argv[1])
    print(len(children))
except Exception:
    print(0)
" "$children_json")

if [[ "$child_count" -eq 0 ]]; then
    echo "NO_DRIFT"
    exit 0
fi

# Collect drifted files across all child tasks.
# Extract created_at and description directly from the children list JSON to
# avoid individual show calls (which may fail in some mock environments).
drifted_files=()

# Write description files to a temp dir so bash can read them without
# worrying about escaping or heredoc issues.
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir"' EXIT

# Extract (index, created_at, ticket_id) pairs and write description files.
python3 - "$children_json" "$_tmpdir" << 'PYEOF'
import json, sys, os

children_json = sys.argv[1]
tmpdir = sys.argv[2]

try:
    children = json.loads(children_json)
except Exception:
    children = []

for i, child in enumerate(children):
    created_at = child.get('created_at', 0)
    description = child.get('description', '')
    ticket_id = child.get('ticket_id', '')
    desc_file = os.path.join(tmpdir, 'desc_{}.txt'.format(i))
    with open(desc_file, 'w') as f:
        f.write(description)
    # Write ticket_id to a separate file for the bash loop
    tid_file = os.path.join(tmpdir, 'tid_{}.txt'.format(i))
    with open(tid_file, 'w') as f:
        f.write(ticket_id)
    # Print index TAB created_at for bash loop to read
    print('{}\t{}'.format(i, created_at))
PYEOF

# Read (index, created_at) pairs from the temp index file produced above.
# The python3 heredoc above wrote pairs to stdout but we captured them —
# re-run to get them (cheap, no I/O cost since tmpdir is already populated).
while IFS=$'\t' read -r _idx _created_at; do
    [[ -z "$_idx" ]] && continue

    _desc_file="$_tmpdir/desc_${_idx}.txt"
    [[ ! -f "$_desc_file" ]] && continue

    _description=$(cat "$_desc_file")

    # Skip if no timestamp
    if [[ -z "$_created_at" || "$_created_at" == "0" ]]; then
        continue
    fi

    # Read ticket_id for this child (written by the python3 extraction block above)
    _tid_file="$_tmpdir/tid_${_idx}.txt"
    _task_id=""
    [[ -f "$_tid_file" ]] && _task_id=$(cat "$_tid_file")

    # Primary: try ticket get-file-impact for structured file paths
    _impact_files=""
    if [[ -n "$_task_id" ]]; then
        _fi_json=$(${TICKET_CMD:-ticket} get-file-impact "$_task_id" 2>/dev/null || echo "[]")
        if [ -n "$_fi_json" ] && [ "$_fi_json" != "[]" ]; then
            _fi_paths=$(echo "$_fi_json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for e in d:
        p = e.get("path") or e.get("file") or ""
        if p:
            print(p)
except Exception:
    pass
' 2>/dev/null || true)
            if [ -n "$_fi_paths" ]; then
                _impact_files="$_fi_paths"
            fi
        fi
    fi

    # Fallback: extract file paths from the markdown description
    if [[ -z "$_impact_files" ]]; then
        _impact_files=$(_extract_impact_files "$_description")
    fi

    # Skip tasks with no file impact
    [[ -z "$_impact_files" ]] && continue

    # For each file in the impact list, check if it was modified after task creation
    while IFS= read -r _impact_file; do
        [[ -z "$_impact_file" ]] && continue

        # Use git log --since=@<epoch> with @ prefix for Unix timestamps
        _git_output=$(git -C "$REPO_PATH" log \
            --since="@${_created_at}" \
            --name-only \
            --format="" \
            -- "$_impact_file" 2>/dev/null || true)

        if [[ -n "$_git_output" ]]; then
            drifted_files+=("$_impact_file")
        fi
    done <<< "$_impact_files"

done < <(python3 - "$children_json" << 'PYEOF2'
import json, sys

children_json = sys.argv[1]
try:
    children = json.loads(children_json)
except Exception:
    children = []

for i, child in enumerate(children):
    created_at = child.get('created_at', 0)
    print('{}\t{}'.format(i, created_at))
PYEOF2
)

# Deduplicate drifted files
if [[ "${#drifted_files[@]}" -eq 0 ]]; then
    echo "NO_DRIFT"
else
    # Deduplicate and join with commas
    unique_files=$(printf '%s\n' "${drifted_files[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "DRIFT_DETECTED: ${unique_files}"
fi

# Check relates_to neighbors for drift (additive — appended after file-drift output)
_check_relates_to_drift "$EPIC_ID" "$children_json"

exit 0
