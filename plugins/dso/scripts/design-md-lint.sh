#!/usr/bin/env bash
# scripts/design-md-lint.sh
#
# Design system lint wrapper using @google/design.md CLI.
# Scopes lint to diff-touched lines only — pre-existing violations in untouched
# lines do NOT cause a non-zero exit.
#
# CRITICAL: @google/design.md lint exits 0 regardless of findings.
# Exit code is NOT reliable. Parse JSON output for summary.errors instead.
#
# Three-state config gate: design.lint_enabled (auto|always|never)
#   auto   — enabled only when a UI stack is detected via detect-ui-files.sh
#   always — always enabled regardless of file types staged
#   never  — always disabled (exit 0 immediately)
#
# Fail-open conditions (exit 0, skip lint):
#   - design.lint_enabled=never
#   - auto mode with no UI files detected
#   - npx not available (command -v check)
#   - DESIGN.md not present at the configured path
#   - No staged files
#   - No diff-touched lines in scope-eligible files
#
# Usage:
#   bash scripts/design-md-lint.sh
#   DSO_CONFIG_PATH=/path/to/dso-config.conf bash scripts/design-md-lint.sh
#
# Environment overrides (for testing):
#   DSO_CONFIG_PATH        — path to dso-config.conf
#   DESIGN_MD_VERSION      — override pinned @google/design.md version
#   DESIGN_MD_NOTES_PATH   — override design.design_notes_path config key

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# ── Config resolution ─────────────────────────────────────────────────────────
CONFIG_FILE="${DSO_CONFIG_PATH:-$REPO_ROOT/.claude/dso-config.conf}"

# If config file is absent, treat as auto mode (no UI files → exit 0)
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "INFO: .claude/dso-config.conf not found — treating design.lint_enabled as auto" >&2
    LINT_ENABLED="auto"
else
    LINT_ENABLED=$(bash "$SCRIPT_DIR/read-config.sh" design.lint_enabled "$CONFIG_FILE" 2>/dev/null || true)
    LINT_ENABLED="${LINT_ENABLED:-auto}"
fi

# Normalize to lowercase (tr for macOS bash 3.2 compatibility)
LINT_ENABLED=$(printf '%s' "$LINT_ENABLED" | tr '[:upper:]' '[:lower:]')

# Validate accepted values
case "$LINT_ENABLED" in
    auto|always|never) ;;
    *)
        echo "WARNING: design.lint_enabled='$LINT_ENABLED' is not a valid value (auto|always|never); defaulting to auto." >&2
        LINT_ENABLED="auto"
        ;;
esac

# ── never mode: immediate exit 0 ─────────────────────────────────────────────
if [[ "$LINT_ENABLED" == "never" ]]; then
    echo "INFO: design.lint_enabled=never — skipping design.md lint." >&2
    exit 0
fi

# ── Fail-open: npx not available ─────────────────────────────────────────────
if ! command -v npx >/dev/null 2>&1; then
    echo "INFO: npx not available — skipping design.md lint (fail-open)." >&2
    exit 0
fi

# ── Resolve DESIGN.md path ────────────────────────────────────────────────────
if [[ -n "${DESIGN_MD_NOTES_PATH:-}" ]]; then
    DESIGN_NOTES_PATH="$DESIGN_MD_NOTES_PATH"
elif [[ -f "$CONFIG_FILE" ]]; then
    _cfg_path=$(bash "$SCRIPT_DIR/read-config.sh" design.design_notes_path "$CONFIG_FILE" 2>/dev/null || true)
    DESIGN_NOTES_PATH="${_cfg_path:-DESIGN.md}"
else
    DESIGN_NOTES_PATH="DESIGN.md"
fi

