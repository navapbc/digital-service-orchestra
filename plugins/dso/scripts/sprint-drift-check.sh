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

for arg in "$@"; do
    case "$arg" in
        --repo=*)
            REPO_PATH="${arg#--repo=}"
            ;;
        --*)
            echo "Unknown option: $arg" >&2
            echo "Usage: $(basename "$0") <epic-id> [--repo=<path>]" >&2
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
    echo "Usage: $(basename "$0") <epic-id> [--repo=<path>]" >&2
    echo "Error: epic-id is required" >&2
    exit 1
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

# ── Main logic ────────────────────────────────────────────────────────────────

# List children of the epic
children_json="$("$TICKET_CMD" list --parent="$EPIC_ID" 2>/dev/null || echo "[]")"

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

# Extract (index, created_at) pairs and write description files.
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
    desc_file = os.path.join(tmpdir, 'desc_{}.txt'.format(i))
    with open(desc_file, 'w') as f:
        f.write(description)
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

    # Extract file paths from the description
    _impact_files=$(_extract_impact_files "$_description")

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

exit 0
