#!/usr/bin/env bash
# tests/hooks/test-review-gate-telemetry.sh
# Tests for telemetry logging in hooks/pre-commit-review-gate.sh
#
# The pre-commit hook logs each gate decision (block or pass) to a JSONL
# telemetry file at $ARTIFACTS_DIR/review-gate-telemetry.jsonl.
#
# Each entry must contain: timestamp, outcome, staged_files, review_status_present,
# hash_match fields.
#
# Tests:
#   test_telemetry_file_created_on_pass
#   test_telemetry_file_created_on_block
#   test_telemetry_entry_has_required_fields
#   test_telemetry_outcome_pass_on_valid_review
#   test_telemetry_outcome_block_on_no_review
#   test_telemetry_appends_multiple_entries
#   test_telemetry_review_status_present_false_when_missing
#   test_telemetry_hash_match_true_on_valid_review

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/pre-commit-review-gate.sh"
ALLOWLIST="$PLUGIN_ROOT/hooks/lib/review-gate-allowlist.conf"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$PLUGIN_ROOT/hooks/lib/deps.sh"

# -- Cleanup on exit --
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# -- Prerequisite checks --
if [[ ! -f "$HOOK" ]]; then
    echo "SKIP: pre-commit-review-gate.sh not found at $HOOK"
    exit 0
fi

if [[ ! -x "$HOOK" ]]; then
    echo "FAIL: pre-commit-review-gate.sh is not executable"
    (( FAIL++ ))
fi

if [[ ! -f "$ALLOWLIST" ]]; then
    echo "SKIP: review-gate-allowlist.conf not found at $ALLOWLIST"
    exit 0
fi

# -- Helper: create a fresh isolated git repo --
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add -A
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# -- Helper: create a fresh artifacts directory --
make_artifacts_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# -- Helper: run the hook in a test repo --
run_hook_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
        bash "$HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# -- Helper: write a valid review-status file --
write_valid_review_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'passed\ntimestamp=2026-03-15T00:00:00Z\ndiff_hash=%s\nscore=5\nreview_hash=abc123\n' \
        "$diff_hash" > "$artifacts_dir/review-status"
}

# -- Helper: compute the diff hash for staged files in a repo --
compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
        bash "$PLUGIN_ROOT/hooks/compute-diff-hash.sh" 2>/dev/null
    )
}

# -- Helper: read the last JSONL line from telemetry file --
read_last_telemetry_entry() {
    local artifacts_dir="$1"
    local telemetry_file="$artifacts_dir/review-gate-telemetry.jsonl"
    if [[ -f "$telemetry_file" ]]; then
        tail -1 "$telemetry_file"
    else
        echo ""
    fi
}

# ============================================================
# test_telemetry_file_created_on_pass
#
# When the hook exits 0 (allowed via valid review), a telemetry
# file must be created.
# ============================================================
test_telemetry_file_created_on_pass() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local telemetry_file="$_artifacts/review-gate-telemetry.jsonl"
    local file_exists=0
    [[ -f "$telemetry_file" ]] && file_exists=1
    assert_eq "test_telemetry_file_created_on_pass" "1" "$file_exists"
}

# ============================================================
# test_telemetry_file_created_on_block
#
# When the hook exits 1 (blocked), a telemetry file must exist.
# ============================================================
test_telemetry_file_created_on_block() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local telemetry_file="$_artifacts/review-gate-telemetry.jsonl"
    local file_exists=0
    [[ -f "$telemetry_file" ]] && file_exists=1
    assert_eq "test_telemetry_file_created_on_block" "1" "$file_exists"
}

# ============================================================
# test_telemetry_entry_has_required_fields
#
# Each telemetry JSONL entry must contain the required fields:
# timestamp, outcome, staged_files, review_status_present, hash_match.
# ============================================================
test_telemetry_entry_has_required_fields() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local entry
    entry=$(read_last_telemetry_entry "$_artifacts")

    assert_contains "test_telemetry_entry_has_required_fields: timestamp" \
        '"timestamp"' "$entry"
    assert_contains "test_telemetry_entry_has_required_fields: outcome" \
        '"outcome"' "$entry"
    assert_contains "test_telemetry_entry_has_required_fields: staged_files" \
        '"staged_files"' "$entry"
    assert_contains "test_telemetry_entry_has_required_fields: review_status_present" \
        '"review_status_present"' "$entry"
    assert_contains "test_telemetry_entry_has_required_fields: hash_match" \
        '"hash_match"' "$entry"
}

# ============================================================
# test_telemetry_outcome_pass_on_valid_review
#
# When a non-allowlisted commit passes (valid review present),
# the telemetry entry must have outcome="pass".
# ============================================================
test_telemetry_outcome_pass_on_valid_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local entry
    entry=$(read_last_telemetry_entry "$_artifacts")
    assert_contains "test_telemetry_outcome_pass_on_valid_review" \
        '"outcome":"pass"' "$entry"
}

# ============================================================
# test_telemetry_outcome_block_on_no_review
#
# When a non-allowlisted commit is blocked (no review),
# the telemetry entry must have outcome="block".
# ============================================================
test_telemetry_outcome_block_on_no_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local entry
    entry=$(read_last_telemetry_entry "$_artifacts")
    assert_contains "test_telemetry_outcome_block_on_no_review" \
        '"outcome":"block"' "$entry"
}

# ============================================================
# test_telemetry_appends_multiple_entries
#
# Running the hook multiple times appends multiple lines to the
# telemetry file (JSONL append, not overwrite).
# ============================================================
test_telemetry_appends_multiple_entries() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true
    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local telemetry_file="$_artifacts/review-gate-telemetry.jsonl"
    local line_count=0
    if [[ -f "$telemetry_file" ]]; then
        line_count=$(wc -l < "$telemetry_file" | tr -d ' ')
    fi

    local has_multiple=0
    [[ "$line_count" -ge 2 ]] && has_multiple=1
    assert_eq "test_telemetry_appends_multiple_entries" "1" "$has_multiple"
}

# ============================================================
# test_telemetry_review_status_present_false_when_missing
#
# When no review-status file exists, the telemetry entry must
# have review_status_present=false.
# ============================================================
test_telemetry_review_status_present_false_when_missing() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"
    rm -f "$_artifacts/review-status"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local entry
    entry=$(read_last_telemetry_entry "$_artifacts")
    assert_contains "test_telemetry_review_status_present_false_when_missing" \
        '"review_status_present":false' "$entry"
}

# ============================================================
# test_telemetry_hash_match_true_on_valid_review
#
# When a valid review-status with matching hash exists, the
# telemetry entry must have hash_match=true.
# ============================================================
test_telemetry_hash_match_true_on_valid_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    run_hook_in_repo "$_repo" "$_artifacts" >/dev/null 2>&1 || true

    local entry
    entry=$(read_last_telemetry_entry "$_artifacts")
    assert_contains "test_telemetry_hash_match_true_on_valid_review" \
        '"hash_match":true' "$entry"
}

# -- Run all tests --
test_telemetry_file_created_on_pass
test_telemetry_file_created_on_block
test_telemetry_entry_has_required_fields
test_telemetry_outcome_pass_on_valid_review
test_telemetry_outcome_block_on_no_review
test_telemetry_appends_multiple_entries
test_telemetry_review_status_present_false_when_missing
test_telemetry_hash_match_true_on_valid_review

print_summary
