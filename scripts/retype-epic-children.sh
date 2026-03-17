#!/usr/bin/env bash
set -uo pipefail
# retype-epic-children.sh — Retype task-type tickets whose parent is an epic to story.
#
# Finds all .tickets/*.md files where:
#   - YAML frontmatter type == "task"
#   - YAML frontmatter parent field is set AND the referenced parent ticket has type == "epic"
#
# For matching tickets, changes `type: task` to `type: story` in-place.
# The operation is idempotent: re-running produces zero changes when all eligible
# tickets are already type=story.
#
# Usage:
#   ./scripts/retype-epic-children.sh [--dry-run]
#
# Options:
#   --dry-run   Print which tickets would be retyped without modifying any files.
#
# Environment:
#   TICKETS_DIR   Override the tickets directory (default: <repo-root>/.tickets)
#                 Useful for testing without touching the real ticket store.
#
# Exit codes:
#   0  — success (even if no tickets were retyped)
#   1  — I/O error or .tickets/ directory not found

set -uo pipefail

# ── Parse arguments ───────────────────────────────────────────────────────────

DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        *)
            echo "ERROR: unknown argument: $arg" >&2
            echo "Usage: $0 [--dry-run]" >&2
            exit 1
            ;;
    esac
done

# ── Resolve paths ─────────────────────────────────────────────────────────────

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: not inside a git repository" >&2
    exit 1
fi

TICKETS_DIR="${TICKETS_DIR:-${REPO_ROOT}/.tickets}"

if [ ! -d "$TICKETS_DIR" ]; then
    echo "ERROR: tickets directory not found: $TICKETS_DIR" >&2
    exit 1
fi

# ── Helper: extract a frontmatter field value ─────────────────────────────────
# Usage: get_frontmatter_field <file> <field_name>
# Prints the value (trimmed) or an empty string if not found.
get_frontmatter_field() {
    local file="$1"
    local field="$2"
    awk -v field="$field" '
        /^---$/ { n++; if (n == 2) exit; next }
        n == 1 && $0 ~ "^" field ":[[:space:]]*" {
            # Strip "fieldname: " prefix and any inline comment after "#"
            sub("^" field ":[[:space:]]*", "")
            sub("[[:space:]]*#.*$", "")
            # Strip surrounding whitespace and quotes
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print
            exit
        }
    ' "$file"
}

# ── Main loop ─────────────────────────────────────────────────────────────────

retyped=0
skipped_not_task=0
skipped_no_parent=0
skipped_parent_not_epic=0
skipped_already_feature=0

while IFS= read -r ticket_file; do
    ticket_type=$(get_frontmatter_field "$ticket_file" "type")

    # Only process type=task tickets
    if [ "$ticket_type" != "task" ]; then
        ((skipped_not_task++))
        continue
    fi

    parent_id=$(get_frontmatter_field "$ticket_file" "parent")

    # Skip if no parent field
    if [ -z "$parent_id" ]; then
        ((skipped_no_parent++))
        continue
    fi

    # Look up parent ticket file
    parent_file="$TICKETS_DIR/${parent_id}.md"
    if [ ! -f "$parent_file" ]; then
        # Parent ticket not found locally — skip (may live in another worktree or be external)
        ((skipped_parent_not_epic++))
        continue
    fi

    parent_type=$(get_frontmatter_field "$parent_file" "type")

    # Only retype if parent is an epic
    if [ "$parent_type" != "epic" ]; then
        ((skipped_parent_not_epic++))
        continue
    fi

    # This ticket qualifies — retype from task to story
    ticket_name="$(basename "$ticket_file")"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] Would retype: $ticket_name (parent: $parent_id)"
        ((retyped++))
    else
        # Replace `type: task` with `type: story` only within the frontmatter block.
        # We use awk to limit the substitution to lines before the second `---` delimiter.
        tmp_file="${ticket_file}.tmp.$$"
        awk '
            /^---$/ { n++ }
            n == 1 && /^type:[[:space:]]*task[[:space:]]*$/ { sub(/^type:[[:space:]]*task/, "type: story") }
            { print }
        ' "$ticket_file" > "$tmp_file"

        if ! mv "$tmp_file" "$ticket_file"; then
            echo "ERROR: failed to update $ticket_file" >&2
            rm -f "$tmp_file"
            exit 1
        fi

        echo "Retyped: $ticket_name (parent: $parent_id)"
        ((retyped++))
    fi

done < <(find "$TICKETS_DIR" -maxdepth 1 -name "*.md" -type f | sort)

# ── Summary ───────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Dry run complete. Would retype ${retyped} ticket(s)."
else
    echo "Done. Retyped ${retyped} ticket(s)."
fi
