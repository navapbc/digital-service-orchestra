#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # Subshell isolation for test independence (export in $() is intentional)
# shellcheck disable=SC2164         # cd into known-valid mktemp dirs in test helpers — cannot fail
# shellcheck disable=SC2155         # Declare-and-assign in subshell context — test-only pattern
# shellcheck disable=SC2069         # Redirect order in run_hook_stderr — pre-existing, intentional
# tests/hooks/test-pre-commit-review-gate.sh
# Tests for hooks/pre-commit-review-gate.sh
#
# The pre-commit hook is a git pre-commit hook that:
#   1. Reads staged files via git diff --cached --name-only
#   2. If ALL staged files match the allowlist → allow (exit 0), no review needed
#   3. If any staged file is non-allowlisted → check for valid review-status file
#      with a matching diff hash. Block (exit 1) if no valid review.
#
# Tests:
#   test_allowlisted_only_commit_passes
#   test_tickets_only_commit_passes
#   test_non_allowlisted_without_review_is_blocked
#   test_non_allowlisted_with_valid_review_passes
#   test_blocked_error_message_names_files
#   test_blocked_error_message_directs_to_commit_or_review
#   test_hook_reads_from_shared_allowlist
#
# NOTE: Merge-state tests (MERGE_HEAD, REBASE_HEAD) have been removed from this
# consumer file. Coverage is now provided by:
#   tests/hooks/test-merge-state.sh          — library unit tests
#   tests/hooks/test-merge-state-golden-path.sh — integration matrix (C1=review-gate)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
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
# Creates a minimal git repo with one initial commit.
# Returns the repo directory path on stdout.
# Caller is responsible for cleanup (or register with _TEST_TMPDIRS).
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
# Runs the hook in a subshell with an isolated temp git repo.
# WORKFLOW_PLUGIN_ARTIFACTS_DIR is set to the provided artifacts dir so
# get_artifacts_dir() returns an isolated path (no real state pollution).
#
# Usage: run_hook_in_repo <repo_dir> <artifacts_dir>
# Returns: exit code of the hook on stdout
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

# ============================================================
# test_allowlisted_only_commit_passes
#
# Staging only files that match the allowlist (e.g., .tickets-tracker/) should
# result in exit 0 — no review needed.
# ============================================================
test_allowlisted_only_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage only an allowlisted .tickets-tracker/ file
    mkdir -p "$_repo/.tickets-tracker"
    echo "ticket content" > "$_repo/.tickets-tracker/test-ticket.md"
    git -C "$_repo" add ".tickets-tracker/test-ticket.md"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_allowlisted_only_commit_passes" "0" "$exit_code"
}

# ============================================================
# test_tickets_only_commit_passes
#
# A commit with only .tickets-tracker/ changes passes without a review, per the
# Done Definition. This is the canonical "ticket metadata" exemption.
# ============================================================
test_tickets_only_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/.tickets-tracker"
    echo "# Task: My task" > "$_repo/.tickets-tracker/lockpick-test-abc1.md"
    echo '{"version":1}' > "$_repo/.tickets-tracker/test-abc1/001-create.json"
    git -C "$_repo" add ".tickets-tracker/"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_tickets_only_commit_passes" "0" "$exit_code"
}

# ============================================================
# test_non_allowlisted_without_review_is_blocked
#
# Staging a .py file without a valid review-status file should
# result in exit 1 (blocked).
# ============================================================
test_non_allowlisted_without_review_is_blocked() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a non-allowlisted Python file — no review-status file exists
    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_non_allowlisted_without_review_is_blocked" "1" "$exit_code"
}

# ============================================================
# test_non_allowlisted_with_valid_review_passes
#
# Staging a .py file WITH a valid review-status matching the current
# diff hash should result in exit 0 (allowed).
# ============================================================
test_non_allowlisted_with_valid_review_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a non-allowlisted Python file
    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    # Compute the diff hash so we can write a matching review-status
    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    local exit_code
    exit_code=$(run_hook_in_repo "$_repo" "$_artifacts")
    assert_eq "test_non_allowlisted_with_valid_review_passes" "0" "$exit_code"
}

# ============================================================
# test_blocked_error_message_names_files
#
# When a commit is blocked, the error message must name the specific
# non-allowlisted files that triggered the block.
# ============================================================
test_blocked_error_message_names_files() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a specifically named non-allowlisted file
    echo "print('hello')" > "$_repo/my_feature.py"
    git -C "$_repo" add "my_feature.py"

    local stderr_output
    stderr_output=$(run_hook_stderr "$_repo" "$_artifacts")
    assert_contains "test_blocked_error_message_names_files: names the file" \
        "my_feature.py" "$stderr_output"
}