# Resolve to absolute path (relative to repo root)
if [[ "$DESIGN_NOTES_PATH" != /* ]]; then
    DESIGN_NOTES_PATH="$REPO_ROOT/$DESIGN_NOTES_PATH"
fi

# Fail-open: DESIGN.md not present
if [[ ! -f "$DESIGN_NOTES_PATH" ]]; then
    echo "INFO: Design notes file not found at '$DESIGN_NOTES_PATH' — skipping design.md lint (fail-open)." >&2
    exit 0
fi

# ── Resolve pinned version ────────────────────────────────────────────────────
DESIGN_MD_VERSION="${DESIGN_MD_VERSION:-0.2.0}"

# ── Get staged files ──────────────────────────────────────────────────────────
STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)

if [[ -z "$STAGED_FILES" ]]; then
    echo "INFO: No staged files — skipping design.md lint." >&2
    exit 0
fi

# ── auto mode: check for UI stack ────────────────────────────────────────────
if [[ "$LINT_ENABLED" == "auto" ]]; then
    if ! echo "$STAGED_FILES" | bash "$SCRIPT_DIR/detect-ui-files.sh" 2>/dev/null; then
        echo "INFO: auto mode — no UI files detected in staged changes; skipping design.md lint." >&2
        exit 0
    fi
fi

# ── Extract diff-touched line ranges per file ─────────────────────────────────
# Use git diff --cached --unified=0 to extract exact changed line ranges.
# Format: @@ -old_start[,old_count] +new_start[,new_count] @@
# We extract new file (+) line ranges to scope lint to added/modified lines.
#
# Writes to a temp file: filename TAB start-end (one range per line)
_ranges_tmp=$(mktemp /tmp/design-md-ranges.XXXXXX)
trap 'rm -f "$_ranges_tmp"' EXIT

_current_file=""
while IFS= read -r line; do
    # Match file header: +++ b/path/to/file
    if [[ "$line" =~ ^\+\+\+\ b/(.+)$ ]]; then
        _current_file="${BASH_REMATCH[1]}"
        continue
    fi
    # Match hunk header: @@ -old +new_start[,new_count] @@
    if [[ "$line" =~ ^@@\ -[0-9,]+\ \+([0-9]+)(,([0-9]+))?\ @@.* ]]; then
        _new_start="${BASH_REMATCH[1]}"
        _new_count="${BASH_REMATCH[3]:-1}"
        # If count is 0, this hunk only deletes — no new lines to lint
        if [[ "$_new_count" -gt 0 && -n "$_current_file" ]]; then
            _new_end=$(( _new_start + _new_count - 1 ))
            printf '%s\t%d-%d\n' "$_current_file" "$_new_start" "$_new_end" >> "$_ranges_tmp"
        fi
        continue
    fi
done < <(git diff --cached --unified=0 2>/dev/null || true)

if [[ ! -s "$_ranges_tmp" ]]; then
    echo "INFO: No diff-touched line ranges found in staged changes — skipping design.md lint." >&2
    exit 0
fi

# ── Parse error count from JSON lint output ───────────────────────────────────
# CRITICAL: @google/design.md lint exits 0 regardless of findings.
# We MUST parse JSON output for summary.errors.
parse_errors_from_json() {
    local json_output="$1"
    local count=0
    if echo "$json_output" | grep -q '"summary"'; then
        local _raw
        _raw=$(echo "$json_output" | grep -o '"errors"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*$' | head -1)
        count="${_raw:-0}"
    fi
    printf '%d' "$count"
}

# ── Run @google/design.md lint on each changed file's diff ranges ─────────────
TOTAL_ERRORS=0
LINT_FAILED=0

# Group ranges by file and process
declare -A FILE_RANGES
while IFS=$'\t' read -r _fp _range; do
    [[ -z "$_fp" ]] && continue
    if [[ -v "FILE_RANGES[$_fp]" ]]; then
        FILE_RANGES["$_fp"]+=" $_range"
    else
        FILE_RANGES["$_fp"]="$_range"
    fi
done < "$_ranges_tmp"

# Per-file error counts (for regression detection)
declare -A FILE_ERRORS

for file_path in "${!FILE_RANGES[@]}"; do
    abs_file="$REPO_ROOT/$file_path"

    # Skip files that don't exist (deleted files)
    [[ ! -f "$abs_file" ]] && continue

    ranges="${FILE_RANGES[$file_path]}"

    # Build --lines arguments for each range
    LINES_ARGS=()
    for range in $ranges; do
        LINES_ARGS+=(--lines "$range")
    done

    # Run lint and capture JSON output
    # @google/design.md lint exits 0 even with errors — parse JSON for summary.errors
    lint_output=""
    lint_output=$(
        cd "$REPO_ROOT" && \
        npx --yes "@google/design.md@${DESIGN_MD_VERSION}" lint \
            --format json \
            --config "$DESIGN_NOTES_PATH" \
            "${LINES_ARGS[@]}" \
            "$file_path" 2>/dev/null
    ) || {
        # npx itself failed (network error, etc.) — fail-open
        echo "WARNING: npx invocation failed for $file_path — skipping (fail-open)." >&2
        FILE_ERRORS["$file_path"]=0
        continue
    }

    if [[ -z "$lint_output" ]]; then
        echo "INFO: No output from design.md lint for $file_path — treating as clean." >&2
        FILE_ERRORS["$file_path"]=0
        continue
    fi

    file_errors=$(parse_errors_from_json "$lint_output")
    FILE_ERRORS["$file_path"]="$file_errors"

    if [[ "$file_errors" -gt 0 ]]; then
        echo "FAIL: design.md lint found $file_errors error(s) in diff-touched lines of $file_path" >&2
        echo "$lint_output" >&2
        LINT_FAILED=1
    else
        echo "OK: $file_path — no design.md lint errors in diff-touched lines." >&2
    fi

    TOTAL_ERRORS=$(( TOTAL_ERRORS + file_errors ))
done

# ── Regression detection via diff subcommand (when HEAD~1 exists) ────────────
# Compare current lint error counts against HEAD~1 baseline to surface newly
# introduced violations. Informational only — does not change exit decision.
if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    for file_path in "${!FILE_ERRORS[@]}"; do
        current_errors="${FILE_ERRORS[$file_path]}"
        [[ "$current_errors" -eq 0 ]] && continue

        # Check if file existed at HEAD~1
        if ! git show "HEAD~1:$file_path" >/dev/null 2>&1; then
            # File is new — all errors are new by definition
            echo "REGRESSION: $file_path is new and has $current_errors error(s) in diff-touched lines." >&2
            continue
        fi

        ranges="${FILE_RANGES[$file_path]}"
        LINES_ARGS=()
        for range in $ranges; do
            LINES_ARGS+=(--lines "$range")
        done

        # Lint the HEAD~1 version in a temp file
        _baseline_tmp=$(mktemp /tmp/design-md-baseline.XXXXXX)
        git show "HEAD~1:$file_path" > "$_baseline_tmp" 2>/dev/null || true

        baseline_output=""
        baseline_output=$(
            cd "$REPO_ROOT" && \
            npx --yes "@google/design.md@${DESIGN_MD_VERSION}" lint \
                --format json \
                --config "$DESIGN_NOTES_PATH" \
                "${LINES_ARGS[@]}" \
                "$_baseline_tmp" 2>/dev/null
        ) || true

        rm -f "$_baseline_tmp"

        baseline_errors=0
        if [[ -n "$baseline_output" ]]; then
            baseline_errors=$(parse_errors_from_json "$baseline_output")
        fi

        if [[ "$current_errors" -gt "$baseline_errors" ]]; then
            delta=$(( current_errors - baseline_errors ))
            echo "REGRESSION: $file_path introduced $delta new error(s) compared to HEAD~1 (was $baseline_errors, now $current_errors)." >&2
        fi
    done
fi

# ── Exit decision ─────────────────────────────────────────────────────────────
if [[ "$LINT_FAILED" -eq 1 ]]; then
    echo "" >&2
    echo "design.md lint FAILED: $TOTAL_ERRORS error(s) found in diff-touched lines." >&2
    echo "Fix the design system violations above before committing." >&2
    exit 1
fi

echo "design.md lint passed: no errors in diff-touched lines." >&2
exit 0
