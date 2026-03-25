#!/usr/bin/env bash
# tests/hooks/test-two-layer-review-gate.sh
# End-to-end tests for the two-layer review gate.
#
# Layer 1: pre-commit-review-gate.sh (git pre-commit hook)
#   - Allowlist pass: commits with only allowlisted files pass
#   - Code block: commits with non-allowlisted files are blocked without review
#
# Layer 2: review-gate-bypass-sentinel.sh (PreToolUse hook)
#   - Bypass block: --no-verify and other bypass vectors are blocked
#
# Plus combined tests:
#   - Error messages: blocked commits output actionable error messages
#   - Formatting self-heal: hook_review_gate self-heals formatting-only hash mismatches
#   - Telemetry: hook_review_gate writes diagnostic log on hash mismatch
#
# Success criteria (6):
#   1. Allowlisted commit passes (Layer 1)
#   2. Code commit blocked without review (Layer 1)
#   3. Bypass attempts blocked by sentinel (Layer 2)
#   4. Blocked commit error messages are actionable
#   5. Formatting self-heal passes on whitespace-only diff changes
#   6. Telemetry diagnostic log written on hash mismatch block
#
# Tests:
#   test_allowlist_pass_tickets_only
#   test_allowlist_pass_docs_only
#   test_code_commit_blocked_without_review
#   test_code_commit_allowed_with_valid_review
#   test_bypass_no_verify_blocked
#   test_bypass_hooks_path_blocked
#   test_bypass_commit_tree_blocked
#   test_error_message_names_blocked_files
#   test_error_message_directs_to_commit_or_review
#   test_formatting_self_heal_passes_whitespace_only_change
#   test_telemetry_diagnostic_log_written_on_mismatch
#   test_hook_review_gate_removed_from_pre_bash_functions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PRE_COMMIT_HOOK="$DSO_PLUGIN_DIR/hooks/pre-commit-review-gate.sh"
PRE_BASH_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/review-gate-bypass-sentinel.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite checks ──────────────────────────────────────────────────────
if [[ ! -f "$PRE_COMMIT_HOOK" ]]; then
    echo "SKIP: pre-commit-review-gate.sh not found at $PRE_COMMIT_HOOK"
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
    git -C "$tmpdir" config commit.gpgsign false
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

# ── Helper: run the pre-commit hook in a test repo ────────────────────────────
# Returns exit code on stdout.
run_pre_commit_hook() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    local exit_code=0
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$PRE_COMMIT_HOOK" 2>/dev/null
    ) || exit_code=$?
    echo "$exit_code"
}

# ── Helper: capture stderr from the pre-commit hook ──────────────────────────
run_pre_commit_hook_stderr() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$PRE_COMMIT_HOOK" 2>&1 >/dev/null
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

# ── Helper: call bypass sentinel ─────────────────────────────────────────────
call_sentinel() {
    local input="$1"
    local exit_code=0
    hook_review_bypass_sentinel "$input" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ============================================================
# CRITERION 1: Allowlist pass
# ============================================================

# test_allowlist_pass_tickets_only
#
# A commit containing only .tickets-tracker/ files must pass Layer 1 without a review.
test_allowlist_pass_tickets_only() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/.tickets-tracker"
    echo "# Task: My task" > "$_repo/.tickets-tracker/lockpick-test-abc1.md"
    git -C "$_repo" add ".tickets-tracker/lockpick-test-abc1.md"

    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_allowlist_pass_tickets_only" "0" "$exit_code"
}

# test_allowlist_pass_docs_only
#
# A commit containing only docs/ files must pass Layer 1 without a review.
test_allowlist_pass_docs_only() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    mkdir -p "$_repo/docs"
    echo "# Documentation" > "$_repo/docs/README.md"
    git -C "$_repo" add "docs/README.md"

    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_allowlist_pass_docs_only" "0" "$exit_code"
}

# ============================================================
# CRITERION 2: Code commit blocked without review
# ============================================================

