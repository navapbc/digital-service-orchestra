#!/usr/bin/env bash
# shellcheck disable=SC2046,SC2329,SC2064
# tests/scripts/test-merge-to-main-spent-classifier.sh
#
# ef39 v1 (merge-to-main self-heal) BEHAVIORAL tests for the shared spent primitive
# and the divergence classifier in merge-to-main-pr.sh. These assert observable
# BEHAVIOR (function exit codes, emitted SOURCE_BRANCH_DIVERGED lines, the chosen
# classification token) against REAL git topology fixtures (a bare origin with real
# rebase/squash-merge history) plus a PATH-shimmed `gh` for the forge-proof read.
# They are NOT source-greps.
#
# Functions under test (sourced via PR_LIB_MODE=1):
#   _branch_is_spent <branch>            — DD0/DD1/DD2 shared safety primitive
#   _classify_branch_divergence <branch> — DD1 pre-push divergence classifier
#   _emit_source_branch_diverged ...     — DD3 distinct top-level signal line
#
# Usage: bash tests/scripts/test-merge-to-main-spent-classifier.sh

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

# ---------------------------------------------------------------------------
# _build_topology_fixture <tmpdir> <topology> <gh_merged_mode>
#
# Builds a REAL clone+origin so origin/main and origin/<branch> remote-tracking
# refs resolve and the --cherry-pick topology test is genuine.
#
# topology:
#   spent       — branch content was REBASE-merged into main (original SHAs gone
#                 from main; patch-equivalent → 0 unmatched commits)
#   squashed    — branch content was SQUASH-merged into main (single new SHA;
#                 patch-equivalent → 0 unmatched commits)
#   not_equiv   — branch has a commit whose patch is NOT on main (>0 unmatched)
#   diverged    — both origin/<branch> and local HEAD have unique commits
#   ff          — local HEAD is ahead of origin/<branch> (fast-forward)
#   behind      — origin/<branch> is ahead of local HEAD
#   absent      — origin/<branch> does not exist
#
# gh_merged_mode (forge-proof stub for `gh pr list --head <b> --state merged`):
#   merged   — returns a length-1 (a merged PR exists)
#   none     — returns length-0 (no merged PR)
#   error    — gh exits non-zero (forge-read indeterminacy)
#   empty    — gh prints nothing, exit 0 (indeterminate)
# ---------------------------------------------------------------------------
BRANCH_NAME="feat-x"

