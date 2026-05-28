#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-pr-title-derivation.sh
#
# Tests for the PR-title derivation helper in merge-to-main-pr.sh
# (bug 85b8-2576). Before this fix, PR titles were derived via
# `git log -1 --pretty=%s`, which after a merge-back from origin/main
# resolves to the uninformative merge-commit subject
# `Merge remote-tracking branch 'origin/main' into <branch>`.
#
# The helper under test is `_derive_pr_title <branch>` which must:
#   (a) Prefer the latest non-merge commit subject.
#   (b) Prefix with `[<ticket-id>]` when a DSO-Story/DSO-Task trailer
#       (or earlier `[id]`-prefixed commit subject) is available and
#       the chosen subject lacks a `[id]` prefix.
#   (c) Fall back to `[<branch>] <truncated-merge-subject>` when no
#       non-merge commit exists.
#
# Strategy: build a throwaway git fixture per case, source the script,
# call the helper directly, assert the returned title string.
#
# Usage: bash tests/scripts/test-merge-to-main-pr-title-derivation.sh

set -uo pipefail

# Disable commit signing for throwaway temp repos.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# Isolate from ambient PROJECT_ROOT leakage (see test-merge-to-main-pr.sh).
unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# Make a fresh git fixture and cd into it. Returns the dir path on stdout.
_mkfixture() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/mtm-pr-title.XXXXXX")"
    (
        cd "$d" || exit 1
        git init -q -b main
        git config user.email "test@example.com"
        git config user.name  "Test"
        # Seed an initial commit on main so subsequent branches have history.
        echo seed > seed.txt
        git add seed.txt
        git commit -q -m "chore: seed"
    )
    printf '%s\n' "$d"
}

# Call the helper under test in a clean subshell, returning its stdout.
# Args: <fixture-dir> <branch>
_call_derive() {
    local dir="$1" branch="$2"
    (
        cd "$dir" || exit 1
        # Sourcing-mode env: skip dispatcher-only init that would `exit` the
        # subshell before the helper is defined.
        export PR_LIB_MODE=1
        export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
        export BRANCH="$branch"
        # shellcheck disable=SC1090
        source "$PR_SCRIPT" >/dev/null 2>&1 || true
        if ! declare -F _derive_pr_title >/dev/null 2>&1; then
            echo "__NO_HELPER__"
            exit 0
        fi
        _derive_pr_title "$branch"
    )
}

# ---------------------------------------------------------------------------
# Test A: latest commit is a merge → title comes from non-merge commit
# ---------------------------------------------------------------------------
t_prefers_non_merge_subject() {
    local d branch title
    d="$(_mkfixture)"
    branch="feature/test-a"
    (
        cd "$d" || exit 1
        git checkout -q -b "$branch"
        echo a > a.txt && git add a.txt
        git commit -q -m "feat(x): foo"
        # Simulate a merge-back from origin/main producing a merge commit.
        git checkout -q main
        echo m > m.txt && git add m.txt
        git commit -q -m "chore: main moves"
        git checkout -q "$branch"
        git merge -q --no-ff -m "Merge remote-tracking branch 'origin/main' into $branch" main
    ) >/dev/null 2>&1

    title="$(_call_derive "$d" "$branch")"
    assert_eq "A: prefers non-merge subject over merge-back commit" \
        "feat(x): foo" "$title"
    rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Test B1: DSO-Story trailer prefixes title with [id]
# ---------------------------------------------------------------------------
t_prefix_from_dso_story_trailer() {
    local d branch title
    d="$(_mkfixture)"
    branch="story/abc-1234"
    (
        cd "$d" || exit 1
        git checkout -q -b "$branch"
        echo a > a.txt && git add a.txt
        git commit -q -m "feat(x): foo

DSO-Story: abc-1234"
        git checkout -q main
        echo m > m.txt && git add m.txt
        git commit -q -m "chore: main moves"
        git checkout -q "$branch"
        git merge -q --no-ff -m "Merge remote-tracking branch 'origin/main' into $branch" main
    ) >/dev/null 2>&1

    title="$(_call_derive "$d" "$branch")"
    assert_eq "B1: prefixes [<id>] from DSO-Story trailer" \
        "[abc-1234] feat(x): foo" "$title"
    rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Test B2: DSO-Task trailer prefixes title with [id]
# ---------------------------------------------------------------------------
t_prefix_from_dso_task_trailer() {
    local d branch title
    d="$(_mkfixture)"
    branch="task/ff00-1111"
    (
        cd "$d" || exit 1
        git checkout -q -b "$branch"
        echo a > a.txt && git add a.txt
        git commit -q -m "fix(y): bar

DSO-Task: ff00-1111"
    ) >/dev/null 2>&1

    title="$(_call_derive "$d" "$branch")"
    assert_eq "B2: prefixes [<id>] from DSO-Task trailer" \
        "[ff00-1111] fix(y): bar" "$title"
    rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Test B3: leading [id] in an earlier commit subject is used as prefix
# ---------------------------------------------------------------------------
t_prefix_from_earlier_subject_prefix() {
    local d branch title
    d="$(_mkfixture)"
    branch="feature/test-b3"
    (
        cd "$d" || exit 1
        git checkout -q -b "$branch"
        echo a > a.txt && git add a.txt
        git commit -q -m "[zzzz-9999] feat(x): initial"
        echo b > b.txt && git add b.txt
        git commit -q -m "refactor(x): tweak"
    ) >/dev/null 2>&1

    title="$(_call_derive "$d" "$branch")"
    assert_eq "B3: prefixes [<id>] from earlier subject's leading [id]" \
        "[zzzz-9999] refactor(x): tweak" "$title"
    rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Test B4: subject already starts with [id] → not double-prefixed
# ---------------------------------------------------------------------------
t_no_double_prefix() {
    local d branch title
    d="$(_mkfixture)"
    branch="feature/test-b4"
    (
        cd "$d" || exit 1
        git checkout -q -b "$branch"
        echo a > a.txt && git add a.txt
        git commit -q -m "[abcd-0001] feat(x): foo

DSO-Story: abcd-0001"
    ) >/dev/null 2>&1

    title="$(_call_derive "$d" "$branch")"
    assert_eq "B4: leaves [id]-prefixed subject untouched" \
        "[abcd-0001] feat(x): foo" "$title"
    rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Test C: no non-merge commit exists → fallback uses [<branch>] form
# ---------------------------------------------------------------------------
t_fallback_when_only_merge_commit() {
    local d branch title
    d="$(_mkfixture)"
    branch="feature/test-c"
    (
        cd "$d" || exit 1
        # Create an unrelated branch with no real commits of its own; merge main in.
        # We want a branch where the only commit reachable-but-not-on-main is a
        # merge commit.
        git checkout -q --orphan "$branch"
        git rm -rqf .
        # Empty merge: bring main in via a merge commit only.
        git merge -q --allow-unrelated-histories --no-ff \
            -m "Merge remote-tracking branch 'origin/main' into $branch" main
    ) >/dev/null 2>&1

    title="$(_call_derive "$d" "$branch")"
    # Fallback must contain the [<branch>] prefix and NOT be the bare merge subject.
    assert_contains "C: fallback contains [<branch>] prefix" \
        "[$branch]" "$title"
    assert_ne "C: fallback is not the bare merge-back subject" \
        "Merge remote-tracking branch 'origin/main' into $branch" "$title"
    rm -rf "$d"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
t_prefers_non_merge_subject
t_prefix_from_dso_story_trailer
t_prefix_from_dso_task_trailer
t_prefix_from_earlier_subject_prefix
t_no_double_prefix
t_fallback_when_only_merge_commit

print_summary
