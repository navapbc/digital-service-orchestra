#!/usr/bin/env bash
# shellcheck disable=SC2317  # functions are invoked indirectly via the runner block at EOF
# shellcheck disable=SC2064  # trap intentionally expands $_T NOW so cleanup targets this fixture dir (same pattern as test-merge-to-main-spent-classifier.sh)
# tests/scripts/test-restage-execute-integration.sh
#
# 3274 m1 — INTEGRATION tests for the DESTRUCTIVE DSO_RESTAGE_EXECUTE=1 path of
# _restage_execute (merge-to-main-pr.sh), previously gated + unit-uncovered.
#
# These drive the full git/gh glue end-to-end against REAL LOCAL FIXTURES ONLY:
#   * a real `git init` work tree whose `origin` remote is a LOCAL BARE repo
#     (the fixture origin — NEVER the real origin),
#   * a PATH-shimmed `gh` STUB for the forge-proof PR1/PR2 reads used by
#     _restage_staged_ref_safe_to_delete,
#   * GIT_CONFIG_GLOBAL/SYSTEM neutralized + a per-fixture HOME so nothing
#     touches the real repo, real origin, or the developer's git config.
#
# NO real `gh`, no real push, no network — every git/gh op targets the bare
# fixture under $_T. The script is sourced in PR_LIB_MODE=1 so _restage_execute
# is callable directly. Behavioral assertions (worktree branch, ref existence
# on the bare origin, fresh-branch presence/absence) — NOT source-greps.
#
#   I1 happy path  — clean rebase onto origin/main, force-with-lease push of the
#                    fresh branch to the BARE origin, staged-ref delete ONLY when
#                    forge-proof-safe (PR1=MERGED, no live PR2).
#   I2 rebase conflict — DD5 rollback: worktree restored to original branch, the
#                    minted fresh branch deleted, nothing pushed.
#   I3 push failure    — DD5 rollback: same restoration; origin made unwritable.
#   I4 unsafe-delete   — happy push BUT PR1 not MERGED → staged ref PRESERVED.
#
# Usage: bash tests/scripts/test-restage-execute-integration.sh

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_COUNT=1  # isolation-ok: scoped to this test process
export GIT_CONFIG_KEY_0=commit.gpgsign  # isolation-ok: scoped to this test process
export GIT_CONFIG_VALUE_0=false  # isolation-ok: scoped to this test process

REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# _build_fixture <tmpdir> <conflict_mode>
#   conflict_mode: clean | conflict
#     clean    — feat-x touches a DIFFERENT file than the advancing origin/main
#                commit, so the rebase applies cleanly.
#     conflict — feat-x and origin/main edit the SAME line, forcing a rebase
#                conflict (DD5 rollback path).
#
# Topology: bare origin + work clone; origin/main advanced beyond the point
# feat-x branched from; feat-x carries a unique (non-patch-equivalent) commit so
# the empty-fresh-branch no-op guard does NOT short-circuit. A 'staged-feat-x'
# ref is also pushed to the bare origin so the staged-ref delete path is exercisable.
# Echoes the work-tree path on stdout.
# ---------------------------------------------------------------------------
SRC_BRANCH="feat-x"
STAGED_REF="staged-feat-x"

_build_fixture() {
    local tmpdir="$1" conflict_mode="$2"
    local origin="$tmpdir/origin.git" work="$tmpdir/work"
    local real_git; real_git=$(command -v git)
    (
        set -e
        "$real_git" init -q --bare "$origin"
        "$real_git" init -q -b main "$work"
        cd "$work"
        "$real_git" config user.email t@t.local; "$real_git" config user.name t
        echo base > base.txt
        if [[ "$conflict_mode" == "conflict" ]]; then echo seed > shared.txt; "$real_git" add shared.txt; fi
        "$real_git" add base.txt; "$real_git" commit -q -m base
        "$real_git" remote add origin "$origin"
        "$real_git" push -q origin main

        # feat-x branches from base, carries a UNIQUE commit (so >0 unmatched).
        "$real_git" checkout -q -b "$SRC_BRANCH"
        if [[ "$conflict_mode" == "conflict" ]]; then
            echo feature-edit > shared.txt; "$real_git" add shared.txt; "$real_git" commit -q -m feat-conflict
        else
            echo feat > feature.txt; "$real_git" add feature.txt; "$real_git" commit -q -m feat-clean
        fi
        "$real_git" push -q origin "$SRC_BRANCH"
        # Stage a 'staged-feat-x' ref on origin (the orphaned staged ref candidate).
        "$real_git" push -q origin "${SRC_BRANCH}:${STAGED_REF}"

        # origin/main advances beyond base.
        "$real_git" checkout -q main
        if [[ "$conflict_mode" == "conflict" ]]; then
            echo main-edit > shared.txt; "$real_git" add shared.txt; "$real_git" commit -q -m main-advance-conflict
        else
            echo advanced > advanced.txt; "$real_git" add advanced.txt; "$real_git" commit -q -m main-advance-clean
        fi
        "$real_git" push -q origin main

        # Land on feat-x as the "original checkout" the executor must restore on rollback.
        "$real_git" checkout -q "$SRC_BRANCH"
        "$real_git" fetch -q origin 2>/dev/null || true
    ) >/dev/null 2>&1
    echo "$work"
}

