#!/usr/bin/env bash
# scripts/check-hooks-doc.sh
# Validate HOOKS-REFERENCE.md stays in sync with the filesystem (R10 follow-up).
#
# Mechanism: every wrapper `*.sh` file directly under `${CLAUDE_PLUGIN_ROOT}/hooks/`
# (excluding lib/, dispatchers/, rollback/, and the pre-commit-* files which
# are listed in the pre-commit section of HOOKS-REFERENCE.md) should be
# documented by name in HOOKS-REFERENCE.md.
#
# This is a one-directional check (file -> doc). The opposite direction
# (documented -> file) is not validated because HOOKS-REFERENCE.md
# legitimately references lib functions and dispatchers that are not
# top-level wrapper files.
#
# This script:
#   1. Enumerates wrapper files under hooks/ (excluding internal dirs).
#   2. For each wrapper, greps HOOKS-REFERENCE.md for the basename.
#   3. Reports each undocumented wrapper.
#
# Usage:
#   scripts/check-hooks-doc.sh
#
# Exit codes:
#   0 — Every wrapper is documented
#   1 — One or more wrappers are undocumented
#   2 — Required input missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$_PLUGIN_ROOT/hooks"
HOOKS_MD="$_PLUGIN_ROOT/docs/HOOKS-REFERENCE.md"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "check-hooks-doc: FATAL: hooks/ dir not found at $HOOKS_DIR" >&2
    exit 2
fi
if [[ ! -f "$HOOKS_MD" ]]; then
    echo "check-hooks-doc: FATAL: HOOKS-REFERENCE.md not found at $HOOKS_MD" >&2
    exit 2
fi

# ── Enumerate wrapper files ───────────────────────────────────────────────────

_wrappers=$(mktemp /tmp/check-hooks-doc-wrappers.XXXXXX)
_undocumented=$(mktemp /tmp/check-hooks-doc-undoc.XXXXXX)

# shellcheck disable=SC2154
trap '_rc=$?; rm -f "$_wrappers" "$_undocumented"; exit $_rc' EXIT

find "$HOOKS_DIR" -maxdepth 1 -type f -name '*.sh' \
    -exec basename {} \; \
    | sort -u > "$_wrappers"

if [[ ! -s "$_wrappers" ]]; then
    echo "check-hooks-doc: FATAL: no wrapper .sh files found under $HOOKS_DIR" >&2
    exit 2
fi

# ── Check each wrapper is documented ──────────────────────────────────────────

while IFS= read -r _wrapper; do
    # Documentation may reference the wrapper as `foo.sh` (filename with .sh)
    # or `foo` (basename in section headers / prose). Accept either form.
    _basename="${_wrapper%.sh}"
    if ! grep -qF "$_wrapper" "$HOOKS_MD" && ! grep -qF "$_basename" "$HOOKS_MD"; then
        printf '%s\n' "$_wrapper" >> "$_undocumented"
    fi
done < "$_wrappers"

_undoc_count=$(wc -l < "$_undocumented" 2>/dev/null | tr -d ' ')

if [[ "${_undoc_count:-0}" -eq 0 ]]; then
    exit 0
fi

echo "check-hooks-doc: $_undoc_count hook wrapper(s) under hooks/ are NOT documented in HOOKS-REFERENCE.md:" >&2
echo "" >&2
while IFS= read -r _wrapper; do
    echo "  - hooks/$_wrapper" >&2
done < "$_undocumented"
echo "" >&2
echo "  Fix: add a row to HOOKS-REFERENCE.md for each undocumented wrapper, OR delete" >&2
echo "  the file if the hook is no longer needed." >&2

exit 1
