#!/usr/bin/env bash
set -uo pipefail
# scripts/check-gate-tier-headers.sh
# F-02 drift detection: every hook under plugins/dso/hooks/ must declare its
# tier via a "# DSO-GATE-TIER: A|B|C" header comment near the top of the file.
#
# The tier governs how the hook behaves on infrastructure failure — see
# plugins/dso/docs/HOOKS-REFERENCE.md "Gate-tier doctrine" for the contract.
#
# Scope:
#   Hooks annotated with "# hook-boundary: enforcement" — these are the
#   safety-critical hooks whose verdicts route execution and where the
#   gate-tier doctrine (Tier A / B / C) actually matters.
#
# Out of scope (lint does not check):
#   - Non-enforcement hooks (dispatchers, fix-bug-skill-directive,
#     record-test-status, etc.) — these are DX/lifecycle hooks where the
#     tier classification is informational. Annotating them is a follow-up
#     audit (see remediation plan F-02 "Scope note").
#   - Library files under hooks/lib/ — those are sourced by hooks and don't
#     have their own gate semantics.
#
# Usage:
#   check-gate-tier-headers.sh [file ...]
#
# Exit codes:
#   0 — all hooks declare a tier
#   1 — at least one hook missing the declaration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Pattern: header must contain a DSO-GATE-TIER declaration ──────────────────
# Accept: # DSO-GATE-TIER: A | B | C | N/A
# The declaration must appear in the first 20 lines (header area) of the file.
_PATTERN='^\s*#\s*DSO-GATE-TIER:\s*(A|B|C|N/A)\b'

# ── Determine target files ────────────────────────────────────────────────────
# When called with explicit files (e.g., from pre-commit with staged files),
# only check files that are themselves enforcement hooks. When called with no
# args, find all enforcement-annotated hooks under plugins/dso/hooks/.
_files=()
if [[ $# -gt 0 ]]; then
    # Filter explicit args to enforcement-annotated hooks only.
    for _f in "$@"; do
        if [[ -f "$_f" ]] && head -n 5 "$_f" 2>/dev/null | grep -q "hook-boundary: enforcement"; then
            _files+=("$_f")
        fi
    done
else
    while IFS= read -r -d '' _f; do
        if head -n 5 "$_f" 2>/dev/null | grep -q "hook-boundary: enforcement"; then
            _files+=("$_f")
        fi
    done < <(find "$PLUGIN_DIR/hooks" -maxdepth 1 -type f -name '*.sh' -print0)
fi

# ── Scan ──────────────────────────────────────────────────────────────────────
_missing=0
_missing_files=()
for _f in "${_files[@]}"; do
    [[ -f "$_f" ]] || continue
    # Look in the first 20 lines.
    if ! head -n 20 "$_f" 2>/dev/null | grep -qE "$_PATTERN"; then
        _missing=$((_missing + 1))
        _missing_files+=("$_f")
    fi
done

# ── Report ────────────────────────────────────────────────────────────────────
if [[ "$_missing" -gt 0 ]]; then
    echo "" >&2
    echo "check-gate-tier-headers: $_missing hook file(s) missing tier declaration." >&2
    echo "" >&2
    for _f in "${_missing_files[@]}"; do
        echo "  $_f" >&2
    done
    echo "" >&2
    echo "Each hook under plugins/dso/hooks/ must declare its tier in the file" >&2
    echo "header via a '# DSO-GATE-TIER: A|B|C' (or 'N/A' for non-hook libraries)" >&2
    echo "comment within the first 20 lines. See plugins/dso/docs/HOOKS-REFERENCE.md" >&2
    echo "'Gate-tier doctrine' section." >&2
    exit 1
fi

echo "check-gate-tier-headers: all hooks declare a tier."
exit 0
