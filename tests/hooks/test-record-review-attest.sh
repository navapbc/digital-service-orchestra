#!/usr/bin/env bash
# tests/hooks/test-record-review-attest.sh
# RED tests for record-review.sh --attest mode.
#
# The --attest flag reads a source review-status from a worktree artifacts dir
# and writes a new review-status to the session artifacts dir, transferring
# the review attestation without re-running the full review pipeline.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-review.sh"
COMPUTE_DIFF_HASH="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# --- Isolation setup ---
# Each test gets its own temp dirs for source (worktree) and session artifacts.
_TEST_TMPDIRS=()
_test_cleanup() {
    for _d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$_d" 2>/dev/null || true
    done
}
trap _test_cleanup EXIT

# Create an isolated temp dir and register it for cleanup.
_make_tmpdir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-attest-XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# Create a minimal git repo with a staged change so compute-diff-hash.sh works.
_init_git_repo() {
    local repo_dir="$1"
    git -C "$repo_dir" init --quiet 2>/dev/null
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    echo "initial" > "$repo_dir/file.txt"
    git -C "$repo_dir" add file.txt
    git -C "$repo_dir" commit -m "initial" --quiet 2>/dev/null
    # Make a change so diff hash is non-empty
    echo "changed" > "$repo_dir/file.txt"
    git -C "$repo_dir" add file.txt
}

# Write a source review-status file with given parameters.
# Usage: _write_source_review_status <dir> <status> <score> <review_hash> [<diff_hash>]
_write_source_review_status() {
    local dir="$1" status="$2" score="$3" review_hash="$4"
    local diff_hash="${5:-abc123def456}"
    mkdir -p "$dir"
    cat > "$dir/review-status" <<EOF
${status}
timestamp=2026-04-12T00:00:00Z
diff_hash=${diff_hash}
score=${score}
review_hash=${review_hash}
EOF
}

# ---------------------------------------------------------------------------
# test_attest_writes_passed_status
# Given: source review-status has status=passed
# When:  record-review.sh --attest <source-dir> is invoked
# Then:  output review-status first line is "passed"
# ---------------------------------------------------------------------------
_test_attest_writes_passed_status() {
    local repo_dir source_dir session_dir exit_code output_status

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    _write_source_review_status "$source_dir" "passed" "5" "deadbeef1234"

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    if [[ -f "$session_dir/review-status" ]]; then
        output_status=$(head -1 "$session_dir/review-status")
    else
        output_status="FILE_NOT_WRITTEN"
    fi

    assert_eq "test_attest_writes_passed_status: exit code 0" "0" "$exit_code"
    assert_eq "test_attest_writes_passed_status: status is passed" "passed" "$output_status"
}
_test_attest_writes_passed_status

# ---------------------------------------------------------------------------
# test_attest_writes_current_diff_hash
# Given: source review-status exists with status=passed
# When:  record-review.sh --attest <source-dir> is invoked in a repo with staged changes
# Then:  output diff_hash matches current compute-diff-hash.sh output
# ---------------------------------------------------------------------------
_test_attest_writes_current_diff_hash() {
    local repo_dir source_dir session_dir exit_code expected_hash actual_hash

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    _write_source_review_status "$source_dir" "passed" "4" "cafecafe1234"

    # Compute the expected diff hash from the repo
    expected_hash=$(cd "$repo_dir" && bash "$COMPUTE_DIFF_HASH") || expected_hash="COMPUTE_FAILED"

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    if [[ -f "$session_dir/review-status" ]]; then
        actual_hash=$(grep '^diff_hash=' "$session_dir/review-status" | head -1 | cut -d= -f2)
    else
        actual_hash="FILE_NOT_WRITTEN"
    fi

    assert_eq "test_attest_writes_current_diff_hash: exit code 0" "0" "$exit_code"
    assert_eq "test_attest_writes_current_diff_hash: diff_hash matches" "$expected_hash" "$actual_hash"
}
_test_attest_writes_current_diff_hash

# ---------------------------------------------------------------------------
# test_attest_preserves_source_score
# Given: source review-status has score=5
# When:  record-review.sh --attest <source-dir> is invoked
# Then:  output score=5
# ---------------------------------------------------------------------------
_test_attest_preserves_source_score() {
    local repo_dir source_dir session_dir exit_code actual_score

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    _write_source_review_status "$source_dir" "passed" "5" "aabbccdd1234"

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    if [[ -f "$session_dir/review-status" ]]; then
        actual_score=$(grep '^score=' "$session_dir/review-status" | head -1 | cut -d= -f2)
    else
        actual_score="FILE_NOT_WRITTEN"
    fi

    assert_eq "test_attest_preserves_source_score: score is 5" "5" "$actual_score"
}
_test_attest_preserves_source_score

