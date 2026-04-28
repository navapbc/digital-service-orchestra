#!/usr/bin/env bash
set -euo pipefail
# sprint-review-scope-check.sh
# Compare reviewer-findings.json file references against a task's ## File Impact
# section to detect out-of-scope review feedback.
#
# Usage:
#   sprint-review-scope-check.sh <reviewer-findings-path> <task-id>
#
# Environment:
#   TICKET_CMD — path to ticket CLI (default: <script-dir>/ticket)
#
# Exit codes:
#   0 = success (IN_SCOPE or OUT_OF_SCOPE printed to stdout)
#   1 = runtime error
#   2 = usage error (missing arguments)
#
# Output (single line):
#   IN_SCOPE                            — all finding files within task scope
#   OUT_OF_SCOPE: file1,file2,...       — files not in the task file impact table
#
# Integration: Referenced in SKILL.md Phase 5 Step 7a (out-of-scope review
# feedback detection). Between-batch routing in Step 13a.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 2 ]; then
    echo "Usage: sprint-review-scope-check.sh <reviewer-findings-path> <task-id>" >&2
    exit 2
fi

FINDINGS_PATH="$1"
TASK_ID="$2"

# ── Edge case: no findings file → IN_SCOPE (graceful) ────────────────────────
if [ ! -f "$FINDINGS_PATH" ]; then
    echo "IN_SCOPE"
    exit 0
fi

# ── Read task ticket and extract ## File Impact section ───────────────────────
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"
ticket_output=$("$TICKET_CMD" show "$TASK_ID" 2>/dev/null) || ticket_output=""

if [ -z "$ticket_output" ]; then
    # Cannot load ticket → cannot determine scope → IN_SCOPE
    echo "IN_SCOPE"
    exit 0
fi

# Primary: try ticket get-file-impact for structured file paths
impact_files=$(${TICKET_CMD:-ticket} get-file-impact "$TASK_ID" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for e in d:
        p = e.get("path") or e.get("file") or ""
        if p:
            print(p)
except Exception:
    pass
' 2>/dev/null || true) || impact_files=""

# Fallback: extract description from JSON and parse ## File Impact section
if [ -z "$impact_files" ]; then
    impact_files=$(echo "$ticket_output" | python3 -c "
import json, sys, re

ticket = json.load(sys.stdin)
desc = ticket.get('description', '')

# Find ## File Impact section (handle multiple heading formats)
# Match '## File Impact', '## File impact', '## file impact', etc.
pattern = r'(?:^|\n)##\s+[Ff]ile\s+[Ii]mpact\s*\n(.*?)(?:\n##\s|\Z)'
match = re.search(pattern, desc, re.DOTALL)
if not match:
    sys.exit(0)

section = match.group(1)
files = []
for line in section.strip().split('\n'):
    line = line.strip()
    # Parse lines like '- path/to/file' or '- path/to/file (description)'
    if line.startswith('- '):
        # Extract path — take first whitespace-delimited token after '- '
        path = line[2:].strip().split()[0] if line[2:].strip() else ''
        if path:
            files.append(path)

for f in files:
    print(f)
" 2>/dev/null) || impact_files=""
fi

# ── Edge case: no File Impact section → IN_SCOPE ─────────────────────────────
if [ -z "$impact_files" ]; then
    echo "IN_SCOPE"
    exit 0
fi

# ── Parse reviewer-findings.json for file paths from findings ─────────────────
finding_files=$(python3 -c "
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

for finding in data.get('findings', []):
    path = finding.get('file', '')
    if path:  # silently skip empty/missing file paths
        print(path)
" "$FINDINGS_PATH" 2>/dev/null) || finding_files=""

# ── Edge case: no finding files → IN_SCOPE ────────────────────────────────────
if [ -z "$finding_files" ]; then
    echo "IN_SCOPE"
    exit 0
fi

# ── Compare: find files in findings but NOT in the impact table ───────────────
out_of_scope=()
while IFS= read -r ffile; do
    [ -z "$ffile" ] && continue
    in_scope=false
    while IFS= read -r ifile; do
        [ -z "$ifile" ] && continue
        if [ "$ffile" = "$ifile" ]; then
            in_scope=true
            break
        fi
    done <<< "$impact_files"
    if [ "$in_scope" = false ]; then
        out_of_scope+=("$ffile")
    fi
done <<< "$finding_files"

# ── Deduplicate out-of-scope list ─────────────────────────────────────────────
if [ ${#out_of_scope[@]} -gt 0 ]; then
    # Deduplicate while preserving order
    seen=()
    unique=()
    for f in "${out_of_scope[@]}"; do
        is_dup=false
        for s in "${seen[@]:+"${seen[@]}"}"; do
            if [ "$f" = "$s" ]; then
                is_dup=true
                break
            fi
        done
        if [ "$is_dup" = false ]; then
            seen+=("$f")
            unique+=("$f")
        fi
    done

    # Join with commas
    result=""
    for f in "${unique[@]}"; do
        if [ -z "$result" ]; then
            result="$f"
        else
            result="$result,$f"
        fi
    done
    echo "OUT_OF_SCOPE: $result"
else
    echo "IN_SCOPE"
fi

exit 0
