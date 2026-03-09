#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-claude-safe-portability.sh
# Portability smoke test: exercises the full claude-safe lifecycle against a
# minimal fixture project, verifying no hardcoded project assumptions leak through.
#
# TDD RED state: test_plugin_script_exists will FAIL because
# lockpick-workflow/scripts/claude-safe does not yet exist. The test suite
# becomes fully GREEN only after the migration (blockers 23lp, 0aas, muq8)
# is complete.
#
# Usage: bash lockpick-workflow/tests/scripts/test-claude-safe-portability.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
PLUGIN_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/claude-safe"
FIXTURE_CONFIG="$REPO_ROOT/lockpick-workflow/tests/fixtures/minimal-plugin-consumer/workflow-config.yaml"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-claude-safe-portability.sh ==="

# ── Setup: minimal git repo + stubs ──────────────────────────────────────────
TMPDIR_MAIN="$(mktemp -d)"
TMPDIR_WORKTREE="$(mktemp -d)"
SENTINEL_FILE="$TMPDIR_MAIN/worktree-create-called"

trap 'rm -rf "$TMPDIR_MAIN" "$TMPDIR_WORKTREE"' EXIT

# Initialize a bare-minimum git repo (main repo, not a worktree)
git init -q "$TMPDIR_MAIN"
git -C "$TMPDIR_MAIN" commit --allow-empty -m "init" -q

# Copy minimal fixture config
cp "$FIXTURE_CONFIG" "$TMPDIR_MAIN/workflow-config.yaml"

# Create bin/ stub directory
mkdir -p "$TMPDIR_MAIN/bin"

# Stub: worktree-create.sh — outputs the fake worktree path, records sentinel
cat > "$TMPDIR_MAIN/bin/worktree-create.sh" <<EOF
#!/usr/bin/env bash
# Stub: writes sentinel, returns fake worktree path
touch "$SENTINEL_FILE"
echo "$TMPDIR_WORKTREE"
EOF
chmod +x "$TMPDIR_MAIN/bin/worktree-create.sh"

# Stub: scripts/worktree-create.sh (the hardcoded path used by current claude-safe)
mkdir -p "$TMPDIR_MAIN/scripts"
cat > "$TMPDIR_MAIN/scripts/worktree-create.sh" <<EOF
#!/usr/bin/env bash
# Stub: writes sentinel, returns fake worktree path
touch "$SENTINEL_FILE"
echo "$TMPDIR_WORKTREE"
EOF
chmod +x "$TMPDIR_MAIN/scripts/worktree-create.sh"

# Stub: claude — exits 0 immediately (simulates real Claude binary)
cat > "$TMPDIR_MAIN/bin/claude" <<'EOF'
#!/usr/bin/env bash
# Stub: simulates Claude binary — exits 0
exit 0
EOF
chmod +x "$TMPDIR_MAIN/bin/claude"

# Initialize the fake worktree path as a git repo with .git FILE (simulating a real worktree)
# claude-safe checks: if [ -f "$REPO_ROOT/.git" ] → already in worktree → exec claude
git init -q "$TMPDIR_WORKTREE"
git -C "$TMPDIR_WORKTREE" commit --allow-empty -m "init" -q

# Export PATH so stubs take precedence
export PATH="$TMPDIR_MAIN/bin:$PATH"
export WORKFLOW_CONFIG="$TMPDIR_MAIN/workflow-config.yaml"
export CLAUDE_PLUGIN_SCRIPTS="$REPO_ROOT/lockpick-workflow/scripts"

# ── Helper: run claude-safe from TMPDIR_MAIN (non-interactively) ─────────────
_run_claude_safe() {
    (cd "$TMPDIR_MAIN" && bash "$PLUGIN_SCRIPT" "$@" < /dev/null 2>&1)
}

# ── test_plugin_script_exists ─────────────────────────────────────────────────
# RED: lockpick-workflow/scripts/claude-safe does not yet exist.
# This test will FAIL until the migration is complete.
echo ""
echo "--- test_plugin_script_exists ---"
_snapshot_fail
if [ -x "$PLUGIN_SCRIPT" ]; then
    assert_eq "test_plugin_script_exists: file exists and is executable" "yes" "yes"
else
    (( ++FAIL ))
    printf "FAIL: test_plugin_script_exists\n  expected: %s\n  actual:   not found or not executable\n" \
        "$PLUGIN_SCRIPT" >&2
fi
assert_pass_if_clean "test_plugin_script_exists"

# All remaining tests are skipped (or guarded) when the plugin script does not
# exist, because running them would fail for the wrong reason.
if [ ! -x "$PLUGIN_SCRIPT" ]; then
    echo ""
    echo "Skipping remaining tests — plugin script not yet present (expected RED state)."
    echo ""
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 1
fi

