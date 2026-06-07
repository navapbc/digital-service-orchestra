#!/usr/bin/env bash
# shellcheck disable=SC2046,SC2329,SC2064,SC2016
# SC2016: this suite embeds orchestrator vars into fixture-run script bodies via the
# intentional '...'"$VAR"'...' single/double quote-toggle; the single-quoted spans are
# deliberately unexpanded (they evaluate inside the fixture), so SC2016 is a false positive.
# tests/scripts/test-merge-to-main-resume-merged-pr1.sh
#
# Bug 6d7f-bade-2350-4eaf — BEHAVIORAL tests for the merged-PR1 staged-base
# resolver and its wiring into the resume advance-to-PR2 path + the mint-site
# refusal guard in merge-to-main-pr.sh.
#
# Defect: the advance-to-PR2 block read its staged-ref input ONLY from the /tmp
# state cache (`_state_get_field staged_branch`). With the cache absent/cleared the
# input was empty, the advance block was skipped, and control fell through to
# _phase_staged_intermediate, which UNCONDITIONALLY minted a NEW staged ref + a
# duplicate PR1. The fix reconstructs the merged-PR1 staged base from GitHub state
# (level-triggered) so the merged-PR1 -> advance-to-PR2 transition is durable.
#
# These assert observable BEHAVIOR (function exit codes, the resolved base echoed
# on stdout, the advance decision, the mint-site refusal + non-invocation of
# _create_staged_ref) against a REAL git origin fixture + a PATH-shimmed `gh`.
# They are NOT source-greps.
#
# Functions under test (sourced via PR_LIB_MODE=1):
#   _resolve_merged_pr1_staged_base <branch>  — the new resolver (6d7f)
#   _resume_should_advance_to_staged ...      — the EXISTING advance gate (reused)
#   _phase_staged_intermediate                — mint-site refusal guard (6d7f DD3)
#
# Usage: bash tests/scripts/test-merge-to-main-resume-merged-pr1.sh

set -uo pipefail

export GIT_CONFIG_GLOBAL=/dev/null   # isolation-ok: scoped to this test process
export GIT_CONFIG_SYSTEM=/dev/null   # isolation-ok: scoped to this test process
export GIT_CONFIG_COUNT=1            # isolation-ok: scoped to this test process
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

SRC_BRANCH="story/6d7f-bade-2350-4eaf/feat-x"

# ---------------------------------------------------------------------------
# _build_fixture <tmpdir> <staged_topology> <gh_merged_mode>
#
# Builds a REAL clone+origin so origin/main and origin/staged-* remote-tracking
# refs resolve, and the "carries work" rev-list range is genuine.
#
# staged_topology — what staged-* refs exist on origin and whether they carry work:
#   one_live      — one staged-AAAA ref, 1 commit ahead of main (live + work)
#   one_empty     — one staged-AAAA ref sitting AT main HEAD (0 ahead → no work)
#   two_live      — two distinct staged-AAAA / staged-BBBB refs, both 1 ahead
#   none          — no staged-* ref on origin at all
#
# gh_merged_mode — what `gh pr list --head <b> --state merged --json ...` returns:
#   one     — one merged PR, baseRefName=staged-AAAA, mergedAt set
#   two     — two merged PRs, baseRefName=staged-AAAA and staged-BBBB
#   nonstaged — one merged PR whose base is `main` (NOT a staged-* base)
#   zero    — empty list "[]" (rc 0) — legitimately no merged PR
#   error   — gh exits non-zero (forge-read indeterminacy)
#   empty   — gh prints nothing, exit 0 (indeterminate)
#   truncated — gh prints malformed/truncated JSON, exit 0 (indeterminate)
# ---------------------------------------------------------------------------
_build_fixture() {
    local tmpdir="$1" topology="$2" gh_mode="$3"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"
    local real_git
    real_git=$(command -v git)

    # Place the origin under a path containing the literal "github.com" so the
    # file:// origin URL satisfies _phase_staged_intermediate's github.com guard
    # (substring match) WHILE the local bare repo still serves real ls-remote/fetch
    # for the resolver's "carries work" check — no network, no real gh.
    mkdir -p "$tmpdir/github.com"
    local origin="$tmpdir/github.com/origin.git"
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

        # The source branch (a non-staged worktree/feature branch) exists locally.
        "$real_git" checkout -q -b "$SRC_BRANCH"
        echo f > f.txt; "$real_git" add f.txt; "$real_git" commit -q -m feat
        "$real_git" checkout -q main

        _mk_staged_live() {  # $1 = staged ref name
            "$real_git" checkout -q -b "$1" main
            echo "$1" > "stg-$1.txt"; "$real_git" add "stg-$1.txt"
            "$real_git" commit -q -m "staged work $1"
            "$real_git" push -q origin "$1"
            "$real_git" checkout -q main
        }
        case "$topology" in
            one_live)  _mk_staged_live "staged-AAAA" ;;
            two_live)  _mk_staged_live "staged-AAAA"; _mk_staged_live "staged-BBBB" ;;
            one_empty)
                # staged ref at main HEAD: 0 commits ahead → carries no work.
                "$real_git" push -q origin main:refs/heads/staged-AAAA
                ;;
            none) : ;;  # no staged-* ref on origin
        esac
        "$real_git" fetch -q origin 2>/dev/null || true
    ) >/dev/null 2>&1

    # ---- gh shim. ----
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  pr)
    if [[ "\$2" == "list" && "\$*" == *"--state merged"* ]]; then
      case "$gh_mode" in
        one)   echo '[{"number":1,"baseRefName":"staged-AAAA","mergeCommit":{"oid":"abc"},"mergedAt":"2026-06-01T10:00:00Z"}]'; exit 0 ;;
        two)   echo '[{"number":1,"baseRefName":"staged-AAAA","mergeCommit":{"oid":"abc"},"mergedAt":"2026-06-01T10:00:00Z"},{"number":2,"baseRefName":"staged-BBBB","mergeCommit":{"oid":"def"},"mergedAt":"2026-06-02T10:00:00Z"}]'; exit 0 ;;
        nonstaged) echo '[{"number":3,"baseRefName":"main","mergeCommit":{"oid":"ghi"},"mergedAt":"2026-06-01T10:00:00Z"}]'; exit 0 ;;
        zero)  echo '[]'; exit 0 ;;
        error) echo "error: auth required" >&2; exit 1 ;;
        empty) exit 0 ;;
        truncated) printf '[{"number":1,"baseRefName":"staged-AAAA"'; exit 0 ;;
      esac
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    echo "$work"
}