_build_topology_fixture() {
    local tmpdir="$1" topology="$2" gh_mode="$3"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"
    local real_git
    real_git=$(command -v git)

    local origin="$tmpdir/origin.git"
    local work="$tmpdir/work"

    (
        set -e
        "$real_git" init -q --bare "$origin"
        "$real_git" init -q -b main "$work"
        cd "$work"
        "$real_git" config user.email t@t.local
        "$real_git" config user.name t
        echo base > base.txt; "$real_git" add base.txt; "$real_git" commit -q -m base
        "$real_git" remote add origin "$origin"
        "$real_git" push -q origin main

        case "$topology" in
            absent)
                # Only main on origin; branch exists locally but never pushed.
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo f > f.txt; "$real_git" add f.txt; "$real_git" commit -q -m feat
                ;;
            spent)
                # Branch commit, then REBASE-merge it into main (new SHA on main),
                # so origin/<branch>'s original SHA is patch-present but not an
                # ancestor. origin/<branch> and origin/main are patch-equivalent.
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo f > f.txt; "$real_git" add f.txt; "$real_git" commit -q -m feat
                "$real_git" push -q origin "$BRANCH_NAME"
                "$real_git" checkout -q main
                # rebase-merge: cherry-pick the feature commit onto main (rewrites SHA)
                "$real_git" cherry-pick "$BRANCH_NAME" -q 2>/dev/null || "$real_git" merge --no-ff -q "$BRANCH_NAME"
                "$real_git" push -q origin main
                "$real_git" checkout -q "$BRANCH_NAME"
                ;;
            squashed)
                # Single-commit squash: the squash commit's patch-id matches the lone
                # branch commit, so --cherry-pick detects equivalence (count 0). NOTE: a
                # MULTI-commit squash collapses several patch-ids into one and is NOT
                # detected by --cherry-pick — that case fails CLOSED to NOT-SPENT (safe),
                # documented in _branch_is_spent's comment.
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo f > f.txt; "$real_git" add f.txt; "$real_git" commit -q -m feat1
                "$real_git" push -q origin "$BRANCH_NAME"
                "$real_git" checkout -q main
                "$real_git" merge --squash -q "$BRANCH_NAME"
                "$real_git" commit -q -m "squash feat"
                "$real_git" push -q origin main
                "$real_git" checkout -q "$BRANCH_NAME"
                ;;
            not_equiv)
                # Branch has a commit whose patch is NOT on main.
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo unique > unique.txt; "$real_git" add unique.txt; "$real_git" commit -q -m unique
                "$real_git" push -q origin "$BRANCH_NAME"
                ;;
            diverged)
                # origin/<branch> gets a commit; local HEAD gets a DIFFERENT commit.
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo a > a.txt; "$real_git" add a.txt; "$real_git" commit -q -m base-feat
                "$real_git" push -q origin "$BRANCH_NAME"
                # origin advances
                echo remote > remote.txt; "$real_git" add remote.txt; "$real_git" commit -q -m remote-only
                "$real_git" push -q origin "$BRANCH_NAME"
                # local rewinds one and makes its own commit → divergence
                "$real_git" reset -q --hard HEAD~1
                echo local > local.txt; "$real_git" add local.txt; "$real_git" commit -q -m local-only
                ;;
            diverged_spent)
                # origin/<branch> is patch-equivalent to main (SPENT topology: the feature
                # commit was rebase-merged into main, so origin/<branch> has 0 unmatched
                # commits vs origin/main). Local HEAD then DIVERGES (a fresh local commit
                # the operator added after the branch's PR1 merged — the canonical
                # "reused a spent branch" case). _branch_is_spent reads origin/<branch>
                # (patch-equivalent + merged PR ⇒ SPENT); the classifier sees local-vs-
                # origin divergence ⇒ classification "spent".
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo f > f.txt; "$real_git" add f.txt; "$real_git" commit -q -m feat
                "$real_git" push -q origin "$BRANCH_NAME"
                "$real_git" checkout -q main
                "$real_git" cherry-pick "$BRANCH_NAME" -q 2>/dev/null || "$real_git" merge --no-ff -q "$BRANCH_NAME"
                "$real_git" push -q origin main
                "$real_git" checkout -q "$BRANCH_NAME"
                # Operator reuses the (now spent) branch: rewind + add a NEW local commit,
                # so local HEAD diverges from origin/<branch> (which is unchanged + spent).
                "$real_git" reset -q --hard HEAD~1
                echo reuse > reuse.txt; "$real_git" add reuse.txt; "$real_git" commit -q -m reuse-on-spent
                ;;
            ff)
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo a > a.txt; "$real_git" add a.txt; "$real_git" commit -q -m c1
                "$real_git" push -q origin "$BRANCH_NAME"
                echo b > b.txt; "$real_git" add b.txt; "$real_git" commit -q -m c2   # local ahead
                ;;
            behind)
                "$real_git" checkout -q -b "$BRANCH_NAME"
                echo a > a.txt; "$real_git" add a.txt; "$real_git" commit -q -m c1
                echo b > b.txt; "$real_git" add b.txt; "$real_git" commit -q -m c2
                "$real_git" push -q origin "$BRANCH_NAME"
                "$real_git" reset -q --hard HEAD~1   # local behind origin
                ;;
        esac
        # Refresh remote-tracking refs so origin/* resolve in the function under test.
        "$real_git" fetch -q origin 2>/dev/null || true
    ) >/dev/null 2>&1

    # ---- gh shim: forge-proof for `gh pr list --head <b> --state merged`. ----
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    if [[ "\$2" == "list" && "\$*" == *"--state merged"* ]]; then
      case "$gh_mode" in
        merged) echo "1"; exit 0 ;;
        none)   echo "0"; exit 0 ;;
        error)  echo "error: auth required" >&2; exit 1 ;;
        empty)  exit 0 ;;
      esac
    fi
    # Any other pr list (e.g. unrelated queries) → empty.
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    echo "$work"
}