# test_code_commit_blocked_without_review
#
# A commit containing a .py file without a valid review-status file must be
# blocked by Layer 1 (exit 1).
test_code_commit_blocked_without_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_code_commit_blocked_without_review" "1" "$exit_code"
}

# test_code_commit_allowed_with_valid_review
#
# A commit containing a .py file WITH a valid review-status matching the
# current diff hash must be allowed by Layer 1 (exit 0).
test_code_commit_allowed_with_valid_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/main.py"
    git -C "$_repo" add "main.py"

    local diff_hash
    diff_hash=$(compute_hash_in_repo "$_repo" "$_artifacts")
    write_valid_review_status "$_artifacts" "$diff_hash"

    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_code_commit_allowed_with_valid_review" "0" "$exit_code"
}

# ============================================================
# CRITERION 3: Bypass attempts blocked
# ============================================================

# test_bypass_no_verify_blocked
#
# A git commit command with --no-verify must be blocked by the bypass sentinel.
test_bypass_no_verify_blocked() {
    local INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m msg"}}'
    local exit_code
    exit_code=$(call_sentinel "$INPUT")
    assert_eq "test_bypass_no_verify_blocked" "2" "$exit_code"
}

# test_bypass_hooks_path_blocked
#
# A git commit command with core.hooksPath override must be blocked.
test_bypass_hooks_path_blocked() {
    local INPUT='{"tool_name":"Bash","tool_input":{"command":"git -c core.hooksPath=/dev/null commit -m msg"}}'
    local exit_code
    exit_code=$(call_sentinel "$INPUT")
    assert_eq "test_bypass_hooks_path_blocked" "2" "$exit_code"
}

# test_bypass_commit_tree_blocked
#
# A git commit-tree command (low-level plumbing bypass) must be blocked.
test_bypass_commit_tree_blocked() {
    local INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit-tree abc123 -m bypass"}}'
    local exit_code
    exit_code=$(call_sentinel "$INPUT")
    assert_eq "test_bypass_commit_tree_blocked" "2" "$exit_code"
}

# ============================================================
# CRITERION 4: Error messages are actionable
# ============================================================

# test_error_message_names_blocked_files
#
# When Layer 1 blocks a commit, the error message must name the specific
# non-allowlisted file(s) that triggered the block.
test_error_message_names_blocked_files() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "print('hello')" > "$_repo/my_feature_module.py"
    git -C "$_repo" add "my_feature_module.py"

    local stderr_output
    stderr_output=$(run_pre_commit_hook_stderr "$_repo" "$_artifacts")
    assert_contains "test_error_message_names_blocked_files" \
        "my_feature_module.py" "$stderr_output"
}

# test_error_message_directs_to_commit_or_review
#
# When Layer 1 blocks a commit, the error message must direct the user to
# /commit or /review to unblock.
test_error_message_directs_to_commit_or_review() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    echo "x = 1" > "$_repo/blocked_code.py"
    git -C "$_repo" add "blocked_code.py"

    local stderr_output
    stderr_output=$(run_pre_commit_hook_stderr "$_repo" "$_artifacts")

    local found_directive=0
    if [[ "$stderr_output" == *dso:commit* ]] || [[ "$stderr_output" == *dso:review* ]]; then
        found_directive=1
    fi
    assert_eq "test_error_message_directs_to_commit_or_review" "1" "$found_directive"
}

# ============================================================
# CRITERION 5: Formatting self-heal
# ============================================================

