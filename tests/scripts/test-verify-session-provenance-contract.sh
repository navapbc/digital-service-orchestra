#!/usr/bin/env bash
# tests/scripts/test-verify-session-provenance-contract.sh
# Contract tests for plugins/dso/scripts/verify-session-provenance.sh exit codes.
#
# Locks exit-code semantics (DD3 from S3's story):
#   0 = all commits provenanced (DSO-Story-Merge / DSO-Story: trailer present)
#   1 = one or more un-provenanced commits found
#   2 = BUDGET_EXHAUSTED — API call budget used up before all commits checked
#
# These contract tests are separate from test-verify-session-provenance.sh
# (behavioral/unit tests); this file specifically asserts the exit-code contract
# that llm-review-dispatch-or-skip.sh depends on for its routing logic.
#
# Usage: bash tests/scripts/test-verify-session-provenance-contract.sh
# Returns: exit 0 if all contract tests pass, exit 1 if any fail
#
# RED marker: [test_verify_session_provenance_contract]
# Target:     plugins/dso/scripts/verify-session-provenance.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verify-session-provenance-contract.sh ==="

# ── Setup ─────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# Helper: create a minimal git repo in a temp dir and return its path.
_setup_git_repo() {
    local git_dir
    git_dir="$(mktemp -d)"
    git init "$git_dir" >/dev/null 2>&1
    git -C "$git_dir" config user.email "test@example.com"
    git -C "$git_dir" config user.name "Test"
    echo "$git_dir"
}

# Helper: create a commit in $1 with message $2; echo its SHA.
_make_commit() {
    local repo="$1" msg="$2"
    local _ns
    _ns="$(date +%s%N 2>/dev/null)"
    [[ -z "$_ns" || "$_ns" == *N ]] && _ns="$(date +%s)_${$}_${RANDOM}"
    local fname="file_${_ns}.txt"
    printf "content\n" > "$repo/$fname"
    git -C "$repo" add "$fname" >/dev/null 2>&1
    git -C "$repo" commit -m "$msg" >/dev/null 2>&1
    git -C "$repo" rev-parse HEAD
}

# Mock gh that returns no associated PRs (forces unprovenanced for untrailered commits)
_make_mock_gh_no_prs() {
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
# Mock gh: return empty PR list for any commits/*/pulls API call
echo "[]"
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"
}

# ── Contract 1: All commits have DSO-Story-Merge trailer → exits 0 ────────────
# Strict contract: verifier MUST exit exactly 0 when all commits in range
# carry a DSO-Story-Merge or DSO-Story: trailer.
test_all_provenanced_exits_exactly_0() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Two story-merge commits — both with DSO-Story-Merge: trailer
    _make_commit "$repo" "$(printf 'Merge story/epic-1/story-1\n\nDSO-Story-Merge: abc1-0001-0000-0001')" > /dev/null
    _make_commit "$repo" "$(printf 'Merge story/epic-1/story-2\n\nDSO-Story-Merge: abc1-0001-0000-0002')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=99
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_all_provenanced_exits_exactly_0: exits exactly 0 (all commits have DSO-Story-Merge)" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Contract 2: DSO-Story: form (no -Merge suffix) also exits 0 ───────────────
# Both 'DSO-Story-Merge:' and 'DSO-Story:' are recognized as provenance trailers.
test_dso_story_trailer_exits_0() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Commit using DSO-Story: form (not DSO-Story-Merge:)
    _make_commit "$repo" "$(printf 'feat(foo): add feature bar\n\nDSO-Story: abc1-0001-0000-0003')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=99
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_dso_story_trailer_exits_0: DSO-Story: trailer (no -Merge) also exits 0" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Contract 3: One un-trailered commit (no PR link) → exits exactly 1 ────────
# When at least one commit lacks a DSO trailer AND has no associated PR,
# verifier MUST exit exactly 1.
test_one_unprovenanced_exits_exactly_1() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # One provenanced commit
    _make_commit "$repo" "$(printf 'Merge story/epic-1/story-1\n\nDSO-Story-Merge: abc1-0001-0000-0004')" > /dev/null
    # One UN-provenanced commit (no trailer, no PR)
    _make_commit "$repo" "fix: direct hotfix with no trailer" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # Mock gh to return empty PRs (no associated PR for the commit)
    _make_mock_gh_no_prs

    local exit_code=99
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="owner/repo" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_one_unprovenanced_exits_exactly_1: exits exactly 1 when one commit lacks trailer+PR" \
        "1" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Contract 4: All commits lack trailers and no PRs → exits 1 ───────────────