# ---------------------------------------------------------------------------
# test_attest_preserves_review_hash
# Given: source review-status has review_hash=deadbeef1234
# When:  record-review.sh --attest <source-dir> is invoked
# Then:  output review_hash=deadbeef1234
# ---------------------------------------------------------------------------
_test_attest_preserves_review_hash() {
    local repo_dir source_dir session_dir exit_code actual_review_hash

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    _write_source_review_status "$source_dir" "passed" "4" "deadbeef1234"

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    if [[ -f "$session_dir/review-status" ]]; then
        actual_review_hash=$(grep '^review_hash=' "$session_dir/review-status" | head -1 | cut -d= -f2)
    else
        actual_review_hash="FILE_NOT_WRITTEN"
    fi

    assert_eq "test_attest_preserves_review_hash: review_hash matches" "deadbeef1234" "$actual_review_hash"
}
_test_attest_preserves_review_hash

# ---------------------------------------------------------------------------
# test_attest_includes_attest_source
# Given: source review-status is valid in a worktree artifacts dir
# When:  record-review.sh --attest <source-dir> is invoked
# Then:  output includes attest_source=<worktree-id> (the basename of source dir)
# ---------------------------------------------------------------------------
_test_attest_includes_attest_source() {
    local repo_dir source_dir session_dir exit_code actual_attest_source source_basename

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    _write_source_review_status "$source_dir" "passed" "5" "ffee1234abcd"

    source_basename=$(basename "$source_dir")

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    if [[ -f "$session_dir/review-status" ]]; then
        actual_attest_source=$(grep '^attest_source=' "$session_dir/review-status" | head -1 | cut -d= -f2)
    else
        actual_attest_source="FILE_NOT_WRITTEN"
    fi

    assert_eq "test_attest_includes_attest_source: exit code 0" "0" "$exit_code"
    # The attest_source should reference the source dir (at minimum, non-empty)
    assert_ne "test_attest_includes_attest_source: attest_source is not empty" "" "$actual_attest_source"
    assert_ne "test_attest_includes_attest_source: attest_source is not FILE_NOT_WRITTEN" "FILE_NOT_WRITTEN" "$actual_attest_source"
}
_test_attest_includes_attest_source

# ---------------------------------------------------------------------------
# test_attest_skips_overlap_check
# Given: source review-status is valid, but NO reviewer-findings.json exists
# When:  record-review.sh --attest <source-dir> is invoked
# Then:  exits 0 (overlap check is skipped; findings file not required)
# ---------------------------------------------------------------------------
_test_attest_skips_overlap_check() {
    local repo_dir source_dir session_dir exit_code

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    _write_source_review_status "$source_dir" "passed" "4" "11223344abcd"

    # Ensure NO reviewer-findings.json exists in session artifacts
    rm -f "$session_dir/reviewer-findings.json" 2>/dev/null || true

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    assert_eq "test_attest_skips_overlap_check: exits 0 without findings file" "0" "$exit_code"
}
_test_attest_skips_overlap_check

# ---------------------------------------------------------------------------
# test_attest_refuses_missing_source
# Given: source directory does NOT contain review-status
# When:  record-review.sh --attest <source-dir> is invoked
# Then:  exits non-zero
# ---------------------------------------------------------------------------
_test_attest_refuses_missing_source() {
    local repo_dir source_dir session_dir exit_code

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    # Do NOT write any review-status in source_dir

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    assert_ne "test_attest_refuses_missing_source: exits non-zero" "0" "$exit_code"
}
_test_attest_refuses_missing_source

# ---------------------------------------------------------------------------
# test_attest_refuses_failed_source
# Given: source review-status has status=failed
# When:  record-review.sh --attest <source-dir> is invoked
# Then:  exits non-zero
# ---------------------------------------------------------------------------
_test_attest_refuses_failed_source() {
    local repo_dir source_dir session_dir exit_code

    repo_dir=$(_make_tmpdir)
    source_dir=$(_make_tmpdir)
    session_dir=$(_make_tmpdir)

    _init_git_repo "$repo_dir"
    _write_source_review_status "$source_dir" "failed" "2" "baadf00d1234"

    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$session_dir"
    exit_code=0
    (cd "$repo_dir" && bash "$HOOK" --attest "$source_dir") 2>/dev/null || exit_code=$?

    assert_ne "test_attest_refuses_failed_source: exits non-zero" "0" "$exit_code"
}
_test_attest_refuses_failed_source

print_summary