# test_formatting_self_heal_passes_whitespace_only_change
#
# hook_review_gate in pre-bash-functions.sh auto-heals formatting-only
# hash mismatches. This test verifies the is_formatting_only_change function
# returns 0 (allow) when diffs differ only in whitespace.
#
# Tests is_formatting_only_change() directly after sourcing pre-bash-functions.sh.
test_formatting_self_heal_passes_whitespace_only_change() {
    # Source the functions file (guard ensures idempotent)
    local _loaded_ok=0
    # shellcheck source=/dev/null
    source "$PRE_BASH_FUNCTIONS" 2>/dev/null && _loaded_ok=1

    if [[ "$_loaded_ok" -ne 1 ]]; then
        assert_eq "test_formatting_self_heal_passes_whitespace_only_change: source" "1" "0"
        return
    fi

    # Two diffs identical except for trailing whitespace on one line
    local OLD_DIFF
    OLD_DIFF=$(printf 'diff --git a/f.py b/f.py\n--- a/f.py\n+++ b/f.py\n@@ -1 +1 @@\n-x = 1  \n+x = 2\n')
    local NEW_DIFF
    NEW_DIFF=$(printf 'diff --git a/f.py b/f.py\n--- a/f.py\n+++ b/f.py\n@@ -1 +1 @@\n-x = 1\n+x = 2\n')

    local result=0
    is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" || result=$?
    assert_eq "test_formatting_self_heal_passes_whitespace_only_change" "0" "$result"
}

# ============================================================
# CRITERION 6: Telemetry — hash mismatch produces actionable diagnostics
# ============================================================

# test_telemetry_diagnostic_log_written_on_mismatch
#
# In the two-layer gate, Layer 1 (pre-commit-review-gate.sh) reports a hash
# mismatch with a clear error message that includes both the recorded and
# current hash prefixes, giving developers actionable telemetry in the
# commit output.
#
# This test verifies that when a code commit is blocked due to hash mismatch,
# the error message contains the hash values for diagnostics.
test_telemetry_diagnostic_log_written_on_mismatch() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Stage a non-allowlisted file
    echo "print('hello')" > "$_repo/telemetry_test.py"
    git -C "$_repo" add "telemetry_test.py"

    # Write a review-status with a STALE hash (hash will not match current state)
    mkdir -p "$_artifacts"
    printf 'passed\ntimestamp=2026-03-14T00:00:00Z\ndiff_hash=stale000000000\nscore=5\nreview_hash=abc\n' \
        > "$_artifacts/review-status"

    # Layer 1 should block with a hash mismatch error message
    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_telemetry_diagnostic_log_written_on_mismatch: blocks on stale hash" "1" "$exit_code"

    # The error message must contain hash diagnostic information
    local stderr_output
    stderr_output=$(run_pre_commit_hook_stderr "$_repo" "$_artifacts")
    # pre-commit-review-gate.sh truncates hashes to 12 chars in error messages
    # "stale000000000" → displayed as "stale0000000..." (first 12 chars + ...)
    assert_contains "test_telemetry_diagnostic_log_written_on_mismatch: has hash info" \
        "stale0000000" "$stderr_output"
}

# ============================================================
# CRITERION: hook_review_gate removed from pre-bash-functions.sh
# (structural check — verifies the migration is complete)
# ============================================================

# test_hook_review_gate_removed_from_pre_bash_functions
#
# After migration, hook_review_gate() must NOT be defined in pre-bash-functions.sh.
# This is the key AC for Story 1idf.
# Checks that the function definition is absent (grep exits non-zero).
test_hook_review_gate_removed_from_pre_bash_functions() {
    local grep_exit=0
    grep -q 'hook_review_gate()' "$PRE_BASH_FUNCTIONS" 2>/dev/null || grep_exit=$?
    # grep_exit=1 means not found (desired); grep_exit=0 means found (fail)
    if [[ "$grep_exit" -ne 0 ]]; then
        assert_eq "test_hook_review_gate_removed_from_pre_bash_functions" "absent" "absent"
    else
        assert_eq "test_hook_review_gate_removed_from_pre_bash_functions" "absent" "present"
    fi
}

# ============================================================
# CRITERION: MERGE_HEAD exemption fires only when MERGE_HEAD actually exists
# (security check — no false-positive bypass)
# ============================================================

