#!/usr/bin/env bash
# tests/workflows/test-integration-review-skip-on-provenance.sh
# E2E test: 6000+ line all-provenanced PR completes without LLM dispatch.
#
# Story: 7382-791d-4cfb-4ad7 (S3 — Provenance-aware CI review dispatch)
# Task:  329c-cecb-152d-4cee (S3.T4 — RED E2E test)
# DD4:   Synthetic test fixture exercises a 6000+ line all-provenanced
#        session→main PR; completes without LLM dispatch.
#

# Target:     plugins/dso/scripts/llm-review-dispatch-or-skip.sh
#
# Scenario:
#   Given  a synthetic git repo with 6000+ lines of changes across
#          multiple story-merge commits, each bearing a DSO-Story-Merge: trailer.
#   When   llm-review-dispatch-or-skip.sh is invoked pointing at the fixture.
#   Then   verify-session-provenance.sh returns exit 0;
#          the wrapper exits 0 with a 'skipped' conclusion;
#          ci-llm-review-runner.sh is NEVER invoked;
#          the output contains 'Covered by sub-PR reviews:' followed by
#          the covering story / PR identifiers.
#
# fails against the current wrapper output, which emits the informal prose
# "All commits covered by sub-PR reviews (provenance verified)." and does not
# format the sub-PR list.  The test will turn GREEN after S3.T2/T3 update the
# wrapper's skip-path output to use the structured format.
#
# Usage: bash tests/workflows/test-integration-review-skip-on-provenance.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WRAPPER="$REPO_ROOT/plugins/dso/scripts/llm-review-dispatch-or-skip.sh"
VERIFIER="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-integration-review-skip-on-provenance.sh ==="

# ── Cleanup registry ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap '_cleanup' EXIT

# ── Helper: create an isolated git repo ───────────────────────────────────────
_make_git_repo() {
    local repo
    repo="$(mktemp -d "${TMPDIR:-/tmp}/test-provenance-e2e.XXXXXX")"
    _CLEANUP_DIRS+=("$repo")
    git init -q "$repo" 2>/dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    echo "$repo"
}

# ── Helper: add N lines to a file and commit with a trailer ───────────────────
# Usage: _make_story_commit <repo> <story_id> <n_lines> [<filename>]
# Produces a commit with body:
#   DSO-Story-Merge: <story_id>
_make_story_commit() {
    local repo="$1" story_id="$2" n_lines="$3"
    local fname="${4:-story_${story_id}.py}"
    local i
    {
        for (( i = 1; i <= n_lines; i++ )); do
            printf "# line %d for story %s\n" "$i" "$story_id"
        done
    } > "$repo/$fname"
    git -C "$repo" add "$fname" >/dev/null 2>&1
    git -C "$repo" commit -q -m "$(printf 'feat: implement %s\n\nDSO-Story-Merge: %s' "$story_id" "$story_id")" 2>/dev/null
    git -C "$repo" rev-parse HEAD
}

# ── Helper: build the 6000+ line all-provenanced fixture ──────────────────────
# Returns: sets FIXTURE_REPO, FIXTURE_BASE_SHA, FIXTURE_HEAD_SHA in caller scope.
_build_large_provenanced_fixture() {
    local repo
    repo="$(_make_git_repo)"

    # Base commit (simulates "main" tip before the session branch)
    printf "# repo root\n" > "$repo/README.md"
    git -C "$repo" add README.md >/dev/null 2>&1
    git -C "$repo" commit -q -m "Initial commit" 2>/dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Story commits — distribute 6000+ lines across multiple story merges.
    # 5 story merges × 1200 lines each = 6000 lines exactly; use 1201 per
    # commit to ensure we exceed 6000 after rounding / header overhead.
    local story_ids=( "s3t1-story-aaa" "s3t1-story-bbb" "s3t1-story-ccc" "s3t1-story-ddd" "s3t1-story-eee" )
    local sid
    for sid in "${story_ids[@]}"; do
        _make_story_commit "$repo" "$sid" 1201 >/dev/null
    done

    local head_sha
    head_sha="$(git -C "$repo" rev-parse HEAD)"

    # Verify line count exceeds 6000 (sanity check inside fixture builder)
    local total_lines
    total_lines="$(git -C "$repo" diff "${base_sha}..${head_sha}" --stat=9999 \
        | tail -1 \
        | grep -oE '[0-9]+ insertion' \
        | grep -oE '[0-9]+' || echo 0)"
    if (( total_lines < 6000 )); then
        echo "WARNING: fixture diff has only ${total_lines} inserted lines (< 6000)" >&2
    fi

    FIXTURE_REPO="$repo"
    FIXTURE_BASE_SHA="$base_sha"
    FIXTURE_HEAD_SHA="$head_sha"
    FIXTURE_STORY_IDS=("${story_ids[@]}")
}