# Run a one-liner inside the fixture work tree with the script sourced in lib mode.
# $1=tmpdir $2=work $3=shell-snippet (uses _branch_is_spent / _classify_*). Captures
# stdout; returns the snippet's exit code.
_run_in_fixture() {
    local tmpdir="$1" work="$2" snippet="$3"
    local wrapper
    wrapper="$(mktemp "${TMPDIR:-/tmp}/dso-ef39-wrap.XXXXXX")"
    cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
PR_LIB_MODE=1 BRANCH="$BRANCH_NAME" source "$PR_SCRIPT" 2>/dev/null
$snippet
exit \$?
WRAP
    chmod +x "$wrapper"
    (
        cd "$work" || exit 99
        PATH="$tmpdir/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        bash "$wrapper"
    )
    local _ec=$?
    rm -f "$wrapper"
    return "$_ec"
}

# ===========================================================================
# _branch_is_spent unit behavior — all branches.
# ===========================================================================

# SPENT: rebase-merged (patch-equivalent) + forge-confirmed merged PR → 0.
t_spent_rebase_merged_with_merged_pr_is_spent() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" spent merged)"
    _run_in_fixture "$_T" "$_W" "_branch_is_spent $BRANCH_NAME"; _ec=$?
    assert_eq "t_spent_rebase_merged_with_merged_pr_is_spent (exit 0 = SPENT)" "0" "$_ec"
}

# SPENT: squash-merged topology likewise patch-equivalent → 0 with merged PR.
t_spent_squash_merged_with_merged_pr_is_spent() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" squashed merged)"
    _run_in_fixture "$_T" "$_W" "_branch_is_spent $BRANCH_NAME"; _ec=$?
    assert_eq "t_spent_squash_merged_with_merged_pr_is_spent (exit 0 = SPENT)" "0" "$_ec"
}

# NOT-SPENT: patch-equivalent topology BUT no merged PR (forge says none).
t_patch_equiv_but_unmerged_pr_is_not_spent() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" spent none)"
    _run_in_fixture "$_T" "$_W" "_branch_is_spent $BRANCH_NAME"; _ec=$?
    assert_eq "t_patch_equiv_but_unmerged_pr_is_not_spent (exit 1 = NOT-SPENT)" "1" "$_ec"
}

# NOT-SPENT: branch has unmatched commits (topology NOT equivalent), even if a PR
# were merged — the topology gate fails first.
t_topology_not_equivalent_is_not_spent() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" not_equiv merged)"
    _run_in_fixture "$_T" "$_W" "_branch_is_spent $BRANCH_NAME"; _ec=$?
    assert_eq "t_topology_not_equivalent_is_not_spent (exit 1 = NOT-SPENT)" "1" "$_ec"
}

# NOT-SPENT (fail-closed): forge read errors → indeterminate → NOT-SPENT even when
# topology is patch-equivalent.
t_forge_error_fails_closed_to_not_spent() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" spent error)"
    _run_in_fixture "$_T" "$_W" "_branch_is_spent $BRANCH_NAME"; _ec=$?
    assert_eq "t_forge_error_fails_closed_to_not_spent (exit 1 = NOT-SPENT)" "1" "$_ec"
}

