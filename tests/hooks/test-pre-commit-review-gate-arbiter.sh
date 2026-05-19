#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # Subshell isolation for test independence (export in $() is intentional)
# shellcheck disable=SC2164         # cd into known-valid mktemp dirs in test helpers — cannot fail
# shellcheck disable=SC2155         # Declare-and-assign in subshell context — test-only pattern
# shellcheck disable=SC2069         # Redirect order in run_hook_stderr — pre-existing, intentional
# tests/hooks/test-pre-commit-review-gate-arbiter.sh
# RED tests for arbiter-rulings.json check in hooks/pre-commit-review-gate.sh
#
# These tests verify that pre-commit-review-gate.sh reads and enforces
# arbiter-rulings.json when present in WORKFLOW_PLUGIN_ARTIFACTS_DIR.
#
# The pre-commit hook does NOT currently implement this check — all tests
# except test_no_arbiter_sidecar_preserves_existing_behavior are expected
# to FAIL (RED state).
#
# Tests:
#   test_arbiter_block_for_current_sha_blocks_commit
#   test_arbiter_drop_only_does_not_block
#   test_arbiter_block_for_different_sha_ignored
#   test_no_arbiter_sidecar_preserves_existing_behavior
#   test_corrupt_arbiter_sidecar_fails_closed_with_warning
#   test_self_heal_path_still_checks_arbiter_block

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-review-gate.sh"
ALLOWLIST="$DSO_PLUGIN_DIR/hooks/lib/review-gate-allowlist.conf"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite checks ──────────────────────────────────────────────────────
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

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
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

# ── Helper: create a fresh artifacts directory ────────────────────────────────
make_artifacts_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    echo "$tmpdir"
}

# ── Helper: run the hook in a test repo ──────────────────────────────────────
run_hook_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: capture stderr from the hook ────────────────────────────────────
run_hook_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$HOOK" 2>&1 >/dev/null
    ) || true
}

# ── Helper: write a valid review-status file ────────────────────────────────
write_valid_review_status() {
    local artifacts_dir="$1"
    local diff_hash="$2"
    mkdir -p "$artifacts_dir"
    printf 'passed\ntimestamp=2026-03-15T00:00:00Z\ndiff_hash=%s\nscore=5\nreview_hash=abc123\n' \
        "$diff_hash" > "$artifacts_dir/review-status"
}

# ── Helper: compute the diff hash for staged files in a repo ────────────────
compute_hash_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null
    )
}

# ── Helper: write an arbiter-rulings.json sidecar ────────────────────────────
# Usage: write_arbiter_rulings <artifacts_dir> <commit_sha> <ruling> <rationale> <block_count>
write_arbiter_rulings() {
    local artifacts_dir="$1"
    local commit_sha="$2"
    local ruling="$3"
    local rationale="$4"
    local block_count="$5"
    mkdir -p "$artifacts_dir"
    printf '{"schema_version":"1.0.0","commit_sha":"%s","rulings":[{"ruling":"%s","rationale":"%s"}],"summary":{"block_count":%s}}\n' \
        "$commit_sha" "$ruling" "$rationale" "$block_count" \
        > "$artifacts_dir/arbiter-rulings.json"
}

# ============================================================
# test_arbiter_block_for_current_sha_blocks_commit
#
# When arbiter-rulings.json has a BLOCK ruling for the current HEAD SHA,
# the pre-commit hook must exit 1 and include the rationale in stderr.
# ============================================================
test_arbiter_block_for_current_sha_blocks_commit() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a non-allowlisted file and write matching review-status so the
    # existing review gate passes — isolating the arbiter check.
    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    # Get current HEAD sha from the test repo
    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD)

    # Write arbiter sidecar with a BLOCK ruling for this SHA
    write_arbiter_rulings "$_artifacts" "$head_sha" "BLOCK" "critical bug" "1"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_arbiter_block_for_current_sha_blocks_commit: exit code" "1" "$exit_code"

    local stderr_output
    stderr_output=$(run_hook_stderr "$_repo" "$_artifacts")
    assert_contains "test_arbiter_block_for_current_sha_blocks_commit: rationale in stderr" \
        "critical bug" "$stderr_output"
}

# ============================================================
# test_arbiter_drop_only_does_not_block
#
# When arbiter-rulings.json has only DROP/DEFER rulings (block_count=0),
# the hook must exit 0 — non-BLOCK rulings are advisory only.
# ============================================================
test_arbiter_drop_only_does_not_block() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD)

    # Write arbiter sidecar with only DROP rulings and block_count=0
    mkdir -p "$_artifacts"
    printf '{"schema_version":"1.0.0","commit_sha":"%s","rulings":[{"ruling":"DROP","rationale":"noise"},{"ruling":"DEFER","rationale":"low priority"}],"summary":{"block_count":0}}\n' \
        "$head_sha" > "$_artifacts/arbiter-rulings.json"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_arbiter_drop_only_does_not_block: exit code" "0" "$exit_code"
}

