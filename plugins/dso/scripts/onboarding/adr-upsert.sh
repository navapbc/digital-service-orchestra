#!/usr/bin/env bash
set -uo pipefail
# adr-upsert.sh
# Create or revise an Architecture Decision Record (ADR).
#
# Deduplication is keyed on the slugified decision topic (--topic). If an ADR
# for the same topic already exists under docs/adr/, a revision note is
# appended instead of creating a duplicate file.
#
# Usage:
#   adr-upsert.sh --topic <decision-topic> --content-file <path>
#                 [--status Accepted] [--project-dir <dir>]
#
# Exit codes:
#   0 — success (created or appended)
#   1 — usage error
#   2 — content file missing

TOPIC=""
CONTENT_FILE=""
STATUS="Accepted"
PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --topic) TOPIC="${2:-}"; shift 2 ;;
        --topic=*) TOPIC="${1#--topic=}"; shift ;;
        --content-file) CONTENT_FILE="${2:-}"; shift 2 ;;
        --content-file=*) CONTENT_FILE="${1#--content-file=}"; shift ;;
        --status) STATUS="${2:-Accepted}"; shift 2 ;;
        --status=*) STATUS="${1#--status=}"; shift ;;
        --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
        --project-dir=*) PROJECT_DIR="${1#--project-dir=}"; shift ;;
        -h|--help)
            echo "Usage: adr-upsert.sh --topic <topic> --content-file <path> [--status Accepted] [--project-dir <dir>]"
            exit 0
            ;;
        *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$TOPIC" || -z "$CONTENT_FILE" ]]; then
    echo "Error: --topic and --content-file are required" >&2
    exit 1
fi

if [[ ! -f "$CONTENT_FILE" ]]; then
    echo "Error: content file not found: $CONTENT_FILE" >&2
    exit 2
fi

if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

ADR_DIR="$PROJECT_DIR/docs/adr"
mkdir -p "$ADR_DIR"

# Slugify topic: lowercase, non-alnum → dash, collapse dashes, trim.
_slugify() {
    printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

SLUG="$(_slugify "$TOPIC")"
if [[ -z "$SLUG" ]]; then
    echo "Error: topic slugified to empty string" >&2
    exit 1
fi

# Look for an existing ADR with this slug.
EXISTING=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    EXISTING="$f"
    break
done < <(find "$ADR_DIR" -maxdepth 1 -type f -name "*-${SLUG}.md" 2>/dev/null | sort)

if [[ -n "$EXISTING" ]]; then
    # Append revision note.
    {
        printf '\n---\n\n## Revision — %s\n\n' "$(date -u +%Y-%m-%d)"
        printf 'Status: %s\n\n' "$STATUS"
        cat "$CONTENT_FILE"
    } >> "$EXISTING"
    echo "[DSO INFO] appended revision to existing ADR: $EXISTING"
    exit 0
fi

# Determine next ADR number (4-digit, zero-padded).
NEXT=1
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    base="$(basename "$f")"
    num="${base%%-*}"
    if [[ "$num" =~ ^[0-9]+$ ]]; then
        n=$((10#$num))
        (( n >= NEXT )) && NEXT=$((n + 1))
    fi
done < <(find "$ADR_DIR" -maxdepth 1 -type f -name "*.md" 2>/dev/null)

printf -v NUM "%04d" "$NEXT"
NEW_FILE="$ADR_DIR/${NUM}-${SLUG}.md"

{
    printf '# %s\n\n' "$TOPIC"
    printf 'Status: %s\n\n' "$STATUS"
    printf 'Date: %s\n\n' "$(date -u +%Y-%m-%d)"
    cat "$CONTENT_FILE"
} > "$NEW_FILE"

echo "[DSO INFO] created ADR: $NEW_FILE"
