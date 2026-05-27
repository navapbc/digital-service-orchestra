#!/usr/bin/env bash
# scripts/write-design-md-additions.sh
# Accepts a JSON payload on stdin and appends a section to repo-root DESIGN.md.
#
# JSON payload schema:
#   {
#     "section_heading": "<string>",    (required)
#     "content_lines":   ["<string>"]   (required, array of strings)
#   }
#
# Behavior:
#   - Creates DESIGN.md at repo root if it does not exist.
#   - Idempotent: if a section with the same heading already exists, exits 0
#     without appending a duplicate.
#   - Uses flock(1) for serialized append so concurrent invocations are safe.
#   - Exits non-zero on empty/invalid payload or missing required fields.
#
# Exit codes:
#   0 — Success (written or already present)
#   1 — Invalid payload (empty stdin, invalid JSON, missing required fields)
#   2 — I/O error (cannot write DESIGN.md)
#
# Environment:
#   PROJECT_ROOT — override the repo root (default: git rev-parse --show-toplevel)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
DESIGN_MD="$PROJECT_ROOT/DESIGN.md"

# ── 1. Read stdin ─────────────────────────────────────────────────────────────

input=$(cat)

if [[ -z "$input" ]]; then
    echo "ERROR: No input on stdin. Pipe a JSON payload." >&2
    exit 1
fi

# ── 2. Validate JSON ──────────────────────────────────────────────────────────

if ! echo "$input" | jq -e '.' >/dev/null 2>&1; then
    echo "ERROR: Input is not valid JSON." >&2
    exit 1
fi

# ── 3. Extract and validate required fields ───────────────────────────────────

section_heading=$(echo "$input" | jq -r '.section_heading // empty' 2>/dev/null)
if [[ -z "$section_heading" ]]; then
    echo "ERROR: Required field 'section_heading' is missing or empty." >&2
    exit 1
fi

# Validate content_lines is present and is an array
content_lines_type=$(echo "$input" | jq -r 'if has("content_lines") then (.content_lines | type) else "missing" end' 2>/dev/null)
if [[ "$content_lines_type" == "missing" ]]; then
    echo "ERROR: Required field 'content_lines' is missing." >&2
    exit 1
fi
if [[ "$content_lines_type" != "array" ]]; then
    echo "ERROR: Field 'content_lines' must be an array." >&2
    exit 1
fi

# Build the section text from content_lines
section_text=$(echo "$input" | jq -r '.content_lines[]' 2>/dev/null)

# ── 4. Create DESIGN.md if absent ────────────────────────────────────────────

if [[ ! -f "$DESIGN_MD" ]]; then
    touch "$DESIGN_MD" 2>/dev/null || {
        echo "ERROR: Cannot create $DESIGN_MD" >&2
        exit 2
    }
fi

# ── 5. flock-serialized idempotent append ────────────────────────────────────
#
# We acquire an exclusive lock on a lock file derived from DESIGN.md to
# serialize concurrent writers. BSD flock (macOS) and util-linux flock (Linux)
# both support `flock <lockfile> <cmd>` style; the inner sub-shell avoids
# dependency on a specific flock binary path.

LOCK_FILE="${DESIGN_MD}.lock"

(
    # Acquire exclusive lock on fd 9
    exec 9>"$LOCK_FILE"
    flock -x 9

    # Re-check idempotency inside the lock (race-condition safe)
    if grep -qF "## ${section_heading}" "$DESIGN_MD" 2>/dev/null; then
        # Section already present — nothing to do
        exit 0
    fi

    # Append section
    # shellcheck disable=SC2094  # Read (-s check) and append (>>) are sequential, not piped
    {
        # Blank line separator if file is non-empty
        if [[ -s "$DESIGN_MD" ]]; then
            echo ""
        fi
        echo "## ${section_heading}"
        echo ""
        echo "$section_text"
    } >> "$DESIGN_MD" || {
        echo "ERROR: Failed to append to $DESIGN_MD" >&2
        exit 2
    }
) || exit $?

exit 0