# ============================================================
# test_blocked_error_message_directs_to_commit_or_review
#
# The error message must direct the user to /commit or /review.
# ============================================================
test_blocked_error_message_directs_to_commit_or_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/blocked.py"
    git -C "$_repo" add "blocked.py"

    local stderr_output
    stderr_output=$(run_hook_stderr "$_repo" "$_artifacts")

    # Error message must mention /dso:commit or /dso:review (qualified skill refs)
    local found_directive=0
    if [[ "$stderr_output" == *dso:commit* ]] || [[ "$stderr_output" == *dso:review* ]]; then
        found_directive=1
    fi
    assert_eq "test_blocked_error_message_directs_to_commit_or_review" "1" "$found_directive"
}

# ============================================================
# test_hook_reads_from_shared_allowlist
#
# The hook script must reference review-gate-allowlist.conf — verified
# by grep (the hook must read from the shared allowlist file, not have
# hardcoded patterns).
# ============================================================
test_hook_reads_from_shared_allowlist() {
    local found
    found=$(grep -c 'review-gate-allowlist.conf' "$HOOK" 2>/dev/null || echo "0")
    if [[ "$found" -gt 0 ]]; then
        assert_eq "test_hook_reads_from_shared_allowlist" "true" "true"
    else
        assert_eq "test_hook_reads_from_shared_allowlist" "true" "false"
    fi
}

# ============================================================
# test_formatting_only_drift_self_heals
#
# When review passes and then ruff auto-formatting reformats a staged .py
# file (whitespace/style only), the pre-commit hook should detect that the
# drift is formatting-only, re-compute the hash, update review-status, and
# allow the commit (exit 0) without requiring re-review.
#
# Simulates: review → ruff reformats file → commit attempt
# Expected: self-heal → exit 0
# ============================================================
test_formatting_only_drift_self_heals() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Find ruff binary
    local ruff_bin
    ruff_bin=$(command -v ruff 2>/dev/null || echo "$REPO_ROOT/app/.venv/bin/ruff")
    if [[ ! -x "$ruff_bin" ]]; then
        echo "SKIP: test_formatting_only_drift_self_heals — ruff not available"
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

    # Now stage a modification that has ONLY poor formatting (as a developer might write).
    # The logic is the same as HEAD — only whitespace/style changed, no new code.
    # This is what the developer staged and got reviewed — unformatted.
    cat > "$_repo/mymodule.py" << 'PYEOF'
def hello( name ):
    return "hello " + name
PYEOF
    git -C "$_repo" add "mymodule.py"

    # Compute the diff hash in the current (unformatted) state — this simulates
    # the hash captured at review time
    local diff_hash_before
    diff_hash_before=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_before"

    # Simulate ruff reformatting the staged file (like the auto-format pre-commit hook)
    # Run ruff format on the file and re-stage it
    "$ruff_bin" format "$_repo/mymodule.py" 2>/dev/null || true
    git -C "$_repo" add "mymodule.py"

    # At this point: review-status has the old hash, but staged content was ruff-formatted
    # The hash will now differ. The hook should self-heal (formatting-only drift).
    local exit_code
    exit_code=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        export PATH="$(dirname "$ruff_bin"):$PATH"
        bash "$HOOK" 2>/dev/null; echo $?
    )

    assert_eq "test_formatting_only_drift_self_heals: hook exits 0" "0" "$exit_code"
}

# ============================================================
# test_code_change_after_review_blocked
#
# When review passes, then a substantive code change (not just formatting)
# is made to a staged .py file, the pre-commit hook should still block the
# commit (exit 1), even if the change happens to include ruff-formatted code.
#
# Simulates: review → real code change made → commit attempt
# Expected: blocked → exit 1
# ============================================================
test_code_change_after_review_blocked() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Find ruff binary
    local ruff_bin
    ruff_bin=$(command -v ruff 2>/dev/null || echo "$REPO_ROOT/app/.venv/bin/ruff")
    if [[ ! -x "$ruff_bin" ]]; then
        echo "SKIP: test_code_change_after_review_blocked — ruff not available"
        (( PASS++ ))
        return
    fi

    # Commit an initial Python file to HEAD so it has a base version
    cat > "$_repo/feature.py" << 'PYEOF'
def compute(x):
    return x * 2
PYEOF
    git -C "$_repo" add "feature.py"
    git -C "$_repo" commit -q -m "add feature"

    # Stage a modification with the same content (already formatted) — simulate review
    # (developer stages the file in its original reviewed state)
    git -C "$_repo" add "feature.py"

    # Compute the diff hash in the current state — simulate review
    local diff_hash_before
    diff_hash_before=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_before"

    # Now simulate a real code change after review (new function added — not just formatting)
    cat > "$_repo/feature.py" << 'PYEOF'
def compute(x):
    return x * 2


