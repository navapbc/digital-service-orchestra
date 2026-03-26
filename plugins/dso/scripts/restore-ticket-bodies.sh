#!/usr/bin/env bash
set -euo pipefail
# restore-ticket-bodies.sh — Restore lost body content to tickets stripped by cross-worktree sync bug.
#
# The sync bug overwrote ticket files with versions that had correct frontmatter
# but empty bodies. This script finds the historical version with the richest body
# content and merges it with the current frontmatter.
#
# Usage:
#   scripts/restore-ticket-bodies.sh [--dry-run | --execute]
#
# Default behavior is --dry-run.

set -euo pipefail

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$REPO_ROOT"
TICKETS_DIR="$REPO_ROOT/.tickets"
# Repo-relative path for git show/log (which need repo-relative paths)
TICKETS_REL=".tickets"
BASELINE_COMMIT="2263d8ab"
MAX_HISTORY=50
MIN_IMPROVEMENT=3  # historical body must have at least 3 more non-empty lines

MODE="dry-run"
if [[ "${1:-}" == "--execute" ]]; then
    MODE="execute"
elif [[ "${1:-}" == "--dry-run" ]]; then
    MODE="dry-run"
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--dry-run | --execute]" >&2
    exit 1
fi

echo "=== Ticket Body Restoration (mode: $MODE) ==="
echo ""

# Count non-empty body lines (lines after the second ---).
# Expects file content on stdin.
count_body_lines() {
    awk 'BEGIN{n=0; c=0} /^---$/{n++; next} n>=2 && NF{c++} END{print c}'
}

# Extract frontmatter (everything from first --- through second ---, inclusive).
extract_frontmatter() {
    awk '/^---$/{n++; print; if(n==2) exit; next} n>=1{print}'
}

# Extract body (everything after the second ---).
extract_body() {
    awk 'BEGIN{n=0; past=0} /^---$/{n++; if(n==2){past=1; next}} past{print}'
}

restored=0
skipped=0
examined=0

for ticket_file in "$TICKETS_DIR"/*.md; do
    [[ -f "$ticket_file" ]] || continue
    filename="$(basename "$ticket_file")"
    ticket_id="${filename%.md}"

    examined=$((examined + 1))

    # Current body line count
    current_body_lines=$(count_body_lines < "$ticket_file")

    # Find the commit with the richest body content.
    # Check baseline first, then search history.
    best_sha=""
    best_lines=0

    # Check baseline commit first (known-good for most tickets)
    baseline_content=$(git show "$BASELINE_COMMIT":"$TICKETS_REL/$filename" 2>/dev/null || true)
    if [[ -n "$baseline_content" ]]; then
        bl=$(echo "$baseline_content" | count_body_lines)
        if (( bl > best_lines )); then
            best_lines=$bl
            best_sha="$BASELINE_COMMIT"
        fi
    fi

    # Search recent history for potentially richer versions
    while IFS= read -r sha; do
        [[ -n "$sha" ]] || continue
        # Skip baseline — already checked
        [[ "$sha" == "$BASELINE_COMMIT"* ]] && continue
        content=$(git show "$sha":"$TICKETS_REL/$filename" 2>/dev/null || true)
        [[ -n "$content" ]] || continue
        bl=$(echo "$content" | count_body_lines)
        if (( bl > best_lines )); then
            best_lines=$bl
            best_sha="$sha"
        fi
    done < <(git log --all -"$MAX_HISTORY" --format=%H -- "$TICKETS_REL/$filename" 2>/dev/null)

    # Check if historical version is meaningfully richer
    improvement=$((best_lines - current_body_lines))
    if (( improvement < MIN_IMPROVEMENT )); then
        skipped=$((skipped + 1))
        continue
    fi

    short_sha="${best_sha:0:8}"
    echo "$ticket_id: $current_body_lines -> $best_lines (from $short_sha)"

    if [[ "$MODE" == "execute" ]]; then
        # Extract current frontmatter (preserve status, jira_key, parent, deps, etc.)
        current_fm=$(extract_frontmatter < "$ticket_file")

        # Extract historical body
        hist_body=$(git show "$best_sha":"$TICKETS_REL/$filename" | extract_body)

        # Write merged file: current frontmatter + historical body
        {
            echo "$current_fm"
            echo "$hist_body"
        } > "$ticket_file"
    fi

    restored=$((restored + 1))
done

echo ""
echo "=== Summary ==="
echo "Examined:  $examined tickets"
echo "Restoring: $restored tickets"
echo "Skipped:   $skipped tickets (no improvement or below threshold)"
if [[ "$MODE" == "dry-run" ]]; then
    echo ""
    echo "This was a dry run. Use --execute to apply changes."
fi
