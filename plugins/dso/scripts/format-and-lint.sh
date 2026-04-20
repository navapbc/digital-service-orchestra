#!/usr/bin/env bash
set -uo pipefail
# scripts/format-and-lint.sh — Combined format-check + lint pre-commit hook
#
# Pre-commit: checks only staged .py files for fast feedback (~3-5s).
# Pre-push:   full-tree checks run via the pre-push-lint hook in .pre-commit-config.yaml.
#
# Usage (invoked by .pre-commit-config.yaml via pre-commit-wrapper.sh):
#   ./scripts/pre-commit-wrapper.sh format-and-lint 15 "scripts/format-and-lint.sh"
#
# Debug commands (full-tree, same as pre-push):
#   cd app && PY_RUN_APPROACH=local make format-check
#   cd app && PY_RUN_APPROACH=local make lint
#
# Exit codes:
#   0 — all checks pass
#   non-zero — first failing check's exit code
#
# Stack: intentionally Python-only (pre-commit hook for staged .py files).
# For polyglot projects, configure format/lint in .pre-commit-config.yaml
# per language. commands.format and commands.lint are not used here.

set -uo pipefail

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# Collect staged .py files (relative to repo root)
STAGED_PY=$(cd "$REPO_ROOT" && git diff --cached --name-only --diff-filter=ACM -- '*.py' 2>/dev/null || true)

if [[ -z "$STAGED_PY" ]]; then
    # No staged Python files — nothing to check
    exit 0
fi

# Build file list (absolute paths)
FILES=()
while IFS= read -r f; do
    [[ -n "$f" ]] && FILES+=("$REPO_ROOT/$f")
done <<< "$STAGED_PY"

if [[ ${#FILES[@]} -eq 0 ]]; then
    exit 0
fi

# Run ruff format check and lint on staged files only
cd "$REPO_ROOT/app" || exit 1

PY_RUN_APPROACH=local poetry run ruff format --check "${FILES[@]}" || exit $?
PY_RUN_APPROACH=local poetry run ruff check "${FILES[@]}" || exit $?
