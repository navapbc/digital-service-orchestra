#!/usr/bin/env bash
# .claude/hooks/pre-commit/shellcheck.sh
# Pre-commit hook: run shellcheck on staged .sh files.
#
# Project-local only — not distributed with the DSO plugin.
# Gracefully skips if shellcheck is not installed.
#
# Exit codes:
#   0 — All staged .sh files pass shellcheck (or shellcheck not available)
#   1 — One or more staged .sh files have shellcheck violations

set -uo pipefail

# ── Graceful skip if shellcheck not installed ────────────────────────────────
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck: not installed — skipping" >&2
    exit 0
fi

# ── Collect staged .sh files ─────────────────────────────────────────────────
_staged=()
while IFS= read -r _f; do
    [[ -n "$_f" ]] || continue
    # Only check files that still exist (not deleted)
    [[ -f "$_f" ]] || continue
    _staged+=("$_f")
done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep '\.sh$' || true)

if [[ ${#_staged[@]} -eq 0 ]]; then
    exit 0
fi

# ── Run shellcheck on each staged file ───────────────────────────────────────
_violations=0
for _file in "${_staged[@]}"; do
    if ! shellcheck --severity=info "$_file" 2>&1; then
        (( _violations++ )) || true
    fi
done

if [[ "$_violations" -gt 0 ]]; then
    echo "" >&2
    echo "shellcheck: $_violations file(s) failed. Fix violations before committing." >&2
    exit 1
fi

exit 0
