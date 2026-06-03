#!/usr/bin/env bash
# scripts/implementation-plan/migration-class-detect.sh
#
# Classifies the migration class of a target symbol by counting call sites.
#
# Argv contract:
#   migration-class-detect.sh <target_symbol> [<lang>] [<repo_root>]
#
#   target_symbol  — the symbol whose call sites are counted (required)
#   lang           — language hint for ast-grep (default: python)
#   repo_root      — directory to scan (default: git rev-parse --show-toplevel)
#
# When target_symbol is empty/absent, emits migration-class=inconclusive (no crash).
#
# Output:
#   A single-line JSON object on stdout conforming to the MIGRATION_CLASS marker contract:
#   {"migration-class":"<value>","detection_query":"<query>","threshold_used":<n>,"target_symbol":"<sym>"}
#
#   migration-class values:
#     sweep       — call site count >= threshold_used (ast-grep available, not db-coupled)
#     db          — symbol file set matches schema/migration globs (regardless of call count)
#     inconclusive — ast-grep unavailable or no target_symbol provided
#
# Configuration:
#   migration.call_site_threshold — read via get_call_site_threshold() (default 3, floor 1)
#   WORKFLOW_CONFIG_FILE          — override config file for test isolation
#
# Detection exclusions:
#   - import lines (lines matching ^(import |from .* import|require\(|#include))
#   - test files (paths matching test/, *_test.*, *.test.*)
#
# DB short-circuit globs (any matched file in repo_root triggers migration-class=db):
#   migrations/, alembic/, db/migrate/, *.migration.ts, schema.sql

set -uo pipefail

# ── Locate plugin root relative to this script ───────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script lives at: <plugin_root>/scripts/implementation-plan/migration-class-detect.sh
_PLUGIN_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

# ── Source helpers ────────────────────────────────────────────────────────────
# shellcheck source=../../hooks/lib/centrality.sh
source "${_PLUGIN_ROOT}/hooks/lib/centrality.sh"
# shellcheck source=../../hooks/lib/planning-config.sh
source "${_PLUGIN_ROOT}/hooks/lib/planning-config.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────
TARGET_SYMBOL="${1:-}"
LANG="${2:-python}"
REPO_ROOT_ARG="${3:-}"

# Resolve repo root
if [[ -n "$REPO_ROOT_ARG" ]]; then
    SCAN_ROOT="$REPO_ROOT_ARG"
else
    SCAN_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
fi

# ── Read threshold ────────────────────────────────────────────────────────────
THRESHOLD=3
THRESHOLD=$(get_call_site_threshold 2>/dev/null) || THRESHOLD=3

# ── Build the detection query string ──────────────────────────────────────────
# ast-grep call-site pattern: matches <sym>(<args>)
DETECTION_QUERY="\$A.${TARGET_SYMBOL}(\$\$\$B)"
# Simpler pattern that works for both method calls and standalone calls
DETECTION_QUERY="${TARGET_SYMBOL}(\$\$\$)"

# ── Emit JSON helper ──────────────────────────────────────────────────────────
emit_json() {
    local mclass="$1"
    local dq="$2"
    local tu="$3"
    local sym="$4"
    # Escape double-quotes in fields for JSON safety
    dq="${dq//\"/\\\"}"
    sym="${sym//\"/\\\"}"
    printf '{"migration-class":"%s","detection_query":"%s","threshold_used":%s,"target_symbol":"%s"}\n' \
        "$mclass" "$dq" "$tu" "$sym"
}

# ── Handle empty target_symbol → inconclusive ────────────────────────────────
if [[ -z "$TARGET_SYMBOL" ]]; then
    emit_json "inconclusive" "$DETECTION_QUERY" "$THRESHOLD" ""
    exit 0
fi

