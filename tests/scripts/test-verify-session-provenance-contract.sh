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

# Target:     plugins/dso/scripts/verify-session-provenance.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# PR-R1: file-level gh shim controlled by DSO_TEST_GH_MOCK env var.
# success → covering PR with passing review-sub-pr (provenanced)
# unset   → empty result (unprovenanced)
_GLOBAL_GH_SHIM_DIR="$(mktemp -d -t dso-gh-shim-contract-XXXXXX)"
cat > "$_GLOBAL_GH_SHIM_DIR/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api)
    shift
    case "${DSO_TEST_GH_MOCK:-}" in
      success)
        case "$1" in
          *commits/*/pulls)
            echo '[{"number": 777, "state": "closed", "merged_at": "2026-01-01T00:00:00Z", "head": {"sha": "deadbeef"}, "merge_commit_sha": "cafef00d"}]'
            ;;
          *pulls/777*) echo '{"number": 777, "head": {"sha": "deadbeef"}}' ;;
          *commits/*/check-runs*)
            echo '{"total_count": 1, "check_runs": [{"name": "review-sub-pr", "status": "completed", "conclusion": "success"}]}'
            ;;
          *) echo "{}" ;;
        esac ;;
      *)
        case "$1" in
          *commits/*/pulls) echo "[]" ;;
          *commits/*/check-runs*) echo '{"total_count": 0, "check_runs": []}' ;;
          *) echo "{}" ;;
        esac ;;
    esac ;;
  *) echo "{}" ;;
esac
STUB
chmod +x "$_GLOBAL_GH_SHIM_DIR/gh"
export PATH="$_GLOBAL_GH_SHIM_DIR:$PATH"
export GH_REPO="test-owner/test-repo"
trap 'rm -rf "$_GLOBAL_GH_SHIM_DIR" 2>/dev/null || true' EXIT

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
    _snapshot_fail
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
    DSO_TEST_GH_MOCK=success \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_all_provenanced_exits_exactly_0: exits exactly 0 (all commits have DSO-Story-Merge)" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_all_provenanced_exits_exactly_0"
}

# ── Contract 2: DSO-Story: form (no -Merge suffix) also exits 0 ───────────────
# Both 'DSO-Story-Merge:' and 'DSO-Story:' are recognized as provenance trailers.
test_dso_story_trailer_exits_0() {
    _snapshot_fail
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
    DSO_TEST_GH_MOCK=success \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" 2>/dev/null
    exit_code=$?

    assert_eq "test_dso_story_trailer_exits_0: DSO-Story: trailer (no -Merge) also exits 0" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_dso_story_trailer_exits_0"
}

# ── Contract 3: One un-trailered commit (no PR link) → exits exactly 1 ────────
# When at least one commit lacks a DSO trailer AND has no associated PR,
# verifier MUST exit exactly 1.
test_one_unprovenanced_exits_exactly_1() {
    _snapshot_fail
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
    assert_pass_if_clean "test_one_unprovenanced_exits_exactly_1"
}

# ── Contract 4: All commits lack trailers and no PRs → exits 1 ───────────────
# Multiple un-provenanced commits still exit 1 (not some other code).
test_all_unprovenanced_exits_1() {
    _snapshot_fail
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
    assert_pass_if_clean "test_all_unprovenanced_exits_1"
}

# ── Contract 5: Budget exhausted → exits exactly 2 ───────────────────────────
# When GH_BUDGET=0 (or budget is exhausted immediately), verifier MUST exit
# exactly 2 — distinct from exit 1 (unprovenanced) and exit 0 (all clear).
test_budget_exhausted_exits_exactly_2() {
    _snapshot_fail
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
    assert_pass_if_clean "test_budget_exhausted_exits_exactly_2"
}

# ── Contract 6: Exit 2 is distinct from exit 1 ────────────────────────────────
# Budget-exhausted (2) must NOT collapse to unprovenanced (1).
# This confirms the contract distinction that llm-review-dispatch-or-skip.sh
# can rely on: both route to full-diff, but the exit code semantics differ.
test_budget_exit2_distinct_from_exit1() {
    _snapshot_fail
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
    assert_pass_if_clean "test_budget_exit2_distinct_from_exit1"
}