# NOT-SPENT (fail-closed): forge read empty/partial → indeterminate → NOT-SPENT.
t_forge_empty_fails_closed_to_not_spent() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" spent empty)"
    _run_in_fixture "$_T" "$_W" "_branch_is_spent $BRANCH_NAME"; _ec=$?
    assert_eq "t_forge_empty_fails_closed_to_not_spent (exit 1 = NOT-SPENT)" "1" "$_ec"
}

# ===========================================================================
# _classify_branch_divergence behavior.
# ===========================================================================

# absent origin/<branch> → "absent", rc 0, NO signal emitted.
t_classify_absent_is_happy_no_signal() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" absent none)"
    _out="$(_run_in_fixture "$_T" "$_W" "_classify_branch_divergence $BRANCH_NAME")"; _ec=$?
    assert_eq "t_classify_absent_token" "absent" "$(printf '%s' "$_out" | head -n1)"
    assert_eq "t_classify_absent_rc_zero" "0" "$_ec"
    if printf '%s' "$_out" | grep -q "SOURCE_BRANCH_DIVERGED:"; then
        assert_eq "t_classify_absent_no_signal" "no-signal" "signal-emitted"
    else
        assert_eq "t_classify_absent_no_signal" "no-signal" "no-signal"
    fi
}

# ff (local ahead) → "ff", rc 0, no signal.
t_classify_ff_is_normal_push() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" ff none)"
    _out="$(_run_in_fixture "$_T" "$_W" "_classify_branch_divergence $BRANCH_NAME")"; _ec=$?
    assert_eq "t_classify_ff_token" "ff" "$(printf '%s' "$_out" | head -n1)"
    assert_eq "t_classify_ff_rc_zero" "0" "$_ec"
}

# behind (origin ahead) → "behind", rc 0.
t_classify_behind_defers() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" behind none)"
    _out="$(_run_in_fixture "$_T" "$_W" "_classify_branch_divergence $BRANCH_NAME")"; _ec=$?
    assert_eq "t_classify_behind_token" "behind" "$(printf '%s' "$_out" | head -n1)"
    assert_eq "t_classify_behind_rc_zero" "0" "$_ec"
}

# diverged + NOT spent (no merged PR) → "concurrent", rc 1, emits the signal with
# classification:concurrent. NEVER auto-force-pushes (no push happens — pure classify).
t_classify_diverged_not_spent_is_concurrent_signal() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" diverged none)"
    _out="$(_run_in_fixture "$_T" "$_W" "_classify_branch_divergence $BRANCH_NAME")"; _ec=$?
    assert_eq "t_classify_concurrent_token" "concurrent" "$(printf '%s' "$_out" | grep -v SOURCE_BRANCH | head -n1)"
    assert_eq "t_classify_concurrent_rc_one" "1" "$_ec"
    local _has_signal="no"
    printf '%s' "$_out" | grep -q '^SOURCE_BRANCH_DIVERGED: .*"classification": *"concurrent"' && _has_signal="yes"
    assert_eq "t_classify_concurrent_emits_signal" "yes" "$_has_signal"
    # DD3 invariant: signal is NOT under the CONFLICT_DATA prefix.
    local _no_conflict_prefix="yes"
    printf '%s' "$_out" | grep -q "CONFLICT_DATA:" && _no_conflict_prefix="no"
    assert_eq "t_classify_concurrent_not_conflict_data" "yes" "$_no_conflict_prefix"
}