# gh stub: only the forge-proof PR-state reads matter to the executor here, but
# the executor reads PR1/PR2 via DSO_RESTAGE_PR1_STATE / _PR2_STATE overrides in
# these tests, so the stub just needs to exist + answer --version and never make
# a network call. Any `gh` invocation that is NOT a known read exits 0 (no-op).
_install_gh_stub() {
    local bin="$1"; mkdir -p "$bin"
    cat > "$bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  *) exit 0 ;;
esac
GH
    chmod +x "$bin/gh"
}

# Run _restage_execute inside the fixture work tree with the script sourced.
# $1=tmpdir $2=work $3=extra-env-prefix $4=args-to-_restage_execute
# Captures combined stdout+stderr; returns the call's exit code.
_run_execute() {
    local tmpdir="$1" work="$2" env_prefix="$3" args="$4" wrapper
    wrapper="$(mktemp "${TMPDIR:-/tmp}/dso-3274-int.XXXXXX")"
    cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
PR_LIB_MODE=1 BRANCH="$SRC_BRANCH" source "$PR_SCRIPT" 2>/dev/null
$env_prefix _restage_execute $args
exit \$?
WRAP
    chmod +x "$wrapper"
    (
        cd "$work" || exit 99
        HOME="$tmpdir/home" \
        TMPDIR="$tmpdir/tmp" \
        PATH="$tmpdir/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$wrapper" 2>&1
    )
    local _ec=$?
    rm -f "$wrapper"
    return "$_ec"
}

# ---- shared per-fixture setup ----
_setup() {
    local tmpdir="$1" conflict_mode="$2"
    mkdir -p "$tmpdir/home" "$tmpdir/tmp" "$tmpdir/bin"
    _install_gh_stub "$tmpdir/bin"
    _build_fixture "$tmpdir" "$conflict_mode"
}

# ===========================================================================
# I1 — happy path: clean rebase, fresh branch pushed to bare origin, staged ref
# deleted (forge-proof safe: PR1=MERGED, PR2 absent).
# ===========================================================================
t_happy_path_pushes_fresh_and_deletes_staged() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274-i1.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_setup "$_T" clean)"
    local _fresh="${SRC_BRANCH}-restage2"
    _out="$(_run_execute "$_T" "$_W" \
        "DSO_RESTAGE_EXECUTE=1 DSO_RESTAGE_PR1_STATE=MERGED DSO_RESTAGE_PR2_STATE=" \
        "'$STAGED_REF' '$SRC_BRANCH' 'main'")"; _ec=$?
    assert_eq "t_happy_path_rc0" "0" "$_ec"
    # Fresh branch must exist on the BARE origin (it was force-with-lease pushed there).
    local _on_origin="no"
    ( cd "$_T/origin.git" && git rev-parse --verify --quiet "refs/heads/$_fresh" >/dev/null 2>&1 ) && _on_origin="yes"
    assert_eq "t_happy_path_fresh_pushed_to_bare_origin" "yes" "$_on_origin"
    # Staged ref must be DELETED from the bare origin (forge-proof safe).
    local _staged_present="yes"
    ( cd "$_T/origin.git" && git rev-parse --verify --quiet "refs/heads/$STAGED_REF" >/dev/null 2>&1 ) || _staged_present="no"
    assert_eq "t_happy_path_staged_ref_deleted" "no" "$_staged_present"
    # The fresh branch's history must include origin/main's advance commit (rebase applied).
    local _rebased="no"
    ( cd "$_W" && git merge-base --is-ancestor origin/main "$_fresh" 2>/dev/null ) && _rebased="yes"
    assert_eq "t_happy_path_rebased_onto_origin_main" "yes" "$_rebased"
}