# ── Contract 7: Empty commit range → exits 0 ─────────────────────────────────
# If there are no commits in BASE..HEAD, all commits are trivially provenanced.
test_empty_range_exits_0() {
    _snapshot_fail
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
    assert_pass_if_clean "test_empty_range_exits_0"
}

# ── Contract 8: OVER_BOUND-marked commit → exits 3 ───────────────────────────
# When a commit is marked with OVER_BOUND (acknowledged non-provenanced,
# routed to admin/FP-recovery), verifier MUST exit exactly 3.
# This is a future contract (S7.T11 implements the OVER_BOUND marker);
# the test is RED until S7.T11 adds the OVER_BOUND recognition logic.
#

# markers — exit 3 support is added in S7.T11.
test_over_bound_marker_exits_3() {
    _snapshot_fail
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
    assert_pass_if_clean "test_over_bound_marker_exits_3"
}

# ── Contract 9 (bug 8a77 v2): Unreachable BASE_SHA → exits 4 + non-empty stderr ─
# When DSO_BASE_SHA refers to a SHA that is not reachable in the working tree
# (typical under shallow CI clone), the verifier MUST exit 4 with a descriptive
# stderr — rather than silently falling through to exit 0 ("all provenanced").
# This is the load-bearing fix for bug 8a77.
test_unreachable_base_sha_exits_4() {
    _snapshot_fail
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    local stderr_file
    stderr_file="$(mktemp)"

    local exit_code=99
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="0000000000000000000000000000000000000001" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" > /dev/null 2> "$stderr_file"
    exit_code=$?

    assert_eq "test_unreachable_base_sha_exits_4: unreachable BASE_SHA exits 4" \
        "4" "$exit_code"

    local stderr_size=0
    if [[ -s "$stderr_file" ]]; then stderr_size=1; fi
    assert_eq "test_unreachable_base_sha_exits_4: non-empty stderr on exit 4" \
        "1" "$stderr_size"

    rm -rf "$repo" "$artifact_dir" "$stderr_file"
    assert_pass_if_clean "test_unreachable_base_sha_exits_4"
}

# ── Contract 10 (bug 8a77 v2): Unreachable SESSION_HEAD → exits 4 + non-empty stderr
test_unreachable_session_head_exits_4() {
    _snapshot_fail
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"
    local stderr_file
    stderr_file="$(mktemp)"

    local exit_code=99
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="0000000000000000000000000000000000000002" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" > /dev/null 2> "$stderr_file"
    exit_code=$?

    assert_eq "test_unreachable_session_head_exits_4: unreachable SESSION_HEAD exits 4" \
        "4" "$exit_code"

    local stderr_size=0
    if [[ -s "$stderr_file" ]]; then stderr_size=1; fi
    assert_eq "test_unreachable_session_head_exits_4: non-empty stderr on exit 4" \
        "1" "$stderr_size"

    rm -rf "$repo" "$artifact_dir" "$stderr_file"
    assert_pass_if_clean "test_unreachable_session_head_exits_4"
}

# ── Contract 11 (bug 8a77 v2): Success marker written on exit 0 ───────────────
# On clean completion (all provenanced), the verifier MUST write
# provenance-complete.marker into ARTIFACT_DIR so the dispatcher can
# distinguish "ran clean" from "never ran / crashed".
test_marker_written_on_all_provenanced() {
    _snapshot_fail
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    _make_commit "$repo" "$(printf 'Merge story\n\nDSO-Story-Merge: abc-0001')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" > /dev/null 2>/dev/null

    local marker_exists="no"
    if [[ -f "$artifact_dir/provenance-complete.marker" ]]; then marker_exists="yes"; fi
    assert_eq "test_marker_written_on_all_provenanced: marker created on exit 0" \
        "yes" "$marker_exists"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_marker_written_on_all_provenanced"
}