def new_function(y):
    return y + 100
PYEOF
    git -C "$_repo" add "feature.py"

    # At this point: review-status has the old hash, real code was added after review.
    # The hook should NOT self-heal — must block with exit 1.
    local exit_code
    exit_code=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        export PATH="$(dirname "$ruff_bin"):$PATH"
        bash "$HOOK" 2>/dev/null; echo $?
    )

    assert_eq "test_code_change_after_review_blocked: hook exits 1" "1" "$exit_code"
}

# ============================================================
# test_shellcheck_disable_only_drift_self_heals
#
# When a shellcheck directive comment (# shellcheck disable=...) is added to a
# staged .sh file after review but before commit, the pre-commit hook should
# self-heal the diff hash and allow the commit (exit 0) without requiring a
# full re-review.
#
# Simulates: review -> shellcheck directive added to .sh file -> commit attempt
# Expected: self-healed -> exit 0
# ============================================================
test_shellcheck_disable_only_drift_self_heals() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Commit an initial shell script to HEAD so it has a base version
    cat > "$_repo/myscript.sh" << 'SHEOF'
#!/usr/bin/env bash
my_func() {
    local arr=()
    for item in $1; do
        arr+=("$item")
    done
    echo "${arr[@]}"
}
SHEOF
    chmod +x "$_repo/myscript.sh"
    git -C "$_repo" add "myscript.sh"
    git -C "$_repo" commit -q -m "add script"

    # Stage the file in its original state -- simulate what was reviewed
    git -C "$_repo" add "myscript.sh"

    # Compute the diff hash before adding the shellcheck directive -- simulate review
    local diff_hash_before
    diff_hash_before=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_before"

    # Add a shellcheck disable directive to the .sh file (non-functional change)
    cat > "$_repo/myscript.sh" << 'SHEOF'
#!/usr/bin/env bash
my_func() {
    local arr=()
    # shellcheck disable=SC2206
    for item in $1; do
        arr+=("$item")
    done
    echo "${arr[@]}"
}
SHEOF
    chmod +x "$_repo/myscript.sh"
    git -C "$_repo" add "myscript.sh"

    # At this point: review-status has the old hash, but only a shellcheck directive was added.
    # The hash will now differ. The hook should self-heal (shellcheck-directive-only drift).
    local exit_code
    exit_code=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$HOOK" 2>/dev/null; echo $?
    )

    assert_eq "test_shellcheck_disable_only_drift_self_heals: hook exits 0" "0" "$exit_code"
}

# ============================================================
# test_shellcheck_disable_with_real_code_change_blocked
#
# When a shellcheck directive comment AND a real code change are both added to a
# staged .sh file after review, the pre-commit hook should still block (exit 1)
# because there is a real code change beyond the directive comment.
#
# Simulates: review -> shellcheck directive + real code change -> commit attempt
# Expected: blocked -> exit 1
# ============================================================
test_shellcheck_disable_with_real_code_change_blocked() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Commit an initial shell script to HEAD
    cat > "$_repo/myscript.sh" << 'SHEOF'
#!/usr/bin/env bash
my_func() {
    echo "hello"
}
SHEOF
    chmod +x "$_repo/myscript.sh"
    git -C "$_repo" add "myscript.sh"
    git -C "$_repo" commit -q -m "add script"

    # Stage the original file -- simulate reviewed state
    git -C "$_repo" add "myscript.sh"

    # Compute the diff hash -- simulate review at this state
    local diff_hash_before
    diff_hash_before=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash_before"

    # Add both a shellcheck directive AND a real new function (substantive change)
    cat > "$_repo/myscript.sh" << 'SHEOF'
#!/usr/bin/env bash
my_func() {
    echo "hello"
}

# shellcheck disable=SC2120
new_function() {
    echo "new behavior added after review"
}
SHEOF
    chmod +x "$_repo/myscript.sh"
    git -C "$_repo" add "myscript.sh"

    # At this point: review-status has the old hash, real code was added after review.
    # The hook should NOT self-heal -- must block with exit 1.
    local exit_code
    exit_code=$(
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$HOOK" 2>/dev/null; echo $?
    )

    assert_eq "test_shellcheck_disable_with_real_code_change_blocked: hook exits 1" "1" "$exit_code"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_allowlisted_only_commit_passes
test_tickets_only_commit_passes
test_non_allowlisted_without_review_is_blocked
test_non_allowlisted_with_valid_review_passes
test_blocked_error_message_names_files
test_blocked_error_message_directs_to_commit_or_review
test_hook_reads_from_shared_allowlist
test_formatting_only_drift_self_heals
test_code_change_after_review_blocked
test_shellcheck_disable_only_drift_self_heals
test_shellcheck_disable_with_real_code_change_blocked

print_summary