# Multiple un-provenanced commits still exit 1 (not some other code).
test_all_unprovenanced_exits_1() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    _make_commit "$repo" "chore: no trailer here" > /dev/null
    _make_commit "$repo" "chore: also no trailer" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    _make_mock_gh_no_prs

    local exit_code=99
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="owner/repo" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_all_unprovenanced_exits_1: exits exactly 1 (not 0 or 2) when all commits unprovenanced" \
        "1" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Contract 5: Budget exhausted → exits exactly 2 ───────────────────────────
# When GH_BUDGET=0 (or budget is exhausted immediately), verifier MUST exit
# exactly 2 — distinct from exit 1 (unprovenanced) and exit 0 (all clear).
test_budget_exhausted_exits_exactly_2() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Un-trailered commits that would require API calls
    _make_commit "$repo" "chore: no trailer commit A" > /dev/null
    _make_commit "$repo" "chore: no trailer commit B" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # gh stub that simulates budget exhausted by emitting BUDGET_EXHAUSTED
    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
echo "BUDGET_EXHAUSTED"
exit 2
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=99
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="owner/repo" \
    DSO_GH_BUDGET="1" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_budget_exhausted_exits_exactly_2: exits exactly 2 on budget exhaustion" \
        "2" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Contract 6: Exit 2 is distinct from exit 1 ────────────────────────────────
# Budget-exhausted (2) must NOT collapse to unprovenanced (1).
# This confirms the contract distinction that llm-review-dispatch-or-skip.sh
# can rely on: both route to full-diff, but the exit code semantics differ.
test_budget_exit2_distinct_from_exit1() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    _make_commit "$repo" "chore: no trailer" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir1 artifact_dir2
    artifact_dir1="$(mktemp -d)"
    artifact_dir2="$(mktemp -d)"

    # gh stub for budget-exhausted case
    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
echo "BUDGET_EXHAUSTED"
exit 2
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local budget_exit=99
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir1" \
    DSO_GH_REPO="owner/repo" \
    DSO_GH_BUDGET="1" \
        bash "$VERIFIER" 2>/dev/null
    budget_exit=$?

    # gh stub for normal no-PR (unprovenanced) case
    _make_mock_gh_no_prs

    local noPr_exit=99
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir2" \
    DSO_GH_REPO="owner/repo" \
        bash "$VERIFIER" 2>/dev/null
    noPr_exit=$?

    assert_eq "test_budget_exit2_distinct_from_exit1: budget-exhausted exits 2" \
        "2" "$budget_exit"

    assert_eq "test_budget_exit2_distinct_from_exit1: normal unprovenanced exits 1" \
        "1" "$noPr_exit"

    assert_ne "test_budget_exit2_distinct_from_exit1: exit codes are distinct (2 != 1)" \
        "$budget_exit" "$noPr_exit"

    rm -rf "$repo" "$artifact_dir1" "$artifact_dir2"
}

# ── Contract 7: Empty commit range → exits 0 ─────────────────────────────────
# If there are no commits in BASE..HEAD, all commits are trivially provenanced.
test_empty_range_exits_0() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    # SESSION_HEAD = BASE_SHA → empty range
    local session_head="$base_sha"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=99
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_empty_range_exits_0: exits 0 when commit range is empty" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Contract 8: OVER_BOUND-marked commit → exits 3 ───────────────────────────
# When a commit is marked with OVER_BOUND (acknowledged non-provenanced,
# routed to admin/FP-recovery), verifier MUST exit exactly 3.
# This is a future contract (S7.T11 implements the OVER_BOUND marker);
# the test is RED until S7.T11 adds the OVER_BOUND recognition logic.
#
# RED-gate: verify-session-provenance.sh does NOT yet recognize OVER_BOUND
# markers — exit 3 support is added in S7.T11.
test_over_bound_marker_exits_3() {
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Commit with OVER_BOUND marker in the commit message (S7.T11 format)
    _make_commit "$repo" "$(printf 'chore: acknowledged non-provenanced commit\n\nDSO-Over-Bound: acknowledged\nDSO-FP-Recovery: routed')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=99
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_over_bound_marker_exits_3: OVER_BOUND-marked commit → exits exactly 3" \
        "3" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Run all contract tests ────────────────────────────────────────────────────
test_all_provenanced_exits_exactly_0
test_dso_story_trailer_exits_0
test_one_unprovenanced_exits_exactly_1
test_all_unprovenanced_exits_1
test_budget_exhausted_exits_exactly_2
test_budget_exit2_distinct_from_exit1
test_empty_range_exits_0
test_over_bound_marker_exits_3

print_summary