# Run a snippet inside the fixture with the script sourced in lib mode. Captures
# stdout (and the snippet's exit code as the wrapper exit code, so an INDETERMINATE
# `exit 75` from the function-under-test surfaces here).
_run_in_fixture() {
    local tmpdir="$1" work="$2" snippet="$3"
    local wrapper
    wrapper="$(mktemp "${TMPDIR:-/tmp}/dso-6d7f-wrap.XXXXXX")"
    cat > "$wrapper" <<WRAP
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
PR_LIB_MODE=1 BRANCH="$SRC_BRANCH" source "$PR_SCRIPT" 2>/dev/null
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
# _resolve_merged_pr1_staged_base — core resolver behavior.
# ===========================================================================

# RESOLVES: a merged PR1 (base=staged-AAAA) + a live staged ref carrying work →
# echoes the staged base, rc 0. (The cache-miss durable-resume seam.)
t_resolves_merged_pr1_live_base() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" one_live one)"
    _out="$(_run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'")"; _ec=$?
    assert_eq "t_resolve_rc_zero" "0" "$_ec"
    assert_eq "t_resolve_echoes_base" "staged-AAAA" "$(printf '%s' "$_out" | head -n1)"
}

# ADVANCE wiring: feed the resolved base into the EXISTING _resume_should_advance_to_staged
# gate (pr1_open=0, staged_exists=1, staged_work>0) → advance (rc 0). Asserts the
# resolver output is consumable by the unchanged decision function.
t_resolved_base_feeds_advance_gate() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" one_live one)"
    _run_in_fixture "$_T" "$_W" '
        base=$(_resolve_merged_pr1_staged_base "'"$SRC_BRANCH"'") || exit 50
        work=$(git rev-list --count "origin/main..origin/${base}" 2>/dev/null)
        _resume_should_advance_to_staged 0 1 "$work"
    '; _ec=$?
    assert_eq "t_resolved_base_advances (exit 0 = ADVANCE)" "0" "$_ec"
}

# NO RESOLUTION: zero merged PR1 ("[]") → rc 1, caller proceeds normally (no exit 75).
t_zero_merged_pr1_proceeds() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" none zero)"
    _run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'"; _ec=$?
    assert_eq "t_zero_merged_pr1_rc_one (rc 1 = no resolution)" "1" "$_ec"
}

# NO RESOLUTION: the only merged PR's base is `main` (not staged-*) → rc 1.
t_nonstaged_base_proceeds() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" none nonstaged)"
    _run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'"; _ec=$?
    assert_eq "t_nonstaged_base_rc_one" "1" "$_ec"
}

# NO RESOLUTION: merged PR1 base=staged-AAAA but the staged ref carries NO work
# (sits at main HEAD, 0 ahead) → rc 1 (not a usable PR2 source; do NOT advance).
t_merged_pr1_empty_staged_proceeds() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" one_empty one)"
    _run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'"; _ec=$?
    assert_eq "t_empty_staged_rc_one" "1" "$_ec"
}

# INDETERMINATE (fail-closed, INC-008): a forge-read error → exit 75, NEVER a guess.
t_forge_error_is_indeterminate() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" none error)"
    _run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'"; _ec=$?
    assert_eq "t_forge_error_exit_75" "75" "$_ec"
}

