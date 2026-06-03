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
#     db          — TARGET_SYMBOL is referenced inside a schema/migration file pattern
#     none         — detection ran, but symbol is below threshold / not migration-class
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
# DB classification (symbol-scoped, NOT repo-global):
#   migration-class=db is emitted only when TARGET_SYMBOL is actually referenced
#   inside a migration-pattern file — migrations/, alembic/, db/migrate/ directories,
#   or *.migration.ts / schema.sql files. The mere existence of such a directory does
#   NOT classify a symbol as db: a symbol with many call sites in normal source still
#   classifies as sweep.

set -uo pipefail

# ── Locate plugin root relative to this script ───────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script lives at: <plugin_root>/scripts/implementation-plan/migration-class-detect.sh
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${_SCRIPT_DIR}/../.." && pwd)}"

# ── Source helpers ────────────────────────────────────────────────────────────
# shellcheck source=../../hooks/lib/centrality.sh
source "${_PLUGIN_ROOT}/hooks/lib/centrality.sh"
# shellcheck source=../../hooks/lib/planning-config.sh
source "${_PLUGIN_ROOT}/hooks/lib/planning-config.sh"

# ── Parse arguments ───────────────────────────────────────────────────────────
TARGET_SYMBOL="${1:-}"
# Language hint for ast-grep. Deliberately NOT named LANG — that is the POSIX
# locale env var, and overwriting it corrupts child-process locales (sg/grep/find).
LANG_HINT="${2:-python}"
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
# ast-grep call-site pattern that works for both method calls and standalone calls
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

# ── DB classification (symbol-scoped): is TARGET_SYMBOL referenced inside a ───
# migration-pattern file? Classification is db ONLY when the target symbol
# actually appears within a schema/migration file — NOT merely because such a
# directory exists in the repo. A symbol with many call sites in normal source
# still classifies as sweep.
#
# Migration-pattern files: any file under migrations/ | alembic/ | db/migrate/
# directories, or any *.migration.ts / schema.sql file (maxdepth 5,
# excluding node_modules).
_symbol_in_migration_file() {
    local root="$1"
    local sym="$2"

    local migration_files=()
    local f
    # Collect candidate migration-pattern files. Use find with -path matches for
    # the directory patterns and -name matches for the file patterns.
    while IFS= read -r f; do
        [[ -n "$f" ]] && migration_files+=("$f")
    done < <(find "$root" -maxdepth 5 -type f \
        \( -path "*/migrations/*" \
           -o -path "*/alembic/*" \
           -o -path "*/db/migrate/*" \
           -o -name "*.migration.ts" \
           -o -name "schema.sql" \) \
        -not -path "*/node_modules/*" \
        2>/dev/null)

    # No migration-pattern files at all → not db.
    [[ ${#migration_files[@]} -eq 0 ]] && return 1

    # Is the target symbol referenced (as a word) inside any of them?
    if grep -qwF -- "$sym" "${migration_files[@]}" 2>/dev/null; then
        return 0
    fi
    return 1
}

if _symbol_in_migration_file "$SCAN_ROOT" "$TARGET_SYMBOL"; then
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
    local lang="$1"
    local root="$2"
    local pattern="$3"

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

        # Extract the actual matched line content. sg's default plain output
        # format is `file:line:content` (3 fields) — the matched source text is
        # field 3 onward (any colons inside the content are preserved by -f3-).
        line_content=$(echo "$line" | cut -d: -f3-)

        # Skip import lines
        if echo "$line_content" | grep -qE '^\s*(import |from .+ import |require\(|#include)' 2>/dev/null; then
            continue
        fi

        (( ++count ))
    done <<< "$raw_output"

    echo "$count"
}

CALL_SITE_COUNT=$(_count_call_sites "$LANG_HINT" "$SCAN_ROOT" "$DETECTION_QUERY")

# ── Classify ──────────────────────────────────────────────────────────────────
# Detection RAN (sg available, db check already excluded). A below-threshold
# result is NOT inconclusive — inconclusive is reserved for "detection could not
# run" (sg unavailable / no target symbol). Emit the distinct `none` value so
# consumers treat it as "not a migration-class change, proceed normally" rather
# than as an install-sg / re-run prompt.
if [[ "$CALL_SITE_COUNT" -ge "$THRESHOLD" ]]; then
    emit_json "sweep" "$DETECTION_QUERY" "$THRESHOLD" "$TARGET_SYMBOL"
else
    emit_json "none" "$DETECTION_QUERY" "$THRESHOLD" "$TARGET_SYMBOL"
fi

exit 0
