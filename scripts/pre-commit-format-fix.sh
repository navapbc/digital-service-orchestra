#!/usr/bin/env bash
# lockpick-workflow/scripts/pre-commit-format-fix.sh
#
# Pre-commit hook that auto-fixes formatting on staged Python files and re-stages them.
#
# Unlike `make format-check` (which uses `--check` and fails on unformatted code),
# this script:
#   1. Identifies staged Python files
#   2. Runs ruff import sorting + formatting (auto-fix mode)
#   3. Re-stages the fixed files so the commit includes the formatted versions
#   4. Exits 0 on successful auto-fix (not "Failed - files were modified")
#
# This prevents the pre-commit framework from reporting misleading "Failed" status
# when formatting is the only issue, and preserves the staging area across the
# auto-fix cycle.
#
# Usage (in .pre-commit-config.yaml):
#   entry: ./scripts/pre-commit-wrapper.sh format-fix 30 "./lockpick-workflow/scripts/pre-commit-format-fix.sh"
#
# Exit codes:
#   0  — all staged Python files are properly formatted (possibly after auto-fix)
#   1  — ruff encountered an error it could not auto-fix (e.g., syntax error)

set -uo pipefail

# ── Resolve paths ─────────────────────────────────────────────────────────────
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
APP_DIR="$REPO_ROOT/app"

# ── Resolve ruff binary ──────────────────────────────────────────────────────
# Look for ruff in: PATH, app venv, poetry run (in order of speed).
RUFF=""
if command -v ruff >/dev/null 2>&1; then
    RUFF="ruff"
elif [[ -x "$APP_DIR/.venv/bin/ruff" ]]; then
    RUFF="$APP_DIR/.venv/bin/ruff"
elif (cd "$APP_DIR" && poetry run ruff --version) >/dev/null 2>&1; then
    # Use a function wrapper for poetry run
    RUFF="poetry-run-ruff"
fi

# Helper: run ruff with resolved binary
run_ruff() {
    if [[ "$RUFF" == "poetry-run-ruff" ]]; then
        (cd "$APP_DIR" && poetry run ruff "$@")
    elif [[ -n "$RUFF" ]]; then
        "$RUFF" "$@"
    else
        echo "format-fix: ruff not found" >&2
        return 1
    fi
}

# ── Collect staged Python files ───────────────────────────────────────────────
# Use --diff-filter=ACMR to include Added, Copied, Modified, Renamed files.
# Exclude deleted files (D) since they no longer exist on disk.
STAGED_PY_FILES=()
while IFS= read -r file; do
    [[ -n "$file" ]] && STAGED_PY_FILES+=("$file")
done < <(git diff --cached --name-only --diff-filter=ACMR -- '*.py')

# Nothing to do if no Python files are staged
if [[ ${#STAGED_PY_FILES[@]} -eq 0 ]]; then
    exit 0
fi

# ── Auto-fix formatting on staged files ───────────────────────────────────────
# Run ruff import sorting (--fix) and ruff format on each staged file.
# Files may be under app/src/, app/tests/, scripts/, tests/, or lockpick-workflow/scripts/.
FIX_FAILED=0
for file in "${STAGED_PY_FILES[@]}"; do
    abs_file="$REPO_ROOT/$file"

    # Skip files that don't exist (e.g., submodule references)
    [[ -f "$abs_file" ]] || continue

    # Determine the working directory for ruff (app/ for app files, repo root otherwise)
    if [[ "$file" == app/* ]]; then
        WORK_DIR="$APP_DIR"
        REL_FILE="${file#app/}"
    else
        WORK_DIR="$REPO_ROOT"
        REL_FILE="$file"
    fi

    # Run import sorting fix, then format
    if ! (cd "$WORK_DIR" && run_ruff check --select I --fix "$REL_FILE" 2>/dev/null && run_ruff format "$REL_FILE" 2>/dev/null); then
        echo "format-fix: failed to format $file (syntax error or ruff issue)" >&2
        FIX_FAILED=1
    fi
done

# ── Re-stage the fixed files ─────────────────────────────────────────────────
# Re-add all staged Python files so the index reflects the formatted versions.
# This preserves other staged changes and ensures the commit includes the fixes.
for file in "${STAGED_PY_FILES[@]}"; do
    abs_file="$REPO_ROOT/$file"
    [[ -f "$abs_file" ]] && git add "$abs_file"
done

# ── Verify formatting is clean ────────────────────────────────────────────────
# After auto-fix, verify all staged files pass the check.
# This catches any files that ruff couldn't fully fix.
VERIFY_FAILED=0
for file in "${STAGED_PY_FILES[@]}"; do
    abs_file="$REPO_ROOT/$file"
    [[ -f "$abs_file" ]] || continue

    if [[ "$file" == app/* ]]; then
        WORK_DIR="$APP_DIR"
        REL_FILE="${file#app/}"
    else
        WORK_DIR="$REPO_ROOT"
        REL_FILE="$file"
    fi

    if ! (cd "$WORK_DIR" && run_ruff check --select I "$REL_FILE" >/dev/null 2>&1 && run_ruff format --check "$REL_FILE" >/dev/null 2>&1); then
        echo "format-fix: $file still has formatting issues after auto-fix" >&2
        VERIFY_FAILED=1
    fi
done

if [[ $FIX_FAILED -ne 0 ]] || [[ $VERIFY_FAILED -ne 0 ]]; then
    exit 1
fi

exit 0