# INDETERMINATE (fail-closed): an empty payload (≠ "[]") → exit 75.
t_forge_empty_is_indeterminate() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" none empty)"
    _run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'"; _ec=$?
    assert_eq "t_forge_empty_exit_75" "75" "$_ec"
}

# INDETERMINATE (fail-closed): truncated/malformed JSON → exit 75.
t_forge_truncated_is_indeterminate() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" none truncated)"
    _run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'"; _ec=$?
    assert_eq "t_forge_truncated_exit_75" "75" "$_ec"
}

# INDETERMINATE (fail-closed): >=2 DISTINCT live staged bases with work for the same
# head → ambiguous → exit 75 (cannot determine the canonical PR1 base).
t_two_live_bases_is_indeterminate() {
    local _T _W _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" two_live two)"
    _run_in_fixture "$_T" "$_W" "_resolve_merged_pr1_staged_base '$SRC_BRANCH'"; _ec=$?
    assert_eq "t_two_live_bases_exit_75" "75" "$_ec"
}

# ===========================================================================
# Mint-site refusal guard in _phase_staged_intermediate (6d7f DD3, defense-in-depth).
# ===========================================================================

# When an already-merged PR1 staged base resolves (live + work), _phase_staged_intermediate
# must REFUSE to mint a new staged ref: it must return non-zero, emit the actionable
# SOURCE_BRANCH_DIVERGED signal, and NEVER invoke _create_staged_ref. We shadow
# _create_staged_ref with a sentinel that records invocation, set a github.com origin
# (so the phase's github guard is satisfied and control reaches the new guard), and
# assert the sentinel never fired.
t_mint_site_refuses_when_pr1_already_merged() {
    local _T _W _out _ec
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" one_live one)"
    # The origin URL contains "github.com" (fixture path) so the phase's non-github
    # auto-skip does NOT fire and control reaches the refusal guard; the local bare
    # repo still serves the resolver's ls-remote/fetch "carries work" check.
    _out="$(_run_in_fixture "$_T" "$_W" '
        BRANCH="'"$SRC_BRANCH"'"
        SENTINEL="'"$_T"'/create_staged_ref_called"
        _create_staged_ref() { : > "$SENTINEL"; echo "staged-NEWREF-9999"; return 0; }
        _phase_staged_intermediate
        echo "PHASE_RC=$?"
        [[ -f "$SENTINEL" ]] && echo MINTED || echo NOT_MINTED
    ')"; _ec=$?
    # Phase returns non-zero (refusal).
    assert_eq "t_mint_refuse_phase_rc_nonzero" "PHASE_RC=1" "$(printf '%s' "$_out" | grep -o 'PHASE_RC=[0-9]*' | head -n1)"
    # _create_staged_ref was NEVER invoked → no duplicate staged ref minted.
    assert_eq "t_mint_refuse_no_mint" "NOT_MINTED" "$(printf '%s' "$_out" | grep -oE 'NOT_MINTED|MINTED' | head -n1)"
    # Actionable divergence signal emitted with the already-merged classification.
    local _has_signal="no"
    printf '%s' "$_out" | grep -q '^SOURCE_BRANCH_DIVERGED: .*"classification": *"staged_pr1_already_merged"' && _has_signal="yes"
    assert_eq "t_mint_refuse_emits_signal" "yes" "$_has_signal"
}

# CONTROL: when NO merged PR1 staged base resolves, the refusal guard does NOT fire —
# control proceeds to _create_staged_ref (the sentinel DOES fire). Guards against the
# refusal guard becoming a one-way block on the normal first-run mint path.
t_mint_site_proceeds_when_no_merged_pr1() {
    local _T _W _out
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-6d7f.XXXXXX")"; trap "rm -rf '$_T'" RETURN
    _W="$(_build_fixture "$_T" none zero)"
    _out="$(_run_in_fixture "$_T" "$_W" '
        BRANCH="'"$SRC_BRANCH"'"
        SENTINEL="'"$_T"'/create_staged_ref_called"
        # Stop right after the mint call so we do not execute the heavy push/gh-create
        # tail of the phase; we only assert the guard let control reach the mint.
        _create_staged_ref() { : > "$SENTINEL"; echo "MINT_REACHED"; return 1; }
        _phase_staged_intermediate >/dev/null 2>&1
        [[ -f "$SENTINEL" ]] && echo MINTED || echo NOT_MINTED
    ')"
    assert_eq "t_mint_proceeds_normal_path" "MINTED" "$(printf '%s' "$_out" | grep -oE 'NOT_MINTED|MINTED' | head -n1)"
}

# Run all.
t_resolves_merged_pr1_live_base
t_resolved_base_feeds_advance_gate
t_zero_merged_pr1_proceeds
t_nonstaged_base_proceeds
t_merged_pr1_empty_staged_proceeds
t_forge_error_is_indeterminate
t_forge_empty_is_indeterminate
t_forge_truncated_is_indeterminate
t_two_live_bases_is_indeterminate
t_mint_site_refuses_when_pr1_already_merged
t_mint_site_proceeds_when_no_merged_pr1

print_summary
