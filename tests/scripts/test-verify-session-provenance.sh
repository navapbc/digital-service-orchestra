#!/usr/bin/env bash
# tests/scripts/test-verify-session-provenance.sh
# RED-phase behavioral tests for plugins/dso/scripts/verify-session-provenance.sh
#
# All tests FAIL until the script is implemented (RED gate confirmed).
#
# The verifier walks commits from main..SESSION_HEAD, checks each for a
# DSO-Story-Merge trailer, caches results to avoid re-querying, retries on
# 429, and writes un-provenanced SHAs to an artifact scope file.
#
# Usage: bash tests/scripts/test-verify-session-provenance.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-verify-session-provenance.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# Helper: create a minimal git repo in a temp dir and return its path.
# Usage: setup_git_repo
setup_git_repo() {
    local git_dir
    git_dir="$(mktemp -d)"
    git init "$git_dir" >/dev/null 2>&1
    git -C "$git_dir" config user.email "test@example.com"
    git -C "$git_dir" config user.name "Test"
    echo "$git_dir"
}

# Helper: create a commit in $1 with message $2; echo its SHA.
make_commit() {
    local repo="$1" msg="$2"
    local fname
    # Portable filename uniqueness: nanoseconds where available (GNU date),
    # else fall back to seconds + PID + RANDOM (works on BSD/macOS coreutils-free).
    local _ns
    _ns="$(date +%s%N 2>/dev/null)"
    [[ -z "$_ns" || "$_ns" == *N ]] && _ns="$(date +%s)_${$}_${RANDOM}"
    fname="file_${_ns}.txt"
    printf "content\n" > "$repo/$fname"
    git -C "$repo" add "$fname" >/dev/null 2>&1
    git -C "$repo" commit -m "$msg" >/dev/null 2>&1
    git -C "$repo" rev-parse HEAD
}

# ── Test 1: script exists and is executable ──────────────────────────────────
# RED: script does not exist yet — assert_eq will FAIL
test_script_exists() {
    local exists
    if [[ -f "$SCRIPT" && -x "$SCRIPT" ]]; then exists="yes"; else exists="no"; fi
    assert_eq "test_script_exists: verify-session-provenance.sh exists and is executable" \
        "yes" "$exists"
}

