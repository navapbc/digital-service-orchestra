#!/usr/bin/env bash
# shellcheck disable=SC2317  # functions are invoked indirectly via the runner block at EOF
# shellcheck disable=SC2064  # trap intentionally expands $_T NOW so cleanup targets this fixture dir (same pattern as test-merge-to-main-spent-classifier.sh)
# tests/scripts/test-restage-hardening-unit.sh
#
# 3274 BEHAVIORAL unit tests for the two new _restage hardening helpers in
# merge-to-main-pr.sh (sourced in PR_LIB_MODE=1 over REAL git fixtures + a real
# lockdir on disk). These assert observable BEHAVIOR (the actually-chosen branch
# name, the function exit code, whether a lockdir was reclaimed) — NOT source-greps.
#
# Functions under test (sourced via PR_LIB_MODE=1):
#   _restage_pick_unused_fresh_name <src> [max]  — 3274 m2 (collision auto-retry)
#   _restage_branch_name_taken <name>            — 3274 m2 (no-clobber predicate)
#   _restage_acquire_lock <lockdir> [max_wait]   — 3274 m3 (PID-staleness recovery)
#
# Usage: bash tests/scripts/test-restage-hardening-unit.sh

set -uo pipefail

export GIT_CONFIG_COUNT=1  # isolation-ok: scoped to this test process
export GIT_CONFIG_KEY_0=commit.gpgsign  # isolation-ok: scoped to this test process
export GIT_CONFIG_VALUE_0=false  # isolation-ok: scoped to this test process

REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# Run a snippet inside a fresh git work tree with the script sourced in lib mode.
# $1=work-dir $2=snippet. Captures stdout; returns the snippet's exit code.
_run_in() {
    local work="$1" snippet="$2" wrapper
    wrapper="$(mktemp "${TMPDIR:-/tmp}/dso-3274-wrap.XXXXXX")"
    cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
PR_LIB_MODE=1 BRANCH="feat-x" source "$PR_SCRIPT" 2>/dev/null
$snippet
exit \$?
WRAP
    chmod +x "$wrapper"
    (
        cd "$work" || exit 99
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" bash "$wrapper"
    )
    local _ec=$?
    rm -f "$wrapper"
    return "$_ec"
}

# Build a minimal real local repo (no origin needed for the name-picker, which
# probes refs/heads + refs/remotes/origin via rev-parse).
_mk_repo() {
    local work="$1"
    (
        set -e
        git init -q -b main "$work"
        cd "$work"
        git config user.email t@t.local; git config user.name t
        echo base > base.txt; git add base.txt; git commit -q -m base
    ) >/dev/null 2>&1
}

# ===========================================================================
# m2 — fresh-name collision auto-retry.
# ===========================================================================

# No collision: the deterministic name is free → picker returns it verbatim.
t_pick_no_collision_returns_deterministic() {
    local _T _name
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    _name="$(_run_in "$_T/repo" "_restage_pick_unused_fresh_name feat-x 10")"
    assert_eq "t_pick_no_collision_returns_deterministic" "feat-x-restage2" "$_name"
}

# Deterministic name ALREADY EXISTS (interrupted prior re-stage) → picks the
# NEXT-unused name. Assert the actually-created name, not a grep.
t_pick_collision_picks_next_unused() {
    local _T _name
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    ( cd "$_T/repo" && git branch -q feat-x-restage2 ) >/dev/null 2>&1
    _name="$(_run_in "$_T/repo" "_restage_pick_unused_fresh_name feat-x 10")"
    assert_eq "t_pick_collision_picks_next_unused" "feat-x-restage2-2" "$_name"
}

# Collision on a REMOTE ref (origin/<name>) is honored too (no-clobber spans origin).
t_pick_collision_remote_ref_honored() {
    local _T _name
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    # Synthesize a remote-tracking ref without a network: write refs/remotes/origin/feat-x-restage2.
    ( cd "$_T/repo" && git update-ref refs/remotes/origin/feat-x-restage2 HEAD ) >/dev/null 2>&1
    _name="$(_run_in "$_T/repo" "_restage_pick_unused_fresh_name feat-x 10")"
    assert_eq "t_pick_collision_remote_ref_honored" "feat-x-restage2-2" "$_name"
}