# ===========================================================================
# I2 — rebase conflict: DD5 rollback. Worktree back on original branch, fresh
# branch gone, nothing pushed to origin.
# ===========================================================================
t_rebase_conflict_rolls_back() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274-i2.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_setup "$_T" conflict)"
    local _fresh="${SRC_BRANCH}-restage2"
    _out="$(_run_execute "$_T" "$_W" \
        "DSO_RESTAGE_EXECUTE=1 DSO_RESTAGE_PR1_STATE=MERGED DSO_RESTAGE_PR2_STATE=" \
        "'$STAGED_REF' '$SRC_BRANCH' 'main'")"; _ec=$?
    assert_eq "t_rebase_conflict_rc1" "1" "$_ec"
    # Worktree restored to the original branch.
    local _cur; _cur="$(cd "$_W" && git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    assert_eq "t_rebase_conflict_back_on_original_branch" "$SRC_BRANCH" "$_cur"
    # Minted fresh branch deleted locally.
    local _fresh_local="present"
    ( cd "$_W" && git rev-parse --verify --quiet "refs/heads/$_fresh" >/dev/null 2>&1 ) || _fresh_local="gone"
    assert_eq "t_rebase_conflict_fresh_branch_deleted" "gone" "$_fresh_local"
    # Nothing pushed: fresh branch absent on the bare origin.
    local _fresh_origin="present"
    ( cd "$_T/origin.git" && git rev-parse --verify --quiet "refs/heads/$_fresh" >/dev/null 2>&1 ) || _fresh_origin="gone"
    assert_eq "t_rebase_conflict_nothing_pushed" "gone" "$_fresh_origin"
    # No rebase left in progress (clean tree).
    local _rebasing="no"
    ( cd "$_W" && { [[ -d .git/rebase-merge ]] || [[ -d .git/rebase-apply ]]; } ) && _rebasing="yes"
    assert_eq "t_rebase_conflict_no_rebase_in_progress" "no" "$_rebasing"
}

# ===========================================================================
# I3 — push failure: DD5 rollback. Make the origin remote unwritable (point it
# at a non-existent path) so the force-with-lease push fails; assert rollback.
# ===========================================================================
t_push_failure_rolls_back() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274-i3.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_setup "$_T" clean)"
    local _fresh="${SRC_BRANCH}-restage2"
    # Break the push target AFTER the fixture is built + fetched: repoint origin at
    # a bogus path so `git push` fails but `origin/main`/`origin/feat-x` remote-
    # tracking refs (already fetched) still resolve for the rebase base.
    ( cd "$_W" && git remote set-url origin "$_T/nonexistent-origin.git" ) >/dev/null 2>&1
    _out="$(_run_execute "$_T" "$_W" \
        "DSO_RESTAGE_EXECUTE=1 DSO_RESTAGE_PR1_STATE=MERGED DSO_RESTAGE_PR2_STATE=" \
        "'$STAGED_REF' '$SRC_BRANCH' 'main'")"; _ec=$?
    assert_eq "t_push_failure_rc1" "1" "$_ec"
    # Worktree restored to original branch.
    local _cur; _cur="$(cd "$_W" && git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    assert_eq "t_push_failure_back_on_original_branch" "$SRC_BRANCH" "$_cur"
    # Minted fresh branch deleted locally.
    local _fresh_local="present"
    ( cd "$_W" && git rev-parse --verify --quiet "refs/heads/$_fresh" >/dev/null 2>&1 ) || _fresh_local="gone"
    assert_eq "t_push_failure_fresh_branch_deleted" "gone" "$_fresh_local"
    # The real bare origin (still at origin.git) must NOT have the staged ref deleted
    # (push failed before the delete step).
    local _staged_present="no"
    ( cd "$_T/origin.git" && git rev-parse --verify --quiet "refs/heads/$STAGED_REF" >/dev/null 2>&1 ) && _staged_present="yes"
    assert_eq "t_push_failure_staged_ref_preserved" "yes" "$_staged_present"
}

# ===========================================================================
# I4 — happy push BUT forge-proof says UNSAFE (PR1 not MERGED) → staged ref
# PRESERVED on the bare origin even though the fresh branch was pushed.
# ===========================================================================
t_unsafe_delete_preserves_staged_ref() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-3274-i4.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_setup "$_T" clean)"
    local _fresh="${SRC_BRANCH}-restage2"
    _out="$(_run_execute "$_T" "$_W" \
        "DSO_RESTAGE_EXECUTE=1 DSO_RESTAGE_PR1_STATE=OPEN DSO_RESTAGE_PR2_STATE=" \
        "'$STAGED_REF' '$SRC_BRANCH' 'main'")"; _ec=$?
    assert_eq "t_unsafe_delete_rc0" "0" "$_ec"
    # Fresh branch pushed (the push happens regardless of delete-safety).
    local _on_origin="no"
    ( cd "$_T/origin.git" && git rev-parse --verify --quiet "refs/heads/$_fresh" >/dev/null 2>&1 ) && _on_origin="yes"
    assert_eq "t_unsafe_delete_fresh_pushed" "yes" "$_on_origin"
    # Staged ref PRESERVED (UNSAFE to delete: PR1=OPEN).
    local _staged_present="no"
    ( cd "$_T/origin.git" && git rev-parse --verify --quiet "refs/heads/$STAGED_REF" >/dev/null 2>&1 ) && _staged_present="yes"
    assert_eq "t_unsafe_delete_staged_ref_preserved" "yes" "$_staged_present"
}

# Run all.
t_happy_path_pushes_fresh_and_deletes_staged
t_rebase_conflict_rolls_back
t_push_failure_rolls_back
t_unsafe_delete_preserves_staged_ref

print_summary