# ── test_lifecycle_exit_zero_with_minimal_config ──────────────────────────────
# Running claude-safe non-interactively (stdin=/dev/null) should exit 0.
# With stdin not a tty: skips validation prompt, skips _offer_worktree_cleanup,
# creates worktree, launches stub claude (exits 0), then exits 0.
echo ""
echo "--- test_lifecycle_exit_zero_with_minimal_config ---"
_snapshot_fail
lifecycle_exit=0
lifecycle_output=""
lifecycle_output=$(_run_claude_safe 2>&1) || lifecycle_exit=$?
assert_eq "test_lifecycle_exit_zero_with_minimal_config: exit code" "0" "$lifecycle_exit"
assert_pass_if_clean "test_lifecycle_exit_zero_with_minimal_config"

# ── test_no_undefined_variable_errors ────────────────────────────────────────
echo ""
echo "--- test_no_undefined_variable_errors ---"
_snapshot_fail
lifecycle_stderr=""
lifecycle_stderr=$(_run_claude_safe 2>&1 >/dev/null) || true
if echo "$lifecycle_stderr" | grep -qE 'unbound variable|undefined variable'; then
    (( ++FAIL ))
    printf "FAIL: test_no_undefined_variable_errors\n  stderr contained unbound/undefined variable errors:\n  %s\n" \
        "$lifecycle_stderr" >&2
else
    assert_eq "test_no_undefined_variable_errors: no unbound variable errors" "ok" "ok"
fi
assert_pass_if_clean "test_no_undefined_variable_errors"

# ── test_no_not_found_errors ──────────────────────────────────────────────────
echo ""
echo "--- test_no_not_found_errors ---"
_snapshot_fail
# Capture combined output; filter out expected stub output lines before checking
run_output_combined=""
run_output_combined=$(_run_claude_safe 2>&1) || true
# Strip lines that are expected (e.g., "Launching Claude in: ...")
unexpected_not_found=""
unexpected_not_found=$(echo "$run_output_combined" \
    | grep -v 'Launching Claude in:' \
    | grep -E 'not found|No such file' || true)
if [ -n "$unexpected_not_found" ]; then
    (( ++FAIL ))
    printf "FAIL: test_no_not_found_errors\n  unexpected 'not found' / 'No such file' in output:\n  %s\n" \
        "$unexpected_not_found" >&2
else
    assert_eq "test_no_not_found_errors: no unexpected not-found errors" "ok" "ok"
fi
assert_pass_if_clean "test_no_not_found_errors"

# ── test_no_config_related_errors ────────────────────────────────────────────
echo ""
echo "--- test_no_config_related_errors ---"
_snapshot_fail
config_errors=""
config_errors=$(echo "$run_output_combined" | grep -E 'read-config\.sh: ' || true)
if [ -n "$config_errors" ]; then
    (( ++FAIL ))
    printf "FAIL: test_no_config_related_errors\n  read-config.sh error lines found:\n  %s\n" \
        "$config_errors" >&2
else
    assert_eq "test_no_config_related_errors: no read-config.sh errors" "ok" "ok"
fi
assert_pass_if_clean "test_no_config_related_errors"

# ── test_worktree_stub_called ─────────────────────────────────────────────────
echo ""
echo "--- test_worktree_stub_called ---"
_snapshot_fail
# Reset sentinel before running
rm -f "$SENTINEL_FILE"
_run_claude_safe >/dev/null 2>&1 || true
if [ -f "$SENTINEL_FILE" ]; then
    assert_eq "test_worktree_stub_called: sentinel file created by stub" "yes" "yes"
else
    (( ++FAIL ))
    printf "FAIL: test_worktree_stub_called\n  sentinel file was not created — worktree-create stub was not called\n  expected at: %s\n" \
        "$SENTINEL_FILE" >&2
fi
assert_pass_if_clean "test_worktree_stub_called"

# ── test_cleanup_runs_without_crash ──────────────────────────────────────────
# Post-exit cleanup (_offer_worktree_cleanup) is a no-op when stdin is not a
# tty. Verify the script exits cleanly regardless (exit 0, no crash).
echo ""
echo "--- test_cleanup_runs_without_crash ---"
_snapshot_fail
cleanup_exit=0
cleanup_output=""
cleanup_output=$(_run_claude_safe 2>&1) || cleanup_exit=$?
assert_eq "test_cleanup_runs_without_crash: exit code" "0" "$cleanup_exit"
assert_pass_if_clean "test_cleanup_runs_without_crash"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
