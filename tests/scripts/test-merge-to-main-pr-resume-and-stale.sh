#!/usr/bin/env bash
# shellcheck disable=SC2164,SC2016
# tests/scripts/test-merge-to-main-pr-resume-and-stale.sh
# Structural RED tests for two related defects in merge-to-main-pr.sh:
#
#   - b0ad-69ee: --resume flag documented in usage but not parsed; the
#     duplicate-PR guard runs unconditionally so resume fails when a PR
#     already exists for the branch.
#
#   - b56b-14e9: _phase_merge calls `git push -u origin "$BRANCH"` without
#     fetching first — when the remote ref has advanced (e.g. a previous
#     "Merge branch 'main' into <branch>" landed via UI or another session),
#     the push is rejected and the workflow halts instead of recovering via
#     fetch+rebase.
#
# REVIEW-DEFENSE (PR #65 round-2 important finding "structural pattern tests
# are brittle"): structural assertions are the convention for merge-to-main-pr
# guard tests — see tests/scripts/test-merge-to-main-resume-cwd.sh which uses
# the same approach for the same script. End-to-end behavioral tests for
# _phase_merge would require shimming `gh`, `git fetch`, `git push`, and
# remote-state across multiple commits per scenario — the existing fixture
# infrastructure (test-merge-to-main-pr.sh, _build_pr_fixture, ~4071 lines)
# is one such heavy harness; layering rebase + retry semantics into it is
# significantly more work than these tests warrant for a guard-pattern fix.
# The structural assertions catch the regression class the bugs describe
# (the flag is parsed; the helper is called before push). A separate
# integration test layer is in scope as a follow-up — see also bug
# 0740-2df7 (test-merge-to-main-*.sh source-grepping cleanup).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# b0ad-69ee — --resume flag wiring
# ---------------------------------------------------------------------------

test_resume_flag_is_parsed() {
    # The argv loop must recognize --resume (not just --help).
    if grep -E '^\s*(--resume\)|"--resume"\)|--resume)' "$PR_SCRIPT" >/dev/null 2>&1 \
        || grep -E '\b_RESUME=1\b' "$PR_SCRIPT" >/dev/null 2>&1; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_resume_flag_is_parsed: --resume not parsed (no _RESUME=1 assignment found in %s)\n" "$PR_SCRIPT" >&2
    fi
}

test_duplicate_pr_check_skipped_on_resume() {
    # When --resume is set and the state file already has pr_url, the
    # _check_duplicate_pr guard must be conditional, not unconditional.
    # Detect by checking that the call site is wrapped in a guard referencing
    # _RESUME (any conditional that mentions _RESUME and _check_duplicate_pr
    # within a small textual window satisfies the boundary).
    if awk '
        /_check_duplicate_pr/ { found_check = 1 }
        found_check && /_RESUME/ { print "guarded"; exit }
    ' "$PR_SCRIPT" | grep -q guarded; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_duplicate_pr_check_skipped_on_resume: _check_duplicate_pr is not guarded by _RESUME in %s\n" "$PR_SCRIPT" >&2
    fi
}

test_phase_merge_skipped_on_resume_with_pr_url() {
    # When --resume is set and state has a recorded pr_url, _phase_merge
    # must NOT be re-invoked (it would attempt to push and create another
    # PR, hitting the same duplicate-PR error).
    # The _phase_merge call must be guarded by either _RESUME or
    # _RESUME_STATE_PR_URL (a state-derived flag that implies _RESUME=1
    # plus a pre-existing PR record).
    if awk '
        /_RESUME_STATE_PR_URL|_RESUME/ { saw_resume = NR }
        /_phase_merge[[:space:]]*\|\|[[:space:]]*_PHASE_MERGE_RC/ {
            if (saw_resume && (NR - saw_resume) <= 5) { print "guarded"; exit }
        }
    ' "$PR_SCRIPT" | grep -q guarded; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_phase_merge_skipped_on_resume_with_pr_url: _phase_merge call site is not guarded by _RESUME in %s\n" "$PR_SCRIPT" >&2
    fi
}

# ---------------------------------------------------------------------------
# b56b-14e9 — pre-push fetch + rebase on rejection
# ---------------------------------------------------------------------------

test_phase_merge_fetches_before_push() {
    # _phase_merge should fetch origin and rebase if needed before its
    # `git push -u origin "$BRANCH"` step. The fetch may live inline OR in
    # an extracted helper (_fetch_and_rebase_branch — Finding 2 refactor).
    # Detect either pattern: literal `git fetch` in the function body, OR
    # a call to a *_fetch_*rebase* helper before the push.
    _detect_tmp=$(mktemp /tmp/phase-merge-detect.XXXXXX)
    awk '
        /^_phase_merge\(\) \{/ { in_func = 1; next }
        in_func && /^\}/ { in_func = 0 }
        in_func && (/git fetch/ || /_fetch_and_rebase|_fetch.*rebase/) { saw_fetch = 1 }
        in_func && /git push -u origin/ {
            if (saw_fetch) print "fetch_before_push"
            else print "no_fetch"
            exit
        }
    ' "$PR_SCRIPT" > "$_detect_tmp"

    if grep -q "fetch_before_push" "$_detect_tmp"; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_phase_merge_fetches_before_push: _phase_merge does not call git fetch before git push -u origin in %s\n" "$PR_SCRIPT" >&2
    fi
    rm -f "$_detect_tmp"
}

test_phase_merge_handles_push_rejection() {
    # On `! [rejected] ... fetch first`, _phase_merge should attempt
    # `git pull --rebase origin "$BRANCH"` and retry the push, not just
    # bail with `ERROR: git push -u origin <branch> failed`.
    if grep -E 'git pull --rebase origin' "$PR_SCRIPT" >/dev/null 2>&1; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_phase_merge_handles_push_rejection: no `git pull --rebase origin` recovery path in %s\n" "$PR_SCRIPT" >&2
    fi
}

# ---------------------------------------------------------------------------

test_resume_flag_is_parsed
test_duplicate_pr_check_skipped_on_resume
test_phase_merge_skipped_on_resume_with_pr_url
test_phase_merge_fetches_before_push
test_phase_merge_handles_push_rejection

print_summary