# ── Contract 12 (bug 8a77 v2): Success marker written on exit 1 (unprovenanced) ─
test_marker_written_on_unprovenanced() {
    _snapshot_fail
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    _make_commit "$repo" "chore: untrailered" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    _make_mock_gh_no_prs

    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="owner/repo" \
        bash "$VERIFIER" > /dev/null 2>/dev/null

    local marker_exists="no"
    if [[ -f "$artifact_dir/provenance-complete.marker" ]]; then marker_exists="yes"; fi
    assert_eq "test_marker_written_on_unprovenanced: marker created on exit 1" \
        "yes" "$marker_exists"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_marker_written_on_unprovenanced"
}

# ── Contract 13 (bug 8a77 v2): NO marker written on exit 4 (unreachable SHA) ──
test_marker_NOT_written_on_unreachable_sha() {
    _snapshot_fail
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="0000000000000000000000000000000000000003" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" > /dev/null 2>/dev/null || true

    local marker_exists="yes"
    if [[ ! -f "$artifact_dir/provenance-complete.marker" ]]; then marker_exists="no"; fi
    assert_eq "test_marker_NOT_written_on_unreachable_sha: marker absent on exit 4" \
        "no" "$marker_exists"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_marker_NOT_written_on_unreachable_sha"
}

# ── Contract 14 (bug 8a77 v2 MF1): over-bound-shas.txt written when OVER_BOUND ─
# Without this artifact, the dispatcher's `[[ -s "$OVERBOUND_FILE" ]]` route
# check is dead code and OVER_BOUND commits silently route as exit 0.
test_overbound_artifact_written() {
    _snapshot_fail
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    _make_commit "$repo" "$(printf 'chore: routed\n\nDSO-Over-Bound: acknowledged')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" > /dev/null 2>/dev/null || true

    local overbound_nonempty="no"
    if [[ -s "$artifact_dir/over-bound-shas.txt" ]]; then overbound_nonempty="yes"; fi
    assert_eq "test_overbound_artifact_written: over-bound-shas.txt non-empty on OVER_BOUND" \
        "yes" "$overbound_nonempty"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_overbound_artifact_written"
}

# ── Contract 15 (bug 8a77 v2 MF2): covered-shas.txt written for trailer-provenanced ─
# When commits are provenanced via DSO-Story-Merge trailer, the verifier must
# write their SHAs to covered-shas.txt so the dispatcher can render the
# "Covered by sub-PR reviews:" line without re-walking BASE..HEAD.
test_covered_shas_written_for_trailer_provenanced() {
    _snapshot_fail
    local repo
    repo="$(_setup_git_repo)"

    _make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    _make_commit "$repo" "$(printf 'Merge story-A\n\nDSO-Story-Merge: epic-A/story-1')" > /dev/null
    local sha_a
    sha_a="$(git -C "$repo" rev-parse HEAD)"
    _make_commit "$repo" "$(printf 'Merge story-B\n\nDSO-Story-Merge: epic-A/story-2')" > /dev/null
    local sha_b
    sha_b="$(git -C "$repo" rev-parse HEAD)"
    local session_head="$sha_b"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    DSO_TEST_GH_MOCK=success \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" > /dev/null 2>/dev/null

    local covered_content=""
    if [[ -f "$artifact_dir/covered-shas.txt" ]]; then
        covered_content="$(cat "$artifact_dir/covered-shas.txt")"
    fi
    assert_contains "test_covered_shas_written_for_trailer_provenanced: covered-shas.txt contains sha_a" \
        "$sha_a" "$covered_content"
    assert_contains "test_covered_shas_written_for_trailer_provenanced: covered-shas.txt contains sha_b" \
        "$sha_b" "$covered_content"

    rm -rf "$repo" "$artifact_dir"
    assert_pass_if_clean "test_covered_shas_written_for_trailer_provenanced"
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
test_unreachable_base_sha_exits_4
test_unreachable_session_head_exits_4
test_marker_written_on_all_provenanced
test_marker_written_on_unprovenanced
test_marker_NOT_written_on_unreachable_sha
test_overbound_artifact_written
test_covered_shas_written_for_trailer_provenanced

print_summary