# ═════════════════════════════════════════════════════════════════════════════
# Test 1 — verifier exits 0 for all-provenanced 6000+ line fixture
# ═════════════════════════════════════════════════════════════════════════════
# Precondition: verify-session-provenance.sh must classify every DSO-Story-Merge:
# commit as provenanced and return exit 0 for the full 6000+ line range.
# This test does NOT need llm-review-dispatch-or-skip.sh; it validates the
# lower-level provenance contract that the E2E test relies on.
test_verifier_exits_0_for_large_all_provenanced_diff() {
    _snapshot_fail

    _build_large_provenanced_fixture

    local artifact_dir
    artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-provenance-artifacts.XXXXXX")"
    _CLEANUP_DIRS+=("$artifact_dir")

    local exit_code=0
    DSO_REPO_PATH="$FIXTURE_REPO" \
    DSO_BASE_SHA="$FIXTURE_BASE_SHA" \
    DSO_SESSION_HEAD="$FIXTURE_HEAD_SHA" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" 2>/dev/null || exit_code=$?

    assert_eq \
        "test_verifier_exits_0_for_large_all_provenanced_diff: verify-session-provenance.sh exits 0 for 6000+ line all-provenanced fixture" \
        "0" "$exit_code"

    # Confirm no unprovenanced-shas.txt was written (exit 0 path never writes it)
    local unprovenanced_file="$artifact_dir/unprovenanced-shas.txt"
    local has_unprovenanced="no"
    if [[ -f "$unprovenanced_file" ]] && [[ -s "$unprovenanced_file" ]]; then
        has_unprovenanced="yes"
    fi
    assert_eq \
        "test_verifier_exits_0_for_large_all_provenanced_diff: no unprovenanced-shas.txt when all commits are provenanced" \
        "no" "$has_unprovenanced"

    assert_pass_if_clean "test_verifier_exits_0_for_large_all_provenanced_diff"
}