# All N candidates collide → clean abort (rc 1, empty stdout). No clobber.
t_pick_all_collide_aborts() {
    local _T _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    # Occupy the deterministic name + its first two suffix increments, with max=3.
    (
        cd "$_T/repo"
        git branch -q feat-x-restage2
        git branch -q feat-x-restage2-2
        git branch -q feat-x-restage2-3
    ) >/dev/null 2>&1
    _out="$(_run_in "$_T/repo" "_restage_pick_unused_fresh_name feat-x 3; echo RC=\$?")"
    _ec="$(printf '%s' "$_out" | grep -o 'RC=[0-9]*' | head -n1)"
    assert_eq "t_pick_all_collide_aborts_rc1" "RC=1" "$_ec"
    # No branch name echoed before the RC marker (clean abort, no clobber).
    local _picked; _picked="$(printf '%s' "$_out" | grep -v '^RC=' | head -n1)"
    assert_eq "t_pick_all_collide_aborts_no_name" "" "$_picked"
}

# A trailing-integer source name increments the integer (deterministic-name path)
# and the collision retry continues incrementing from there.
t_pick_numeric_source_increments() {
    local _T _name
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    ( cd "$_T/repo" && git branch -q feat-3 ) >/dev/null 2>&1   # occupy the deterministic -3
    # source 'feat-2' → deterministic 'feat-3' (taken) → next 'feat-4'.
    _name="$(_run_in "$_T/repo" "_restage_pick_unused_fresh_name feat-2 10")"
    assert_eq "t_pick_numeric_source_increments" "feat-4" "$_name"
}

# ===========================================================================
# m3 — mkdir-lock staleness / PID recovery.
# ===========================================================================

# No lock present → acquires (rc 0) and records our PID in the lockdir.
t_lock_no_lock_acquires() {
    local _T _ec _pid
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    local _ld="$_T/lock.d"
    _run_in "$_T/repo" "_restage_acquire_lock '$_ld' 3"; _ec=$?
    assert_eq "t_lock_no_lock_acquires_rc0" "0" "$_ec"
    # The lockdir + a numeric pid file must exist after acquire.
    [[ -d "$_ld" ]] && _pid="$(cat "$_ld/pid" 2>/dev/null || true)" || _pid=""
    local _isnum="no"; [[ "$_pid" =~ ^[0-9]+$ ]] && _isnum="yes"
    assert_eq "t_lock_no_lock_records_pid" "yes" "$_isnum"
}

# STALE lock (recorded PID is provably DEAD) → reclaimed + proceeds (rc 0).
# Use a PID that is guaranteed dead: spawn a trivial child, reap it, reuse its PID.
t_lock_stale_dead_pid_reclaims() {
    local _T _ec _dead
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    local _ld="$_T/lock.d"
    # Pre-create a held lockdir whose recorded PID is dead.
    ( sleep 0.01 ) & _dead=$!; wait "$_dead" 2>/dev/null || true
    mkdir -p "$_ld"; printf '%s\n' "$_dead" > "$_ld/pid"
    # max_wait=2: if reclaim did NOT happen, the call would spin 2s then abort (rc 1).
    _run_in "$_T/repo" "_restage_acquire_lock '$_ld' 2"; _ec=$?
    assert_eq "t_lock_stale_dead_pid_reclaims_rc0" "0" "$_ec"
}

# LIVE lock (recorded PID is alive) → still BLOCKS (spin then abort rc 1).
# Use a long-lived background sleep as the live holder; record its PID.
t_lock_live_pid_still_blocks() {
    local _T _ec _live
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    local _ld="$_T/lock.d"
    sleep 30 & _live=$!
    mkdir -p "$_ld"; printf '%s\n' "$_live" > "$_ld/pid"
    # max_wait=2: a live holder must NOT be reclaimed → spin 2s → abort rc 1.
    _run_in "$_T/repo" "_restage_acquire_lock '$_ld' 2"; _ec=$?
    kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
    assert_eq "t_lock_live_pid_still_blocks_rc1" "1" "$_ec"
}

# FAIL-SAFE: indeterminate liveness (missing pid file) → do NOT reclaim → blocks.
t_lock_indeterminate_pid_failsafe_blocks() {
    local _T _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _mk_repo "$_T/repo"
    local _ld="$_T/lock.d"
    mkdir -p "$_ld"   # held lockdir with NO pid file → liveness indeterminate
    _run_in "$_T/repo" "_restage_acquire_lock '$_ld' 2"; _ec=$?
    assert_eq "t_lock_indeterminate_pid_failsafe_blocks_rc1" "1" "$_ec"
}

# Run all.
t_pick_no_collision_returns_deterministic
t_pick_collision_picks_next_unused
t_pick_collision_remote_ref_honored
t_pick_all_collide_aborts
t_pick_numeric_source_increments
t_lock_no_lock_acquires
t_lock_stale_dead_pid_reclaims
t_lock_live_pid_still_blocks
t_lock_indeterminate_pid_failsafe_blocks

print_summary