# diverged + SPENT (origin/<branch> patch-equivalent to main + merged PR; local HEAD
# diverged by a reuse commit) → "spent", rc 1, emits classification:spent signal.
# The classifier ROUTES only — no push, no merge, no ref mutation happens here.
t_classify_diverged_spent_is_spent_signal() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_topology_fixture "$_T" diverged_spent merged)"
    _out="$(_run_in_fixture "$_T" "$_W" "_classify_branch_divergence $BRANCH_NAME")"; _ec=$?
    assert_eq "t_classify_spent_token" "spent" "$(printf '%s' "$_out" | grep -v SOURCE_BRANCH | head -n1)"
    assert_eq "t_classify_spent_rc_one" "1" "$_ec"
    local _has_signal="no"
    printf '%s' "$_out" | grep -q '^SOURCE_BRANCH_DIVERGED: .*"classification": *"spent"' && _has_signal="yes"
    assert_eq "t_classify_spent_emits_signal" "yes" "$_has_signal"
    # DD3 invariant: signal is on its own top-level line, NOT under CONFLICT_DATA.
    local _no_conflict_prefix="yes"
    printf '%s' "$_out" | grep -q "CONFLICT_DATA:" && _no_conflict_prefix="no"
    assert_eq "t_classify_spent_not_conflict_data" "yes" "$_no_conflict_prefix"
    # Recommended command cuts a FRESH branch off origin/<default> (never reuses the
    # spent branch) — the prevention/heal contract.
    local _has_fresh="no"
    printf '%s' "$_out" | grep -q '"recommended_command": *"git checkout -b ' && _has_fresh="yes"
    assert_eq "t_classify_spent_recommends_fresh_branch" "yes" "$_has_fresh"
}

# DD5 + non-negotiable invariant (fresh-branch heal NEVER auto-merges / never creates
# an empty PR): on a SPENT, patch-equivalent source (0 unmatched commits), _restage_execute
# must short-circuit to an explicit NO-OP — it must NOT cut a fresh branch, must NOT push,
# and must NOT create an empty PR. Asserts behavior: rc 0, "NO-OP" message, and that the
# fresh branch was NEVER created (the heal cannot chain into a merge within one invocation).
t_restage_execute_empty_fresh_branch_is_noop() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-ef39.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    # 'spent' topology: origin/<branch> is patch-equivalent to origin/main (0 unmatched).
    _W="$(_build_topology_fixture "$_T" spent merged)"
    local _fresh="${BRANCH_NAME}-restage2"
    # DSO_RESTAGE_EXECUTE=1 so the guard inside _restage_execute is reachable; the no-op
    # short-circuit must fire BEFORE any checkout/push. Capture stderr (the NO-OP line).
    _out="$(_run_in_fixture "$_T" "$_W" \
        "DSO_RESTAGE_EXECUTE=1 _restage_execute '' '$BRANCH_NAME' 'main' 2>&1; echo RC=\$?; git rev-parse --verify --quiet '$_fresh' >/dev/null 2>&1 && echo FRESH_EXISTS || echo FRESH_ABSENT")"
    local _is_noop="no"; printf '%s' "$_out" | grep -q "NO-OP:" && _is_noop="yes"
    assert_eq "t_restage_noop_emits_noop" "yes" "$_is_noop"
    assert_eq "t_restage_noop_rc_zero" "RC=0" "$(printf '%s' "$_out" | grep -o 'RC=[0-9]*' | head -n1)"
    # Invariant: no fresh branch was minted → cannot chain into an auto-merge/empty PR.
    assert_eq "t_restage_noop_no_fresh_branch" "FRESH_ABSENT" "$(printf '%s' "$_out" | grep -o 'FRESH_\(EXISTS\|ABSENT\)' | head -n1)"
}

# Run all.
t_spent_rebase_merged_with_merged_pr_is_spent
t_spent_squash_merged_with_merged_pr_is_spent
t_patch_equiv_but_unmerged_pr_is_not_spent
t_topology_not_equivalent_is_not_spent
t_forge_error_fails_closed_to_not_spent
t_forge_empty_fails_closed_to_not_spent
t_classify_absent_is_happy_no_signal
t_classify_ff_is_normal_push
t_classify_behind_defers
t_classify_diverged_not_spent_is_concurrent_signal
t_classify_diverged_spent_is_spent_signal
t_restage_execute_empty_fresh_branch_is_noop

print_summary