# ============================================================
# test_arbiter_block_for_different_sha_ignored
#
# When arbiter-rulings.json has commit_sha that does NOT match current HEAD,
# the sidecar is stale and must be ignored — hook exits 0.
# ============================================================
test_arbiter_block_for_different_sha_ignored() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    # Write sidecar with a DIFFERENT (old) sha — hook must ignore it
    write_arbiter_rulings "$_artifacts" "old-sha-deadbeef000000000000000000000000000" "BLOCK" "stale block" "1"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_arbiter_block_for_different_sha_ignored: exit code" "0" "$exit_code"
}

# ============================================================
# test_no_arbiter_sidecar_preserves_existing_behavior
#
# When no arbiter-rulings.json exists, existing gate behavior is unchanged:
# valid review-status with matching hash → exit 0.
# This test is expected to PASS even before the feature is implemented.
# ============================================================
test_no_arbiter_sidecar_preserves_existing_behavior() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    # Ensure no arbiter sidecar exists
    rm -f "$_artifacts/arbiter-rulings.json"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_no_arbiter_sidecar_preserves_existing_behavior: exit code" "0" "$exit_code"
}

# ============================================================
# test_corrupt_arbiter_sidecar_fails_closed_with_warning
#
# When arbiter-rulings.json contains malformed JSON, the hook must
# fail closed (exit 1) and emit a WARNING about the parse failure to stderr.
# ============================================================
test_corrupt_arbiter_sidecar_fails_closed_with_warning() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    # Write malformed JSON to the sidecar
    mkdir -p "$_artifacts"
    printf '{this is not valid json!!!' > "$_artifacts/arbiter-rulings.json"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_corrupt_arbiter_sidecar_fails_closed_with_warning: exit code" "1" "$exit_code"

    local stderr_output
    stderr_output=$(run_hook_stderr "$_repo" "$_artifacts")
    assert_contains "test_corrupt_arbiter_sidecar_fails_closed_with_warning: WARNING in stderr" \
        "WARNING" "$stderr_output"
}

# ============================================================
# test_self_heal_path_still_checks_arbiter_block
#
# REGRESSION GUARD: When the self-heal path (formatting-only drift) would
# normally exit 0, a BLOCK ruling in arbiter-rulings.json must still prevent
# the commit. Without the fix, self-heal's `exit 0` bypasses the arbiter check.
#
# Simulates: reviewed state → ruff reformats file → arbiter BLOCK present
# Expected: exit 1 with BLOCK rationale in stderr
# ============================================================
test_self_heal_path_still_checks_arbiter_block() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Find ruff binary
    local ruff_bin
    ruff_bin=$(command -v ruff 2>/dev/null || echo "$PLUGIN_ROOT/app/.venv/bin/ruff")
    if [[ ! -x "$ruff_bin" ]]; then
        echo "SKIP: test_self_heal_path_still_checks_arbiter_block — ruff not available"
        (( PASS++ ))
        return
    fi

    # Commit an initial already-formatted Python file to HEAD so it has a base version
    cat > "$_repo/mymodule.py" << 'PYEOF'
def hello(name):
    return "hello " + name
PYEOF
    git -C "$_repo" add "mymodule.py"
    git -C "$_repo" commit -q -m "add mymodule"

    # Stage a modification with poor formatting only (no logic change)
    cat > "$_repo/mymodule.py" << 'PYEOF'
def hello( name ):
    return "hello " + name
PYEOF
    git -C "$_repo" add "mymodule.py"

    # Capture hash in unformatted state — simulate what was reviewed
    local diff_hash_before
    diff_hash_before=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_before"

    # Simulate ruff reformatting the staged file (like the auto-format pre-commit hook)
    "$ruff_bin" format "$_repo/mymodule.py" 2>/dev/null || true
    git -C "$_repo" add "mymodule.py"

    # Get current HEAD sha and write arbiter BLOCK ruling
    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD)
    write_arbiter_rulings "$_artifacts" "$head_sha" "BLOCK" "arbiter says no" "1"

    # Without fix: self-heal exits 0 before arbiter check → arbiter ignored
    # With fix: arbiter check runs even on self-heal path → exits 1
    local exit_code
    exit_code=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        export PATH="$(dirname "$ruff_bin"):$PATH"
        bash "$HOOK" 2>/dev/null; echo $?
    )
    assert_eq "test_self_heal_path_still_checks_arbiter_block: exit code" "1" "$exit_code"

    local stderr_output
    stderr_output=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        export PATH="$(dirname "$ruff_bin"):$PATH"
        bash "$HOOK" 2>&1 >/dev/null || true
    )
    assert_contains "test_self_heal_path_still_checks_arbiter_block: rationale in stderr" \
        "arbiter says no" "$stderr_output"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_arbiter_block_for_current_sha_blocks_commit
test_arbiter_drop_only_does_not_block
test_arbiter_block_for_different_sha_ignored
test_no_arbiter_sidecar_preserves_existing_behavior
test_corrupt_arbiter_sidecar_fails_closed_with_warning
test_self_heal_path_still_checks_arbiter_block

print_summary