# ═════════════════════════════════════════════════════════════════════════════
# Test 2 — E2E: wrapper skips LLM dispatch (runner NEVER invoked)
# ═════════════════════════════════════════════════════════════════════════════
# ci-llm-review-runner.sh must NEVER be invoked when
# verify-session-provenance.sh exits 0. This is the load-bearing DD4 assertion.
# grep check required by AC: grep -qE 'NEVER.*ci-llm-review-runner|assert.*not.invoked'
test_e2e_large_provenanced_pr_runner_never_invoked() {
    _snapshot_fail

    if [[ ! -f "$WRAPPER" || ! -x "$WRAPPER" ]]; then
        assert_eq \
            "test_e2e_large_provenanced_pr_runner_never_invoked: wrapper must exist to run E2E test" \
            "wrapper_exists_and_executable" "wrapper_missing_or_not_executable"
        assert_pass_if_clean "test_e2e_large_provenanced_pr_runner_never_invoked"
        return
    fi

    _build_large_provenanced_fixture

    # Mock ci-llm-review-runner.sh via DSO_RUNNER_PATH; record any invocation.
    local mock_dir
    mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-mock-runner.XXXXXX")"
    _CLEANUP_DIRS+=("$mock_dir")

    local runner_call_log="$mock_dir/runner-invocations.log"
    local mock_runner="$mock_dir/ci-llm-review-runner.sh"
    cat > "$mock_runner" <<MOCKEOF
#!/usr/bin/env bash
# Mock ci-llm-review-runner.sh — records invocation; MUST NOT be called
echo "runner-invoked-unexpectedly" >> "$runner_call_log"
exit 0
MOCKEOF
    chmod +x "$mock_runner"

    local artifact_dir
    artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-provenance-artifacts2.XXXXXX")"
    _CLEANUP_DIRS+=("$artifact_dir")

    # bug 8a77 v2 (Change B): the dispatcher consumes verifier-written
    # artifacts rather than re-invoking the verifier. Pre-run the verifier
    # to populate artifact dir — this mirrors the real ci.yml step ordering
    # (Step 1 verify-session-provenance → Step 2 llm-review-dispatch-or-skip).
    DSO_REPO_PATH="$FIXTURE_REPO" \
    DSO_BASE_SHA="$FIXTURE_BASE_SHA" \
    DSO_SESSION_HEAD="$FIXTURE_HEAD_SHA" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" >/dev/null 2>&1 || true

    # Invoke the wrapper against the populated artifact dir.
    local wrapper_exit=0
    DSO_REPO_PATH="$FIXTURE_REPO" \
    DSO_BASE_SHA="$FIXTURE_BASE_SHA" \
    DSO_SESSION_HEAD="$FIXTURE_HEAD_SHA" \
    DSO_RUNNER_PATH="$mock_runner" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" 2>/dev/null || wrapper_exit=$?

    # Assert: runner was NEVER invoked (call log must not exist or be empty)
    local runner_was_called="no"
    if [[ -f "$runner_call_log" ]] && grep -q "runner-invoked-unexpectedly" "$runner_call_log" 2>/dev/null; then
        runner_was_called="yes"
    fi
    # NEVER ci-llm-review-runner invocation: assert not.invoked
    assert_eq \
        "test_e2e_large_provenanced_pr_runner_never_invoked: ci-llm-review-runner.sh NEVER invoked for all-provenanced 6000+ line diff" \
        "no" "$runner_was_called"

    # Assert: wrapper exits 0 (skip path)
    assert_eq \
        "test_e2e_large_provenanced_pr_runner_never_invoked: wrapper exits 0 on all-provenanced diff" \
        "0" "$wrapper_exit"

    assert_pass_if_clean "test_e2e_large_provenanced_pr_runner_never_invoked"
}

