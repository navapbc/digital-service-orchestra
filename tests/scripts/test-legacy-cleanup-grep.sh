#!/usr/bin/env bash
# tests/scripts/test-legacy-cleanup-grep.sh
# AP-5 fitness function: enforces zero legacy config key references outside the allowlist.
#
# Contract under test (future state after cleanup):
#   grep -rln '<legacy-key-pattern>' plugins/dso/skills/ plugins/dso/scripts/
#           plugins/dso/hooks/ .github/workflows/
#     — after excluding the allowlist, the output must be EMPTY.
#
# RED state: ~31 files still have legacy refs. This test FAILS until the cleanup
#            task removes them (story bb8a-a882-64a7-4c6c, task 16a9-dd52-c7f2-4ed5).
#
# Legacy keys under scrutiny:
#   merge.strategy, enforcement.strategy, worktree.isolation_enabled,
#   attribution.enabled, DSO_SPRINT_MODE, MERGE_TO_MAIN_PR_MODE
#
# Allowlist (legitimately reference legacy keys):
#   - plugins/dso/scripts/migrate-dso-workflow-config.sh  (the migrator)
#   - plugins/dso/scripts/read-config.sh                  (the compat shim)
#   - CLAUDE.md, docs/adr/**, plugins/dso/docs/**         (reference/historical docs)
#   - tests/**                                             (separate scope)
#
# Usage: bash tests/scripts/test-legacy-cleanup-grep.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-legacy-cleanup-grep.sh ==="

# ── test_no_legacy_key_refs_in_scope_files ────────────────────────────────────
# Given: the live repo at REPO_ROOT
# When:  grep scans the four scope dirs for legacy config key patterns,
#        excluding the allowlist entries
# Then:  the result is EMPTY — no files outside the allowlist still reference
#        legacy keys
#
# RED: this FAILS now because many files in skills/, scripts/, hooks/, and
#      .github/workflows/ still reference the legacy keys. That is expected
#      and correct — this test becomes GREEN only after cleanup is complete.
test_no_legacy_key_refs_in_scope_files() {
    local legacy_pattern='merge\.strategy\|enforcement\.strategy\|worktree\.isolation_enabled\|attribution\.enabled\|DSO_SPRINT_MODE\|MERGE_TO_MAIN_PR_MODE'

    # Scope directories to scan
    local scope_dirs=(
        "$REPO_ROOT/plugins/dso/skills"
        "$REPO_ROOT/plugins/dso/scripts"
        "$REPO_ROOT/plugins/dso/hooks"
        "$REPO_ROOT/.github/workflows"
    )

    # Build the grep command output, applying allowlist exclusions.
    # Allowlist exclusions:
    #   1. migrate-dso-workflow-config.sh — the migrator script itself
    #   2. read-config.sh — the compat shim
    #   3. plugins/dso/docs/ — reference/historical docs shipped with the plugin
    # Note: CLAUDE.md, docs/adr/, and tests/ are outside the scope dirs and
    # therefore never hit by the scoped grep.
    local hits
    hits=$(grep -rln "$legacy_pattern" "${scope_dirs[@]}" 2>/dev/null \
        | grep -v 'plugins/dso/scripts/migrate-dso-workflow-config\.sh' \
        | grep -v 'plugins/dso/scripts/read-config\.sh' \
        | grep -v 'plugins/dso/docs/' \
        || true)

    if [[ -z "$hits" ]]; then
        (( ++PASS ))
        echo "test_no_legacy_key_refs_in_scope_files ... PASS"
    else
        (( ++FAIL ))
        printf "FAIL: test_no_legacy_key_refs_in_scope_files\n" >&2
        printf "  Legacy config key references found outside the allowlist.\n" >&2
        printf "  These files must be updated to use the new config key names:\n" >&2
        printf "%s\n" "$hits" | sed 's/^/    /' >&2
    fi
}

test_no_legacy_key_refs_in_scope_files

print_summary
