#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-resume-freshness.sh
# Structural tests for multi-session hardening (cb31-3552):
#   --resume detects when origin/main has advanced since the state file was
#   created and resets post-sync phases (sync, merge, version_bump, push) so
#   they re-run against the fresh tip.
#
# Root cause this hardens: when a long-paused --resume executes against a
# state file recorded before origin/main advanced, completed_phases would
# cause sync/merge/version_bump to be skipped. The self-healing push handles
# the immediate push consequence, but the freshness check makes the
# staleness explicit and avoids skipping phases that need re-validation
# against the new tip.
#
# Per behavioral testing standard Rule 5 (instruction files): tests assert
# the structural boundary of the script — that the freshness logic exists
# and is wired into the right pipeline location.
#
# Usage: bash tests/scripts/test-merge-to-main-resume-freshness.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"
HELPERS="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

if [[ ! -f "$MERGE_SCRIPT" ]]; then
    echo "SKIP: merge-to-main-direct.sh not found at $MERGE_SCRIPT"
    exit 0
fi
if [[ ! -f "$HELPERS" ]]; then
    echo "SKIP: merge-helpers.sh not found at $HELPERS"
    exit 0
fi

# ── Extract the --resume block from the script ────────────────────────────────
_RESUME_BLOCK=$(awk '
    /if \[\[ "\$_CLI_RESUME" == "true" \]\]; then/ { found=1; depth=1; print; next }
    found {
        print
        if (/^[[:space:]]*if /) depth++
        if (/^[[:space:]]*fi$/ || /^[[:space:]]*fi[[:space:]]/) {
            depth--
            if (depth == 0) { found=0 }
        }
    }
' "$MERGE_SCRIPT" 2>/dev/null)

# Fail-fast if extraction silently produced nothing — otherwise every grep-based
# test below would assert against an empty string and falsely pass when the
# --resume block has been removed or its signature changed (llm-review f-j-2/4).
if [[ -z "$_RESUME_BLOCK" ]]; then
    echo "FATAL: failed to extract --resume block from $MERGE_SCRIPT — script structure may have changed" >&2
    echo "       Expected pattern: 'if [[ \"\$_CLI_RESUME\" == \"true\" ]]; then'" >&2
    exit 1
fi

# ============================================================
# test_state_init_records_origin_main_sha (cb31-3552)
#
# _state_init in merge-helpers.sh must record origin_main_sha in the initial
# state-file skeleton so the --resume freshness check has a reference SHA.
# ============================================================
test_state_init_records_origin_main_sha() {
    local found=0
    grep -q 'origin_main_sha' "$HELPERS" 2>/dev/null && found=1 || true
    assert_eq "state-file skeleton records origin_main_sha (cb31-3552)" "1" "$found"
}

# ============================================================
# test_resume_block_reads_origin_main_sha (cb31-3552)
#
# The --resume block must read the recorded origin_main_sha from the state
# file before iterating phases — otherwise it cannot detect that origin
# advanced past the recorded reference.
# ============================================================
test_resume_block_reads_origin_main_sha() {
    local found=0
    grep -q "origin_main_sha" <<< "$_RESUME_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "resume block reads origin_main_sha from state (cb31-3552)" "1" "$found"
}

# ============================================================
# test_resume_block_uses_merge_base_ancestor_check (cb31-3552)
#
# Staleness is decided by "recorded SHA is an ancestor of current
# origin/main" — i.e., origin advanced PAST the recorded SHA. The check
# must use `git merge-base --is-ancestor` rather than a string equality
# comparison so that an unrelated origin/main reset is handled correctly.
# ============================================================
test_resume_block_uses_merge_base_ancestor_check() {
    local found=0
    grep -q 'merge-base --is-ancestor' <<< "$_RESUME_BLOCK" 2>/dev/null && found=1 || true
    assert_eq "resume block uses merge-base --is-ancestor for staleness (cb31-3552)" "1" "$found"
}

# ============================================================
# test_resume_block_resets_post_sync_phases_on_stale (cb31-3552)
#
# On stale state, the freshness check must remove sync/merge/version_bump/push
# from completed_phases so the existing phase-iteration loop re-runs them.
# ============================================================
test_resume_block_resets_post_sync_phases_on_stale() {
    local found=0
    # Look for the literal phase-name set in the reset python snippet
    grep -E "'sync'.*'merge'.*'version_bump'.*'push'" <<< "$_RESUME_BLOCK" >/dev/null 2>&1 && found=1 || true
    assert_eq "resume block resets {sync,merge,version_bump,push} on stale state (cb31-3552)" "1" "$found"
}

# ============================================================
# test_resume_block_tolerates_missing_recorded_sha (cb31-3552)
#
# Legacy state files (created before this hardening landed) have no
# origin_main_sha field. The check must guard with a non-empty test so
# legacy state files are not erroneously flagged as stale.
# ============================================================
test_resume_block_tolerates_missing_recorded_sha() {
    local found=0
    # Look for an [[ -n "$_RECORDED_..." ]] or similar non-empty guard
    # shellcheck disable=SC2016  # intentional: matching literal $_RECORDED_ORIGIN_SHA in script source
    grep -E '\[\[ -n "\$_RECORDED_ORIGIN_SHA" \]\]' <<< "$_RESUME_BLOCK" >/dev/null 2>&1 && found=1 || true
    assert_eq "resume freshness check guards on non-empty recorded SHA (cb31-3552)" "1" "$found"
}

# ============================================================
# test_resume_freshness_runs_before_phase_iteration (cb31-3552)
#
# The freshness check must run before the phase iteration loop, so that
# resetting completed_phases is visible to the loop. Verify by ordering of
# substrings within the extracted resume block.
# ============================================================
test_resume_freshness_runs_before_phase_iteration() {
    local freshness_line iter_line
    freshness_line=$(grep -n 'merge-base --is-ancestor' <<< "$_RESUME_BLOCK" | head -1 | cut -d: -f1)
    # shellcheck disable=SC2016  # intentional: matching literal ${_ALL_PHASES[@]} in script source
    iter_line=$(grep -n 'for _pname in "${_ALL_PHASES\[@\]}"' <<< "$_RESUME_BLOCK" | head -1 | cut -d: -f1)
    if [[ -n "$freshness_line" && -n "$iter_line" && "$freshness_line" -lt "$iter_line" ]]; then
        assert_eq "freshness check runs before phase iteration (cb31-3552)" "ok" "ok"
    else
        assert_eq "freshness check runs before phase iteration (cb31-3552)" "ok" "freshness=$freshness_line iter=$iter_line"
    fi
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_state_init_records_origin_main_sha
test_resume_block_reads_origin_main_sha
test_resume_block_uses_merge_base_ancestor_check
test_resume_block_resets_post_sync_phases_on_stale
test_resume_block_tolerates_missing_recorded_sha
test_resume_freshness_runs_before_phase_iteration

print_summary