# ── Test 2: all provenanced commits → exits 0 ───────────────────────────────
# Every commit in main..HEAD carries a DSO-Story-Merge trailer → script exits 0.
test_all_provenanced_exits_zero() {
    local repo
    repo="$(setup_git_repo)"

    # base commit on "main"
    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # story merge commit with DSO-Story-Merge trailer
    make_commit "$repo" "$(printf 'Merge story/epic-1/story-1\n\nDSO-Story-Merge: story-1-id')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=0
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_eq "test_all_provenanced_exits_zero: exits 0 when all commits have DSO-Story-Merge" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test 3: direct commit without trailer → exits non-zero; SHA in output ────
# A commit lacking DSO-Story-Merge causes exit non-zero and the SHA appears in
# both stdout/stderr AND in the integration review scope file.
test_direct_commit_exits_nonzero() {
    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Direct commit — no trailer
    local bad_sha
    bad_sha="$(make_commit "$repo" "Direct commit without provenance")"
    local session_head="$bad_sha"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=0
    local combined_output
    combined_output=$(
        DSO_REPO_PATH="$repo" \
        DSO_BASE_SHA="$base_sha" \
        DSO_SESSION_HEAD="$session_head" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    # Must exit non-zero
    assert_ne "test_direct_commit_exits_nonzero: exits non-zero for un-provenanced commit" \
        "0" "$exit_code"

    # SHA must appear in output
    assert_contains "test_direct_commit_exits_nonzero: un-provenanced SHA appears in output" \
        "$bad_sha" "$combined_output"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test 4: BUDGET_EXHAUSTED condition → exits non-zero with keyword ─────────
# When gh api call count exceeds the budget limit, script exits non-zero and
# emits "BUDGET_EXHAUSTED" in its output.
test_budget_exhaustion_exits_nonzero() {
    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Create multiple un-trailered commits to drive up gh api calls
    local i
    for i in 1 2 3 4 5; do
        make_commit "$repo" "Direct commit $i" > /dev/null
    done
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # gh stub: always succeeds but counts calls; budget exceeded from the start
    local call_log="$TMPDIR_TEST/gh-calls-budget.log"
    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
echo "\$*" >> "$call_log"
# Simulate budget exhausted by returning a special signal
echo "BUDGET_EXHAUSTED"
exit 2
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    local output
    output=$(
        PATH="$MOCK_BIN:$PATH" \
        DSO_REPO_PATH="$repo" \
        DSO_BASE_SHA="$base_sha" \
        DSO_SESSION_HEAD="$session_head" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
        DSO_GH_BUDGET="1" \
            bash "$SCRIPT" 2>&1
    ) || exit_code=$?

    assert_ne "test_budget_exhaustion_exits_nonzero: exits non-zero on budget exhaustion" \
        "0" "$exit_code"

    assert_contains "test_budget_exhaustion_exits_nonzero: output contains BUDGET_EXHAUSTED" \
        "BUDGET_EXHAUSTED" "$output"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test 5: cache prevents re-query for already-seen SHAs ────────────────────
# On second invocation with the same SHAs and same cache dir, gh api is NOT
# called again for those SHAs (call counter stays the same between runs).
test_cache_prevents_requery() {
    # RED gate: script must exist for this test to exercise cache behavior
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_cache_prevents_requery: script must exist to test cache behavior" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Commit with trailer — will be cached; no gh api call needed on second run
    make_commit "$repo" "$(printf 'Merge story/epic-x/story-x\n\nDSO-Story-Merge: story-x-id')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local call_count_file="$TMPDIR_TEST/gh-call-count.txt"
    echo "0" > "$call_count_file"

    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
count=\$(cat "$call_count_file")
echo \$(( count + 1 )) > "$call_count_file"
echo '{"items":[]}'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    # First run
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$SCRIPT" 2>/dev/null || true

    local count_after_first
    count_after_first="$(cat "$call_count_file")"

    # Second run — same SHAs, same artifact dir (cache location)
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$SCRIPT" 2>/dev/null || true

    local count_after_second
    count_after_second="$(cat "$call_count_file")"

    # gh api should NOT have been called again on second run
    assert_eq "test_cache_prevents_requery: gh api not re-called for cached SHAs" \
        "$count_after_first" "$count_after_second"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test 6: squash merge with DSO-Story-Merge trailer is accepted ─────────────
# A squash-merged commit bearing the DSO-Story-Merge trailer is treated as
# provenanced → script exits 0.
test_squash_merge_dso_story_merge_trailer_accepted() {
    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Squash merge: single commit, carries DSO-Story-Merge trailer
    make_commit "$repo" "$(printf 'feat: squash merge of story-abc\n\nDSO-Story-Merge: story-abc-id')" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=0
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_eq "test_squash_merge_dso_story_merge_trailer_accepted: squash merge with trailer exits 0" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test 7: 429 response → script retries (sleep/retry visible) ──────────────
# When gh api returns HTTP 429, script should retry; the retry is observable
# via the call counter in the gh stub increasing beyond the first call.
test_backoff_on_429() {
    # RED gate: script must exist for this test to exercise retry behavior
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_backoff_on_429: script must exist to test retry behavior" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Commit without trailer — will trigger gh api lookup
    make_commit "$repo" "Direct commit no trailer" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local call_count_file="$TMPDIR_TEST/gh-call-count-429.txt"
    echo "0" > "$call_count_file"

    # gh stub: first call returns 429, subsequent calls succeed
    cat > "$MOCK_BIN/gh" << MOCKEOF
#!/usr/bin/env bash
count=\$(cat "$call_count_file")
echo \$(( count + 1 )) > "$call_count_file"
if [[ \$count -eq 0 ]]; then
    echo "HTTP 429 Too Many Requests" >&2
    exit 1
fi
# Subsequent calls succeed with empty result
echo '{"items":[]}'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    # Mock sleep so tests don't actually wait
    cat > "$MOCK_BIN/sleep" << 'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/sleep"

    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$SCRIPT" 2>/dev/null || true

    local call_count
    call_count="$(cat "$call_count_file")"

    # More than 1 call means retry happened after 429
    assert_ne "test_backoff_on_429: gh api called more than once (retry after 429)" \
        "1" "$call_count"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test 8: un-provenanced SHA is written to the scope file ──────────────────
# After running with a direct commit, the SHA of that commit must appear in
# the integration review scope input file in the artifact directory.
test_unprovenanced_sha_written_to_scope_file() {
    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Direct commit — no trailer
    local bad_sha
    bad_sha="$(make_commit "$repo" "Another direct commit without provenance")"
    local session_head="$bad_sha"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$SCRIPT" 2>/dev/null || true

    # The scope file should exist somewhere in artifact_dir.
    # Prefer unprovenanced-shas.txt by name (bug 8a77 v2 adds covered-shas.txt
    # and over-bound-shas.txt to the same dir; the prior `*.txt` glob picked
    # an unrelated file alphabetically).
    local scope_file_contents=""
    local scope_file
    for scope_file in "$artifact_dir"/unprovenanced-shas.txt \
                      /tmp/unprovenanced-shas.txt \
                      "$artifact_dir"/*.txt; do
        if [[ -f "$scope_file" ]]; then
            scope_file_contents="$(cat "$scope_file")"
            break
        fi
    done

    assert_contains "test_unprovenanced_sha_written_to_scope_file: bad SHA in scope file" \
        "$bad_sha" "$scope_file_contents"

    rm -rf "$repo" "$artifact_dir"
}

## S1 trailer grammar fixtures
# ── Test 9: DSO-Story: trailer (no -Merge) → exits 0 ─────────────────────────
# RED phase: verify-session-provenance.sh:137 only accepts ^DSO-Story-Merge:
# so a commit with DSO-Story: (no -Merge suffix) is currently unprovenanced.
# GREEN phase: after extending the grep to accept both trailers, this exits 0.
test_verify_session_provenance_accepts_both_trailers() {
    local repo
    repo="$(setup_git_repo)"

    # base commit on "main"
    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Fixture A: DSO-Story: trailer only (no -Merge suffix) — RED fixture
    make_commit "$repo" "$(printf 'feat: story work\n\nDSO-Story: story-abc-id')" > /dev/null
    local session_head_a
    session_head_a="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir_a
    artifact_dir_a="$(mktemp -d)"

    local exit_code_a=0
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head_a" \
    DSO_ARTIFACT_DIR="$artifact_dir_a" \
        bash "$SCRIPT" 2>/dev/null || exit_code_a=$?

    assert_eq "test_verify_session_provenance_accepts_both_trailers: DSO-Story: trailer exits 0" \
        "0" "$exit_code_a"

    # Fixture B: DSO-Story-Merge: trailer (existing behavior must still pass)
    make_commit "$repo" "$(printf 'feat: story-merge work\n\nDSO-Story-Merge: story-def-id')" > /dev/null
    local session_head_b
    session_head_b="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir_b
    artifact_dir_b="$(mktemp -d)"

    local exit_code_b=0
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$session_head_a" \
    DSO_SESSION_HEAD="$session_head_b" \
    DSO_ARTIFACT_DIR="$artifact_dir_b" \
        bash "$SCRIPT" 2>/dev/null || exit_code_b=$?

    assert_eq "test_verify_session_provenance_accepts_both_trailers: DSO-Story-Merge: trailer exits 0" \
        "0" "$exit_code_b"

    rm -rf "$repo" "$artifact_dir_a" "$artifact_dir_b"
}
## end S1 trailer grammar fixtures

## S5 version-bump trailer fixtures
# ── Test 10: version-bump commit with DSO-Story-Merge: trailer → exits 0 ──────
# Simulates the source-branch bump commit produced by S5.T2's pre-merge phase.
# The commit subject is a chore(version) bump; the body carries DSO-Story-Merge:
# so verify-session-provenance.sh must recognize it as provenanced.
#
# RED state: before S1.T5's grammar extension lands, the script only accepted
# ^DSO-Story-Merge: — once S1.T5 adds ^DSO-Story(-Merge)?: both forms pass.
# This fixture tests that the version-bump commit's DSO-Story-Merge: trailer
# is recognized by the post-S1.T5 grammar.
test_verify_session_provenance_version_bump_trailer() {
    local repo
    repo="$(setup_git_repo)"

    # base commit on "main"
    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Positive fixture: chore(version) bump commit with DSO-Story-Merge: trailer
    # (mirrors S5.T2's pre-merge source-branch bump commit format)
    local bump_msg
    bump_msg="$(printf 'chore(version): bump to 1.18.0\n\nDSO-Story-Merge: 0c55-1103-a14d-431e')"
    make_commit "$repo" "$bump_msg" > /dev/null
    local session_head
    session_head="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    local exit_code=0
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_eq "test_verify_session_provenance_version_bump_trailer: chore(version) bump with DSO-Story-Merge: exits 0" \
        "0" "$exit_code"

    # Control case: same chore(version) subject but WITHOUT the trailer → exits 1
    local repo2
    repo2="$(setup_git_repo)"
    make_commit "$repo2" "Initial commit" > /dev/null
    local base_sha2
    base_sha2="$(git -C "$repo2" rev-parse HEAD)"

    make_commit "$repo2" "chore(version): bump to 1.18.0" > /dev/null
    local session_head2
    session_head2="$(git -C "$repo2" rev-parse HEAD)"

    local artifact_dir2
    artifact_dir2="$(mktemp -d)"

    local exit_code2=0
    DSO_REPO_PATH="$repo2" \
    DSO_BASE_SHA="$base_sha2" \
    DSO_SESSION_HEAD="$session_head2" \
    DSO_ARTIFACT_DIR="$artifact_dir2" \
        bash "$SCRIPT" 2>/dev/null || exit_code2=$?

    assert_ne "test_verify_session_provenance_version_bump_trailer: chore(version) bump WITHOUT trailer exits non-zero" \
        "0" "$exit_code2"

    # Additional fixture: DSO-Story: form (no -Merge) on a version-bump commit → also exits 0
    local repo3
    repo3="$(setup_git_repo)"
    make_commit "$repo3" "Initial commit" > /dev/null
    local base_sha3
    base_sha3="$(git -C "$repo3" rev-parse HEAD)"

    local bump_msg_story
    bump_msg_story="$(printf 'chore(version): bump to 1.18.0\n\nDSO-Story: 0c55-1103-a14d-431e')"
    make_commit "$repo3" "$bump_msg_story" > /dev/null
    local session_head3
    session_head3="$(git -C "$repo3" rev-parse HEAD)"

    local artifact_dir3
    artifact_dir3="$(mktemp -d)"

    local exit_code3=0
    DSO_REPO_PATH="$repo3" \
    DSO_BASE_SHA="$base_sha3" \
    DSO_SESSION_HEAD="$session_head3" \
    DSO_ARTIFACT_DIR="$artifact_dir3" \
        bash "$SCRIPT" 2>/dev/null || exit_code3=$?

    assert_eq "test_verify_session_provenance_version_bump_trailer: chore(version) bump with DSO-Story: exits 0" \
        "0" "$exit_code3"

    rm -rf "$repo" "$artifact_dir" "$repo2" "$artifact_dir2" "$repo3" "$artifact_dir3"
}
## end S5 version-bump trailer fixtures

# ── Test G3: covering PR with failed review-sub-pr → unprovenanced ───────────
# A covering merged PR whose review-sub-pr check FAILED must NOT count as
# valid provenance. The commit must be classified as unprovenanced.
test_covering_pr_failed_review_is_unprovenanced() {
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_covering_pr_failed_review_is_unprovenanced: script must exist" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Direct commit — no trailer, so it hits the API path
    local bad_sha
    bad_sha="$(make_commit "$repo" "Direct commit to check G3")"
    local session_head="$bad_sha"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # Mock gh: /commits/{sha}/pulls returns a merged covering PR #50,
    # /commits/{sha}/check-runs returns review-sub-pr with conclusion=failure
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
# Route based on the API path
for arg in "$@"; do
    if [[ "$arg" == *"/pulls" ]]; then
        # Return a merged covering PR
        cat << 'JSONEOF'
[{"number":50,"state":"closed","merged_at":"2026-05-01T00:00:00Z","head":{"sha":"coveringheadsha123"},"merge_commit_sha":"coveringmergesha456"}]
JSONEOF
        exit 0
    fi
    if [[ "$arg" == *"/check-runs" ]]; then
        # Return review-sub-pr with failure conclusion
        cat << 'JSONEOF'
{"check_runs":[{"name":"review-sub-pr","conclusion":"failure"}]}
JSONEOF
        exit 0
    fi
done
echo '[]'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="test/repo" \
    PR_NUMBER=999 \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_ne "test_covering_pr_failed_review_is_unprovenanced: exits non-zero when covering PR failed review" \
        "0" "$exit_code"

    # The commit SHA should appear in the unprovenanced file
    local unprov_content=""
    if [[ -f "${artifact_dir}/unprovenanced-shas.txt" ]]; then
        unprov_content="$(cat "${artifact_dir}/unprovenanced-shas.txt")"
    fi
    assert_contains "test_covering_pr_failed_review_is_unprovenanced: bad SHA in unprovenanced file" \
        "$bad_sha" "$unprov_content"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test G3b: covering PR with passed review-sub-pr → provenanced ────────────
# A covering merged PR whose review-sub-pr check PASSED should count as
# valid provenance. The commit must be classified as provenanced.
test_covering_pr_passed_review_is_provenanced() {
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_covering_pr_passed_review_is_provenanced: script must exist" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    local good_sha
    good_sha="$(make_commit "$repo" "Direct commit covered by reviewed PR")"
    local session_head="$good_sha"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # Mock gh: /commits/{sha}/pulls returns a merged covering PR #50,
    # /commits/{sha}/check-runs returns review-sub-pr with conclusion=success
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"/pulls" ]]; then
        cat << 'JSONEOF'
[{"number":50,"state":"closed","merged_at":"2026-05-01T00:00:00Z","head":{"sha":"coveringheadsha123"},"merge_commit_sha":"coveringmergesha456"}]
JSONEOF
        exit 0
    fi
    if [[ "$arg" == *"/check-runs" ]]; then
        cat << 'JSONEOF'
{"check_runs":[{"name":"review-sub-pr","conclusion":"success"}]}
JSONEOF
        exit 0
    fi
done
echo '[]'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="test/repo" \
    PR_NUMBER=999 \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_eq "test_covering_pr_passed_review_is_provenanced: exits 0 when covering PR passed review" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test G3c: covering PR with no review check → unprovenanced ───────────────
# A covering merged PR with NO review-sub-pr or llm-review check run must NOT
# count as valid provenance. The commit must be classified as unprovenanced.
# (F2 mitigation: not_found is no longer treated as covered.)
test_covering_pr_no_review_check_is_unprovenanced() {
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_covering_pr_no_review_check_is_unprovenanced: script must exist" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"

    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    local bad_sha
    bad_sha="$(make_commit "$repo" "Direct commit covered by unreviewed PR")"
    local session_head="$bad_sha"

    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # Mock gh: /commits/{sha}/pulls returns a merged covering PR #50,
    # /commits/{sha}/check-runs returns NO review-related checks
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"/pulls" ]]; then
        cat << 'JSONEOF'
[{"number":50,"state":"closed","merged_at":"2026-05-01T00:00:00Z","head":{"sha":"coveringheadsha123"},"merge_commit_sha":"coveringmergesha456"}]
JSONEOF
        exit 0
    fi
    if [[ "$arg" == *"/check-runs" ]]; then
        # Return check runs with NO review-sub-pr or llm-review
        cat << 'JSONEOF'
{"check_runs":[{"name":"ShellCheck","conclusion":"success"},{"name":"Hook Tests","conclusion":"success"}]}
JSONEOF
        exit 0
    fi
done
echo '[]'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$session_head" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="test/repo" \
    PR_NUMBER=999 \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_ne "test_covering_pr_no_review_check_is_unprovenanced: exits non-zero when no review check found" \
        "0" "$exit_code"

    local unprov_content=""
    if [[ -f "${artifact_dir}/unprovenanced-shas.txt" ]]; then
        unprov_content="$(cat "${artifact_dir}/unprovenanced-shas.txt")"
    fi
    assert_contains "test_covering_pr_no_review_check_is_unprovenanced: SHA in unprovenanced file" \
        "$bad_sha" "$unprov_content"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test R2a: failure-then-rerun-success → unprovenanced (poison-on-failure) ──
# A covering PR with a HISTORICAL failure check-run record on its head SHA
# must NOT count as covered, even if a later re-run succeeded. The poison-on-
# failure semantic prevents an admin from masking a real failure by re-running
# the check until it passes. (R2 v4 hardening)
test_covering_pr_failure_then_rerun_success_is_unprovenanced() {
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_covering_pr_failure_then_rerun_success: script must exist" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"
    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    local bad_sha
    bad_sha="$(make_commit "$repo" "Direct commit covered by failure-then-rerun PR")"
    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # Mock gh: /pulls returns a merged covering PR #50,
    # /check-runs returns TWO records — earlier failure + later success.
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"/pulls" ]]; then
        cat << 'JSONEOF'
[{"number":50,"state":"closed","merged_at":"2026-05-01T00:00:00Z","head":{"sha":"coveringheadsha123"},"merge_commit_sha":"coveringmergesha456"}]
JSONEOF
        exit 0
    fi
    if [[ "$arg" == *"/check-runs" ]]; then
        # Historical: one failure record + one later success record
        cat << 'JSONEOF'
{"check_runs":[{"name":"review-sub-pr","conclusion":"success"},{"name":"review-sub-pr","conclusion":"failure"}]}
JSONEOF
        exit 0
    fi
done
echo '[]'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$bad_sha" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="test/repo" \
    PR_NUMBER=999 \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_ne "test_covering_pr_failure_then_rerun_success: failure poisons SHA despite later success" \
        "0" "$exit_code"
    local unprov_content=""
    if [[ -f "${artifact_dir}/unprovenanced-shas.txt" ]]; then
        unprov_content="$(cat "${artifact_dir}/unprovenanced-shas.txt")"
    fi
    assert_contains "test_covering_pr_failure_then_rerun_success: SHA in unprovenanced file" \
        "$bad_sha" "$unprov_content"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test R2b: unrelated check-runs do NOT affect classification (name-filter) ──
# Failures on check-runs NOT named review-sub-pr or llm-review (e.g. Hook Tests)
# must NOT poison the SHA. The name filter ensures only review-related failures
# count.
test_unrelated_check_runs_do_not_affect_classification() {
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_unrelated_check_runs: script must exist" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"
    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    local good_sha
    good_sha="$(make_commit "$repo" "Direct commit covered by passing review with unrelated failures")"
    local artifact_dir
    artifact_dir="$(mktemp -d)"

    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"/pulls" ]]; then
        cat << 'JSONEOF'
[{"number":50,"state":"closed","merged_at":"2026-05-01T00:00:00Z","head":{"sha":"coveringheadsha123"},"merge_commit_sha":"coveringmergesha456"}]
JSONEOF
        exit 0
    fi
    if [[ "$arg" == *"/check-runs" ]]; then
        # Hook Tests FAILED, but review-sub-pr PASSED — only the review counts
        cat << 'JSONEOF'
{"check_runs":[{"name":"Hook Tests","conclusion":"failure"},{"name":"review-sub-pr","conclusion":"success"}]}
JSONEOF
        exit 0
    fi
done
echo '[]'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$good_sha" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="test/repo" \
    PR_NUMBER=999 \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    assert_eq "test_unrelated_check_runs: Hook Tests failure does NOT poison SHA" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Test R2c: cache_version mismatch entries are discarded on read ────────────
# A pre-existing cache file with cache_version != 3 must be treated as empty
# (entries discarded) so v2 cached "provenanced" verdicts that may have masked
# failures are re-evaluated under v3 semantics.
test_cache_version_mismatch_entries_discarded() {
    if [[ ! -f "$SCRIPT" ]]; then
        assert_eq "test_cache_version_mismatch: script must exist" \
            "script_exists" "script_missing"
        return
    fi

    local repo
    repo="$(setup_git_repo)"
    make_commit "$repo" "Initial commit" > /dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    local sha
    sha="$(make_commit "$repo" "Test commit")"
    local artifact_dir
    artifact_dir="$(mktemp -d)"

    # Pre-seed a v2 cache file with a stale "provenanced" entry for this SHA.
    # Under v3 with no API mock providing covering PRs, the SHA should be
    # re-evaluated and classified as unprovenanced (no covering PRs found).
    cat > "$artifact_dir/session-provenance-cache.json" <<EOF
{
  "cache_version": 2,
  "entries": {
    "${sha}.pr999": "provenanced"
  }
}
EOF

    # Mock gh that returns empty PR list — without cache, SHA is unprovenanced.
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
echo '[]'
exit 0
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    PATH="$MOCK_BIN:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$sha" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="test/repo" \
    PR_NUMBER=999 \
        bash "$SCRIPT" 2>/dev/null || exit_code=$?

    # Without the v3 invalidation, the stale "provenanced" entry would let
    # exit_code=0 (false-pass). With invalidation, SHA is re-evaluated and
    # classified as unprovenanced → exit_code != 0.
    assert_ne "test_cache_version_mismatch: v2 cache entries discarded → SHA re-evaluated" \
        "0" "$exit_code"

    rm -rf "$repo" "$artifact_dir"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_script_exists
test_all_provenanced_exits_zero
test_direct_commit_exits_nonzero
test_budget_exhaustion_exits_nonzero
test_cache_prevents_requery
test_squash_merge_dso_story_merge_trailer_accepted
test_backoff_on_429
test_unprovenanced_sha_written_to_scope_file
test_verify_session_provenance_accepts_both_trailers
test_verify_session_provenance_version_bump_trailer
test_covering_pr_failed_review_is_unprovenanced
test_covering_pr_passed_review_is_provenanced
test_covering_pr_no_review_check_is_unprovenanced
test_covering_pr_failure_then_rerun_success_is_unprovenanced
test_unrelated_check_runs_do_not_affect_classification
test_cache_version_mismatch_entries_discarded

print_summary