# test_merge_head_present_allowlisted_commit_passes
#
# When MERGE_HEAD exists in the target worktree's git dir (in-progress merge)
# and only allowlisted files are staged, Layer 1 must allow the commit.
# This is the normal merge-resolution path (e.g., resolving .tickets/ticket-data.json).
test_merge_head_present_allowlisted_commit_passes() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Write MERGE_HEAD to simulate an in-progress merge in this repo
    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)
    echo "$head_sha" > "$_repo/.git/MERGE_HEAD"

    # Stage only allowlisted files (ticket index merge resolution)
    mkdir -p "$_repo/.tickets-tracker"
    echo '{"version":2}' > "$_repo/.tickets-tracker/ticket-data.json"
    git -C "$_repo" add ".tickets-tracker/ticket-data.json"

    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_merge_head_present_allowlisted_commit_passes" "0" "$exit_code"

    rm -f "$_repo/.git/MERGE_HEAD"
}

# test_merge_head_absent_non_allowlisted_still_blocked
#
# When MERGE_HEAD does NOT exist (no in-progress merge), a non-allowlisted
# file commit without review must still be blocked. This verifies there is
# no false-positive bypass — the hook checks the actual git state.
test_merge_head_absent_non_allowlisted_still_blocked() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Confirm MERGE_HEAD does NOT exist
    if [[ -f "$_repo/.git/MERGE_HEAD" ]]; then
        rm -f "$_repo/.git/MERGE_HEAD"
    fi

    # Stage a non-allowlisted file without a review
    echo "x = 42" > "$_repo/no_merge_head.py"
    git -C "$_repo" add "no_merge_head.py"

    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_merge_head_absent_non_allowlisted_still_blocked" "1" "$exit_code"
}

# test_merge_head_present_non_allowlisted_without_review_blocked
#
# When MERGE_HEAD exists but the staged non-allowlisted file has no valid
# review, the commit must still be blocked. MERGE_HEAD alone does NOT
# bypass the review requirement — only allowlisted files bypass it.
# This is the security invariant: no false-positive bypass.
test_merge_head_present_non_allowlisted_without_review_blocked() {
    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Write MERGE_HEAD (simulating in-progress merge)
    local head_sha
    head_sha=$(git -C "$_repo" rev-parse HEAD 2>/dev/null)
    echo "$head_sha" > "$_repo/.git/MERGE_HEAD"

    # Stage a non-allowlisted file — no review recorded
    echo "def merged_fn(): pass" > "$_repo/merged_code.py"
    git -C "$_repo" add "merged_code.py"

    # No review-status file → hook must block
    local exit_code
    exit_code=$(run_pre_commit_hook "$_repo" "$_artifacts")
    assert_eq "test_merge_head_present_non_allowlisted_without_review_blocked" "1" "$exit_code"

    rm -f "$_repo/.git/MERGE_HEAD"
}

# ============================================================
# CRITERION: Test gate two-layer integration
# Layer 1: pre-commit-test-gate.sh blocks commit when test-gate-status absent
# Layer 2: bypass sentinel blocks --no-verify on a test-gate-failing commit
# ============================================================

# Helper: locate pre-commit-test-gate.sh
PRE_COMMIT_TEST_GATE="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"

# test_gate_layer1_blocks_commit_without_test_status
#
# A commit staging a .py source file that has an associated test, with no
# test-gate-status file recorded, must be blocked by Layer 1 (exit 1).
test_gate_layer1_blocks_commit_without_test_status() {
    if [[ ! -f "$PRE_COMMIT_TEST_GATE" ]]; then
        assert_eq "test_gate_layer1_blocks_commit_without_test_status: prereq" "found" "not-found"
        return
    fi

    local _repo _artifacts
    _repo=$(make_test_repo)
    _artifacts=$(make_artifacts_dir)

    # Create a source file with a corresponding test file in tests/ tree
    echo "def add(a, b): return a + b" > "$_repo/calc.py"
    mkdir -p "$_repo/tests"
    echo "def test_add(): assert add(1,2)==3" > "$_repo/tests/test_calc.py"
    git -C "$_repo" add "calc.py" "tests/test_calc.py"

    # No test-gate-status file → hook must block
    local exit_code=0
    (
        cd "$_repo"
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_artifacts"
        export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
        bash "$PRE_COMMIT_TEST_GATE" 2>/dev/null
    ) || exit_code=$?

    assert_eq "test_gate_layer1_blocks_commit_without_test_status" "1" "$exit_code"
}

