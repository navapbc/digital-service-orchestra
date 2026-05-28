#!/usr/bin/env bash
# tests/scripts/test-sprint-bypass-detection-query.sh
#
# Tests the git-log query used by sprint SKILL.md Phase F → G's sprint-bypass
# redistribute check (bug 85f3). The detection block isn't directly invokable
# (it lives inside a SKILL.md inline bash block executed by the orchestrator),
# so this test exercises the underlying git semantics it depends on.
#
# Critical assertion: --first-parent + --no-merges must distinguish bypass
# commits (direct-to-session, carry DSO-Story trailer) from per-story PR
# merges (merge commits whose second parent has DSO-Story-trailered commits).
# Without --first-parent the query produces a false positive on every
# well-behaved ci-pr sprint.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-bypass-detection-query.sh ==="

# The exact query the SKILL.md detection block runs (with --first-parent).
_run_detection_query() {
    local repo="$1" main_branch="$2"
    git -C "$repo" log --no-merges --first-parent \
        --pretty='%H %(trailers:key=DSO-Story,valueonly=true)' \
        "${main_branch}..HEAD" 2>/dev/null \
        | awk 'NF>1 {c++} END {print c+0}'
}

# The buggy query (without --first-parent) — kept here so the regression
# remains observable: this is what the PR's first version did wrong.
_run_buggy_query() {
    local repo="$1" main_branch="$2"
    git -C "$repo" log --no-merges \
        --pretty='%H %(trailers:key=DSO-Story,valueonly=true)' \
        "${main_branch}..HEAD" 2>/dev/null \
        | awk 'NF>1 {c++} END {print c+0}'
}

# ── test_well_behaved_ci_pr_sprint_no_false_positive ──────────────────────────
# Simulates the normal ci-pr flow: per-story branches are created off main,
# commits land with DSO-Story trailers, the story branch is merged into the
# session branch via `gh pr merge --merge` (a true merge commit, not squash).
# The detection MUST NOT count these as bypass commits.
test_well_behaved_ci_pr_sprint_no_false_positive() {
    local T
    T=$(mktemp -d)
    # shellcheck disable=SC2064  # Intentional: $T resolves at function-scope time, single-quote semantics would lose the local value.
    trap "rm -rf '$T'" RETURN
    git -C "$T" init -q -b main
    git -C "$T" config user.email "test@example.com"
    git -C "$T" config user.name "Test"
    git -C "$T" commit --allow-empty -qm "initial"
    # Pretend origin/main tracks the same point
    git -C "$T" branch -f main HEAD
    git -C "$T" update-ref refs/remotes/origin/main HEAD

    # Create session branch from main
    git -C "$T" checkout -qb session-branch

    # Story 1: per-story branch with a commit carrying DSO-Story trailer,
    # then merge-via-PR into session branch (--no-ff simulates `gh pr merge --merge`)
    git -C "$T" checkout -qb story/epic-1/story-001 main
    git -C "$T" commit --allow-empty -qm "story-001 work

DSO-Story: story-001
"
    git -C "$T" checkout -q session-branch
    git -C "$T" merge --no-ff story/epic-1/story-001 -qm "Merge pull request #1 from story/epic-1/story-001"

    # Story 2: same pattern
    git -C "$T" checkout -qb story/epic-1/story-002 main
    git -C "$T" commit --allow-empty -qm "story-002 work

DSO-Story: story-002
"
    git -C "$T" checkout -q session-branch
    git -C "$T" merge --no-ff story/epic-1/story-002 -qm "Merge pull request #2 from story/epic-1/story-002"

    local count
    count=$(_run_detection_query "$T" "origin/main")
    assert_eq "well-behaved ci-pr sprint: detection counts 0 bypass commits" "0" "$count"

    # Also confirm the buggy query (without --first-parent) WOULD have produced
    # a false positive — this is the regression we are pinning against.
    local buggy_count
    buggy_count=$(_run_buggy_query "$T" "origin/main")
    assert_eq "buggy query (no --first-parent) demonstrates the regression" "2" "$buggy_count"
}
test_well_behaved_ci_pr_sprint_no_false_positive

# ── test_bypass_commits_are_detected ──────────────────────────────────────────
# Simulates the bug 85f3 failure mode: sub-agents commit directly to the
# session branch with DSO-Story trailers under DSO_SPRINT_ACTIVE=0 (no
# per-story branches, no merge commits). The detection MUST count these.
test_bypass_commits_are_detected() {
    local T
    T=$(mktemp -d)
    # shellcheck disable=SC2064  # Intentional: $T resolves at function-scope time, single-quote semantics would lose the local value.
    trap "rm -rf '$T'" RETURN
    git -C "$T" init -q -b main
    git -C "$T" config user.email "test@example.com"
    git -C "$T" config user.name "Test"
    git -C "$T" commit --allow-empty -qm "initial"
    git -C "$T" branch -f main HEAD
    git -C "$T" update-ref refs/remotes/origin/main HEAD

    git -C "$T" checkout -qb session-branch

    # Two direct-to-session commits with DSO-Story trailers (the bypass signature)
    git -C "$T" commit --allow-empty -qm "story-001 work

DSO-Story: story-001
"
    git -C "$T" commit --allow-empty -qm "story-002 work

DSO-Story: story-002
"

    local count
    count=$(_run_detection_query "$T" "origin/main")
    assert_eq "bypass commits: detection counts 2 direct-to-session commits" "2" "$count"
}
test_bypass_commits_are_detected

# ── test_mixed_bypass_and_pr_merges_counts_only_bypass ────────────────────────
# A realistic recovery scenario: some stories went through proper PR merges,
# others were committed directly under the bypass. The detection MUST count
# only the bypass commits, not the PR-merged ones.
test_mixed_bypass_and_pr_merges_counts_only_bypass() {
    local T
    T=$(mktemp -d)
    # shellcheck disable=SC2064  # Intentional: $T resolves at function-scope time, single-quote semantics would lose the local value.
    trap "rm -rf '$T'" RETURN
    git -C "$T" init -q -b main
    git -C "$T" config user.email "test@example.com"
    git -C "$T" config user.name "Test"
    git -C "$T" commit --allow-empty -qm "initial"
    git -C "$T" branch -f main HEAD
    git -C "$T" update-ref refs/remotes/origin/main HEAD

    git -C "$T" checkout -qb session-branch

    # Story A: proper per-story PR merge
    git -C "$T" checkout -qb story/epic-1/story-A main
    git -C "$T" commit --allow-empty -qm "story-A work

DSO-Story: story-A
"
    git -C "$T" checkout -q session-branch
    git -C "$T" merge --no-ff story/epic-1/story-A -qm "Merge pull request #1 from story-A"

    # Story B: bypass — direct commit
    git -C "$T" commit --allow-empty -qm "story-B work via bypass

DSO-Story: story-B
"

    # Story C: another proper PR merge
    git -C "$T" checkout -qb story/epic-1/story-C main
    git -C "$T" commit --allow-empty -qm "story-C work

DSO-Story: story-C
"
    git -C "$T" checkout -q session-branch
    git -C "$T" merge --no-ff story/epic-1/story-C -qm "Merge pull request #3 from story-C"

    local count
    count=$(_run_detection_query "$T" "origin/main")
    assert_eq "mixed bypass + PR merges: detection counts only the 1 bypass" "1" "$count"
}
test_mixed_bypass_and_pr_merges_counts_only_bypass

print_summary
