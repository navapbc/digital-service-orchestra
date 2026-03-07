#!/usr/bin/env bash
# lockpick-workflow/scripts/issue-quality-check.sh
# Check whether a tk issue has enough detail for issue-as-prompt dispatch.
# Sub-agents using issue-as-prompt read their own context via `tk show`.
# This script validates the issue is detailed enough for that pattern.
#
# Usage:
#   issue-quality-check.sh <id>
#
# Exit codes:
#   0 = quality sufficient (issue-as-prompt is safe)
#   1 = too sparse (fall back to inline prompt)
#
# Output (single line):
#   QUALITY: pass (<line_count> lines, <keyword_count> criteria, <ac_items> AC items, <file_impact> file impact)
#   QUALITY: fail - description too sparse (<line_count> lines), using inline prompt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TK="${TK:-$SCRIPT_DIR/tk}"

if [ $# -ne 1 ]; then
    echo "Usage: issue-quality-check.sh <id>" >&2
    exit 1
fi

ID="$1"

# Get the full issue output (stays in script, not in orchestrator context).
# tk show exits 0 even when an issue is not found (error goes to stderr).
# Detect failure by checking for an empty output after suppressing stderr.
output=$("$TK" show "$ID" 2>/dev/null)
if [ -z "$output" ]; then
    echo "QUALITY: fail - could not load issue $ID, using inline prompt"
    exit 1
fi

# Extract description (markdown body after YAML frontmatter, across ALL sections).
# tk show outputs YAML frontmatter between --- delimiters, then markdown body with ## headings.
# Previously this stopped at the first ## heading, undercounting structured tickets.
description=$(echo "$output" | awk '
  /^---$/ { fm++; next }
  fm < 2 { next }
  /^#+ / { next }
  { print }
')

# Count description lines (non-empty)
line_count=$(echo "$description" | grep -c '[^ ]' 2>/dev/null || echo "0")

# Count acceptance criteria indicators
keyword_count=0
# File path patterns (src/, tests/, app/)
# Note: tr -d '\n' strips trailing newline from grep -c output that breaks $((...)) arithmetic
keyword_count=$((keyword_count + $(echo "$description" | grep -c -E '(src/|tests/|app/|\.py|\.ts|\.js|\.html)' 2>/dev/null | tr -d '\n' || echo "0")))
# Criteria keywords
keyword_count=$((keyword_count + $(echo "$description" | grep -c -iE '(must|should|given|when|then|acceptance|criteria|expect|verify|ensure)' 2>/dev/null | tr -d '\n' || echo "0")))

# Count acceptance criteria items in ## Acceptance Criteria section.
# Matches the "## Acceptance Criteria" heading from tk markdown body.
# Note: This awk logic is intentionally duplicated in check-acceptance-criteria.sh
# for independence (each script calls tk show separately). Keep both in sync.
ac_items=$(echo "$output" | awk '
  tolower($0) ~ /^## acceptance criteria/ { found=1; next }
  found && /^## / { exit }
  found && /^- \[/ { count++ }
  END { print count+0 }
')
ac_items="${ac_items:-0}"

# Count file impact items in ## File Impact or ### Files to modify section.
# Matches lines containing file path patterns (src/, tests/, app/, .py, .ts, .js, .html).
file_impact_items=$(echo "$output" | awk '
  tolower($0) ~ /^## file impact/ || tolower($0) ~ /^### files to modify/ { found=1; next }
  found && /^## / { exit }
  found && /^### / && tolower($0) !~ /^### files to/ { exit }
  found && /(src\/|tests\/|app\/|\.py|\.ts|\.js|\.html)/ { count++ }
  END { print count+0 }
')
file_impact_items="${file_impact_items:-0}"

# Quality gate: staged rollout (Phase 1 = warn-only for missing AC block)
# Phase 1: warn but don't enforce AC block requirement
if [ "$ac_items" -ge 1 ]; then
    echo "QUALITY: pass ($line_count lines, $keyword_count criteria, $ac_items AC items, $file_impact_items file impact)"
    exit 0
elif [ "$file_impact_items" -ge 1 ]; then
    echo "QUALITY: pass ($line_count lines, $keyword_count criteria, $file_impact_items file impact)"
    exit 0
elif [ "$line_count" -ge 5 ] && [ "$keyword_count" -ge 1 ]; then
    echo "QUALITY: pass (legacy - no AC/file impact) ($line_count lines, $keyword_count criteria)"
    echo "WARNING: Task lacks Acceptance block and File Impact section. Add via 'tk add-note <id>'." >&2
    exit 0
else
    echo "QUALITY: fail - description too sparse ($line_count lines), using inline prompt"
    exit 1
fi