# ═════════════════════════════════════════════════════════════════════════════
# Test 3 — E2E: wrapper emits 'skipped' conclusion
# ═════════════════════════════════════════════════════════════════════════════
test_e2e_large_provenanced_pr_emits_skipped_conclusion() {
    _snapshot_fail

    if [[ ! -f "$WRAPPER" || ! -x "$WRAPPER" ]]; then
        assert_eq \
            "test_e2e_large_provenanced_pr_emits_skipped_conclusion: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_e2e_large_provenanced_pr_emits_skipped_conclusion"
        return
    fi

    _build_large_provenanced_fixture

    local mock_dir
    mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-mock-runner2.XXXXXX")"
    _CLEANUP_DIRS+=("$mock_dir")

    local mock_runner="$mock_dir/ci-llm-review-runner.sh"
    cat > "$mock_runner" <<'MOCKEOF'
#!/usr/bin/env bash
echo "runner-invoked-unexpectedly"
exit 0
MOCKEOF
    chmod +x "$mock_runner"

    local artifact_dir
    artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-provenance-artifacts3.XXXXXX")"
    _CLEANUP_DIRS+=("$artifact_dir")

    # bug 8a77 v2: pre-run verifier to populate artifact dir (see Test 2 note).
    DSO_REPO_PATH="$FIXTURE_REPO" \
    DSO_BASE_SHA="$FIXTURE_BASE_SHA" \
    DSO_SESSION_HEAD="$FIXTURE_HEAD_SHA" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" >/dev/null 2>&1 || true

    local output
    output=$(
        DSO_REPO_PATH="$FIXTURE_REPO" \
        DSO_BASE_SHA="$FIXTURE_BASE_SHA" \
        DSO_SESSION_HEAD="$FIXTURE_HEAD_SHA" \
        DSO_RUNNER_PATH="$mock_runner" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    assert_contains \
        "test_e2e_large_provenanced_pr_emits_skipped_conclusion: wrapper output contains 'skipped' conclusion" \
        "skipped" "$output"

    assert_pass_if_clean "test_e2e_large_provenanced_pr_emits_skipped_conclusion"
}

# ═════════════════════════════════════════════════════════════════════════════
# Test 4 — E2E: output contains 'Covered by sub-PR reviews:' with story refs
# ═════════════════════════════════════════════════════════════════════════════
# Current wrapper emits "All commits covered by sub-PR reviews (provenance
# verified)." which does NOT include 'Covered by sub-PR reviews:' with a colon
# followed by a structured list of covering PR/story identifiers.
# This assertion fails until S3.T2/T3 update the skip-path output format.
test_e2e_output_contains_covered_by_sub_pr_reviews_with_list() {
    _snapshot_fail

    if [[ ! -f "$WRAPPER" || ! -x "$WRAPPER" ]]; then
        assert_eq \
            "test_e2e_output_contains_covered_by_sub_pr_reviews_with_list: wrapper must exist" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_e2e_output_contains_covered_by_sub_pr_reviews_with_list"
        return
    fi

    _build_large_provenanced_fixture

    local mock_dir
    mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-mock-runner3.XXXXXX")"
    _CLEANUP_DIRS+=("$mock_dir")

    local mock_runner="$mock_dir/ci-llm-review-runner.sh"
    cat > "$mock_runner" <<'MOCKEOF'
#!/usr/bin/env bash
exit 0
MOCKEOF
    chmod +x "$mock_runner"

    local artifact_dir
    artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-provenance-artifacts4.XXXXXX")"
    _CLEANUP_DIRS+=("$artifact_dir")

    # bug 8a77 v2: pre-run verifier to populate artifact dir (see Test 2 note).
    DSO_REPO_PATH="$FIXTURE_REPO" \
    DSO_BASE_SHA="$FIXTURE_BASE_SHA" \
    DSO_SESSION_HEAD="$FIXTURE_HEAD_SHA" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$VERIFIER" >/dev/null 2>&1 || true

    local output
    output=$(
        DSO_REPO_PATH="$FIXTURE_REPO" \
        DSO_BASE_SHA="$FIXTURE_BASE_SHA" \
        DSO_SESSION_HEAD="$FIXTURE_HEAD_SHA" \
        DSO_RUNNER_PATH="$mock_runner" \
        DSO_ARTIFACT_DIR="$artifact_dir" \
            bash "$WRAPPER" 2>&1
    ) || true

    # wrapper must emit 'Covered by sub-PR reviews:' (with colon)
    # followed by at least one story/PR identifier.  This fails against the current
    # implementation which emits prose without the structured colon+list format.
    local has_structured_coverage_line="no"
    if echo "$output" | grep -qE "Covered by sub-PR reviews:[[:space:]]+[^[:space:]]"; then
        has_structured_coverage_line="yes"
    fi
    assert_eq \
        "test_e2e_output_contains_covered_by_sub_pr_reviews_with_list: output contains 'Covered by sub-PR reviews:' followed by identifier list" \
        "yes" "$has_structured_coverage_line"

    assert_pass_if_clean "test_e2e_output_contains_covered_by_sub_pr_reviews_with_list"
}

# ═════════════════════════════════════════════════════════════════════════════
# Test 5 — Negative control: mixed diff (some unprovenanced) invokes runner
# ═════════════════════════════════════════════════════════════════════════════
# This negative-control test confirms the E2E fixture distinguishes correctly:
# when a 6000+ line diff contains even ONE direct commit (no trailer), the runner
# IS invoked. Validates that the skip path is not the default path.
test_e2e_mixed_diff_invokes_runner() {
    _snapshot_fail

    if [[ ! -f "$WRAPPER" || ! -x "$WRAPPER" ]]; then
        assert_eq \
            "test_e2e_mixed_diff_invokes_runner: wrapper must exist for negative-control test" \
            "wrapper_exists" "wrapper_missing"
        assert_pass_if_clean "test_e2e_mixed_diff_invokes_runner"
        return
    fi

    # Build a repo where most commits are provenanced but ONE is direct (no trailer)
    local repo
    repo="$(_make_git_repo)"

    printf "# repo root\n" > "$repo/README.md"
    git -C "$repo" add README.md >/dev/null 2>&1
    git -C "$repo" commit -q -m "Initial commit" 2>/dev/null
    local base_sha
    base_sha="$(git -C "$repo" rev-parse HEAD)"

    # Story commits — provenanced
    _make_story_commit "$repo" "neg-ctrl-story-aaa" 1000 >/dev/null
    _make_story_commit "$repo" "neg-ctrl-story-bbb" 1000 >/dev/null

    # Direct commit — NO trailer (triggers runner)
    printf "# direct work bypassing story provenance\n" > "$repo/direct_change.py"
    git -C "$repo" add "$repo/direct_change.py" >/dev/null 2>&1
    git -C "$repo" commit -q -m "Direct commit — no DSO-Story-Merge trailer" 2>/dev/null

    _make_story_commit "$repo" "neg-ctrl-story-ccc" 1000 >/dev/null

    local head_sha
    head_sha="$(git -C "$repo" rev-parse HEAD)"

    local mock_dir
    mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-mock-runner4.XXXXXX")"
    _CLEANUP_DIRS+=("$mock_dir")

    local runner_call_log="$mock_dir/runner-neg-calls.log"
    local mock_runner="$mock_dir/ci-llm-review-runner.sh"
    cat > "$mock_runner" <<MOCKEOF
#!/usr/bin/env bash
echo "runner-invoked" >> "$runner_call_log"
exit 0
MOCKEOF
    chmod +x "$mock_runner"

    # gh mock: return empty PR list for any SHA (no PR provenance)
    # gh mock: differentiate subcommands.
    #   `gh api ...commits/.../pulls`  → empty PR list (verifier path)
    #   `gh pr diff <N>`               → synthetic diff (bug 9788 fix: dispatcher
    #                                    now invokes `gh pr diff` to supply
    #                                    DSO_CI_REVIEW_DIFF_PATH to the runner)
    local mock_bin="$mock_dir/bin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" <<'MOCKEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "pr" && "${2:-}" == "diff" ]]; then
    printf 'diff --git a/direct_change.py b/direct_change.py\nnew file mode 100644\n--- /dev/null\n+++ b/direct_change.py\n+# direct work\n'
    exit 0
fi
echo '[]'
exit 0
MOCKEOF
    chmod +x "$mock_bin/gh"

    local artifact_dir
    artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-provenance-artifacts5.XXXXXX")"
    _CLEANUP_DIRS+=("$artifact_dir")

    # bug 8a77 v2: pre-run verifier so the dispatcher has artifacts to consume
    # (mirrors ci.yml Step 1 → Step 2 ordering).
    PATH="$mock_bin:$PATH" \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$head_sha" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
    DSO_GH_REPO="owner/repo" \
        bash "$VERIFIER" >/dev/null 2>&1 || true

    # bug 9788 fix: dispatcher's case-1 branch requires PR_NUMBER to call gh pr diff.
    PATH="$mock_bin:$PATH" \
    PR_NUMBER=99 \
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$base_sha" \
    DSO_SESSION_HEAD="$head_sha" \
    DSO_RUNNER_PATH="$mock_runner" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$WRAPPER" 2>/dev/null || true

    local runner_was_called="no"
    if [[ -f "$runner_call_log" ]] && grep -q "runner-invoked" "$runner_call_log" 2>/dev/null; then
        runner_was_called="yes"
    fi
    assert_eq \
        "test_e2e_mixed_diff_invokes_runner: runner IS called when at least one commit is unprovenanced (negative control)" \
        "yes" "$runner_was_called"

    assert_pass_if_clean "test_e2e_mixed_diff_invokes_runner"
}

# ═════════════════════════════════════════════════════════════════════════════
# Run all tests
# ═════════════════════════════════════════════════════════════════════════════
echo ""
test_verifier_exits_0_for_large_all_provenanced_diff
echo ""
test_e2e_large_provenanced_pr_runner_never_invoked
echo ""
test_e2e_large_provenanced_pr_emits_skipped_conclusion
echo ""
test_e2e_output_contains_covered_by_sub_pr_reviews_with_list
echo ""
test_e2e_mixed_diff_invokes_runner
echo ""

print_summary