# test_gate_layer2_blocks_no_verify_on_test_gate_failing_commit
#
# When Layer 1 would block (no test-gate-status), an agent attempting
# --no-verify to bypass it must be blocked by Layer 2 (bypass sentinel,
# exit 2), independently of git hooks.
test_gate_layer2_blocks_no_verify_on_test_gate_failing_commit() {
    local INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify -m \"bypass test gate\""}}'
    local exit_code
    exit_code=$(call_sentinel "$INPUT")
    assert_eq "test_gate_layer2_blocks_no_verify_on_test_gate_failing_commit" "2" "$exit_code"
}

# test_gate_layer2_blocks_direct_write_to_test_gate_status
#
# A direct write to test-gate-status (attempting to forge a passing status)
# must be blocked by Layer 2 with exit code 2.
test_gate_layer2_blocks_direct_write_to_test_gate_status() {
    local INPUT='{"tool_name":"Bash","tool_input":{"command":"echo passed > /tmp/workflow-plugin-xxx/test-gate-status"}}'
    local exit_code
    exit_code=$(call_sentinel "$INPUT")
    assert_eq "test_gate_layer2_blocks_direct_write_to_test_gate_status" "2" "$exit_code"
}

# test_gate_layer2_blocks_direct_write_to_test_exemptions
#
# A direct write to test-exemptions (attempting to forge an exemption) must
# be blocked by Layer 2 with exit code 2.
test_gate_layer2_blocks_direct_write_to_test_exemptions() {
    local INPUT='{"tool_name":"Bash","tool_input":{"command":"echo \"tests::test_slow\" > /tmp/workflow-plugin-xxx/test-exemptions"}}'
    local exit_code
    exit_code=$(call_sentinel "$INPUT")
    assert_eq "test_gate_layer2_blocks_direct_write_to_test_exemptions" "2" "$exit_code"
}

# test_gate_layer2_allows_record_test_exemption_sh
#
# A call to record-test-exemption.sh must NOT be blocked by Layer 2 —
# it is the authorized writer for the exemptions file.
test_gate_layer2_allows_record_test_exemption_sh() {
    local INPUT='{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/hooks/record-test-exemption.sh tests/unit/test_calc.py::test_slow"}}'
    local exit_code
    exit_code=$(call_sentinel "$INPUT")
    assert_eq "test_gate_layer2_allows_record_test_exemption_sh" "0" "$exit_code"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_allowlist_pass_tickets_only
test_allowlist_pass_docs_only
test_code_commit_blocked_without_review
test_code_commit_allowed_with_valid_review
test_bypass_no_verify_blocked
test_bypass_hooks_path_blocked
test_bypass_commit_tree_blocked
test_error_message_names_blocked_files
test_error_message_directs_to_commit_or_review
test_formatting_self_heal_passes_whitespace_only_change
test_telemetry_diagnostic_log_written_on_mismatch
test_hook_review_gate_removed_from_pre_bash_functions
test_merge_head_present_allowlisted_commit_passes
test_merge_head_absent_non_allowlisted_still_blocked
test_merge_head_present_non_allowlisted_without_review_blocked
test_gate_layer1_blocks_commit_without_test_status
test_gate_layer2_blocks_no_verify_on_test_gate_failing_commit
test_gate_layer2_blocks_direct_write_to_test_gate_status
test_gate_layer2_blocks_direct_write_to_test_exemptions
test_gate_layer2_allows_record_test_exemption_sh

print_summary