# ── DB short-circuit: check if scan root contains schema/migration files ──────
# Globs: migrations/, alembic/, db/migrate/, *.migration.ts, schema.sql
_is_db_coupled() {
    local root="$1"
    # Check for migration directory patterns
    if [[ -d "${root}/migrations" ]] || \
       [[ -d "${root}/alembic" ]] || \
       [[ -d "${root}/db/migrate" ]]; then
        return 0
    fi
    # Check for migration file patterns
    if find "$root" -maxdepth 5 \
        \( -name "*.migration.ts" -o -name "schema.sql" \) \
        -not -path "*/node_modules/*" \
        2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

if _is_db_coupled "$SCAN_ROOT"; then
    emit_json "db" "$DETECTION_QUERY" "$THRESHOLD" "$TARGET_SYMBOL"
    exit 0
fi

# ── ast-grep availability check ───────────────────────────────────────────────
if ! _is_astgrep_sg; then
    emit_json "inconclusive" "$DETECTION_QUERY" "$THRESHOLD" "$TARGET_SYMBOL"
    exit 0
fi

# ── Count non-test, non-import call sites via ast-grep ────────────────────────
# Run sg to find all matches, then filter out:
#   - test files: paths matching /test/, _test., .test.
#   - import lines: lines starting with import, from ... import, require(, #include
_count_call_sites() {
    local sym="$1"
    local lang="$2"
    local root="$3"
    local pattern="$4"

    local raw_output
    # sg outputs file:line:col:match format with --json or plain text
    # Use plain output (one match per line with file path) to count
    raw_output=$(sg --pattern "$pattern" --lang "$lang" "$root" 2>/dev/null || true)

    if [[ -z "$raw_output" ]]; then
        echo "0"
        return 0
    fi

    local count=0
    local line file_part rel_part line_content

    # Normalise the scan root for scope-relative path computation: strip any
    # trailing slash so the prefix-strip below yields a clean relative path.
    local root_norm="${root%/}"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # sg output format: filepath:linenum:colnum:matched_text
        # or just the matched content with file shown above
        # Try to extract file path from the line
        file_part="${line%%:*}"

        # Compute the path RELATIVE to the scan root before applying the
        # test-file exclusion. The exclusion must be scope-relative: a "tests/"
        # segment in the absolute prefix above the scan root (e.g. when the
        # scan root itself lives under a repo's tests/ tree) must NOT cause the
        # legitimate source files inside the scan root to be excluded. Anchoring
        # the match to the relative path keeps the real exclusion of test files
        # *within* the scanned tree intact while ignoring the absolute prefix.
        rel_part="$file_part"
        if [[ "$file_part" == "$root_norm/"* ]]; then
            rel_part="${file_part#"$root_norm"/}"
        elif [[ "$file_part" == "$root_norm" ]]; then
            rel_part=""
        fi

        # Skip test files — matched against the scope-relative path only.
        if echo "$rel_part" | grep -qE '(^|/)(test[s]?)/|_test\.|\.test\.' 2>/dev/null; then
            continue
        fi

        # Extract the actual matched line content (everything after file:line:col:)
        # sg format: path:line:col:content
        line_content=$(echo "$line" | cut -d: -f4-)

        # Skip import lines
        if echo "$line_content" | grep -qE '^\s*(import |from .+ import |require\(|#include)' 2>/dev/null; then
            continue
        fi

        (( ++count ))
    done <<< "$raw_output"

    echo "$count"
}

CALL_SITE_COUNT=$(_count_call_sites "$TARGET_SYMBOL" "$LANG" "$SCAN_ROOT" "$DETECTION_QUERY")

# ── Classify ──────────────────────────────────────────────────────────────────
if [[ "$CALL_SITE_COUNT" -ge "$THRESHOLD" ]]; then
    emit_json "sweep" "$DETECTION_QUERY" "$THRESHOLD" "$TARGET_SYMBOL"
else
    emit_json "inconclusive" "$DETECTION_QUERY" "$THRESHOLD" "$TARGET_SYMBOL"
fi

exit 0
