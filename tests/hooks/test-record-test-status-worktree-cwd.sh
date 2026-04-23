#!/usr/bin/env bash
set -euo pipefail
# tests/hooks/test-record-test-status-worktree-cwd.sh
# Tests for hooks/record-test-status.sh — worktree CWD scenario (c7f3-3de6)
#
# Bug: when record-test-status.sh is invoked with CWD set to a DSO plugin
# worktree (not the host project), git rev-parse --show-toplevel returns the
# worktree path. The script then uses the WRONG REPO_ROOT to resolve test files
# and the artifacts directory, producing a silent no-op (doc-only-exempt written
# to wrong artifacts dir) instead of running the actual host-project tests.
#
# Fix: use PROJECT_ROOT (or CLAUDE_PROJECT_DIR) env var to override git-based
# root resolution when the CWD does not match the project being tested.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/record-test-status.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Disable commit signing for test git repos
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

# Helper: create an isolated temp git repo with initial commit
create_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-worktree-cwd-XXXXXX")
    git -C "$tmpdir" init --quiet 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add .gitkeep
    git -C "$tmpdir" commit -m "initial" --quiet 2>/dev/null
    echo "$tmpdir"
}

# ============================================================
# test_worktree_cwd_uses_project_root
#
# Scenario: record-test-status.sh is invoked from a "DSO worktree" CWD
# (a different git repo), but the --source-file refers to a file in a
# separate "host project" repo. PROJECT_ROOT is set to the host project.
#
# Before fix: REPO_ROOT is set via `git rev-parse --show-toplevel` from
#   the worktree CWD, returning the worktree path. Test files in the host
#   project are never found. No tests run. A doc-only-exempt "passed" is
#   written to the wrong artifacts dir (keyed by the worktree path).
#
# After fix: REPO_ROOT resolution uses PROJECT_ROOT (from resolve_repo_root()
#   in deps.sh) before falling back to git rev-parse. The host project's
#   tests are found and run. The test-gate-status is written correctly.
# ============================================================
echo ""
echo "=== test_worktree_cwd_uses_project_root ==="
_snapshot_fail

# --- Set up the "host project" repo ---
HOST_PROJECT=$(create_test_repo)
HOST_ARTIFACTS=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-wt-artifacts-XXXXXX")
trap 'rm -rf "$HOST_PROJECT" "$HOST_ARTIFACTS"' EXIT

mkdir -p "$HOST_PROJECT/src" "$HOST_PROJECT/tests"

# Create source file and associated test in the host project
cat > "$HOST_PROJECT/src/migrate.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "migrate"
SHEOF
cat > "$HOST_PROJECT/tests/test-migrate.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_migrate_runs: PASS"
exit 0
SHEOF
chmod +x "$HOST_PROJECT/tests/test-migrate.sh"

git -C "$HOST_PROJECT" add -A
git -C "$HOST_PROJECT" commit -m "add migrate" --quiet 2>/dev/null

# Stage a change to the source file (creates the diff that --source-file refers to)
echo "# changed" >> "$HOST_PROJECT/src/migrate.sh"
git -C "$HOST_PROJECT" add src/migrate.sh

# --- Set up a "DSO worktree" — a separate git repo to simulate the worktree CWD ---
DSO_WORKTREE=$(create_test_repo)
trap 'rm -rf "$HOST_PROJECT" "$HOST_ARTIFACTS" "$DSO_WORKTREE"' EXIT

# Create unrelated files in the "DSO worktree" so it has tests/ too
# (ensures the bug is reproducible: worktree has its own tests/ directory)
mkdir -p "$DSO_WORKTREE/tests" "$DSO_WORKTREE/plugins"
cat > "$DSO_WORKTREE/tests/test-unrelated.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_unrelated: PASS"
exit 0
SHEOF
chmod +x "$DSO_WORKTREE/tests/test-unrelated.sh"
git -C "$DSO_WORKTREE" add -A
git -C "$DSO_WORKTREE" commit -m "worktree files" --quiet 2>/dev/null

# --- Run the hook from the DSO worktree CWD with PROJECT_ROOT pointing to host project ---
# The hook should use PROJECT_ROOT (not git rev-parse in the DSO worktree)
# to find the host project's tests and artifacts dir.
EXIT_CODE_WT=$(
    cd "$DSO_WORKTREE"
    PROJECT_ROOT="$HOST_PROJECT" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$HOST_ARTIFACTS" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --source-file "src/migrate.sh" 2>/dev/null || echo $?
)
# Normalize: bash substitution doesn't propagate the exit code via $?; handle both forms
# When the subshell exits 0, EXIT_CODE_WT is empty from the echo (no echo ran).
EXIT_CODE_WT="${EXIT_CODE_WT:-0}"

assert_eq "worktree_cwd: hook exits 0" "0" "$EXIT_CODE_WT"

# The test-gate-status file must exist in the HOST_ARTIFACTS dir
if [[ -f "$HOST_ARTIFACTS/test-gate-status" ]]; then
    STATUS_LINE=$(head -1 "$HOST_ARTIFACTS/test-gate-status" 2>/dev/null || echo "missing")
    assert_eq "worktree_cwd: status is passed" "passed" "$STATUS_LINE"

    # The tested_files field must reference the HOST PROJECT's test file, not unrelated worktree tests
    TESTED_LINE=$(grep '^tested_files=' "$HOST_ARTIFACTS/test-gate-status" 2>/dev/null || echo "")
    assert_contains "worktree_cwd: tested_files contains host project test" "test-migrate" "$TESTED_LINE"

    # Must NOT contain the DSO worktree's unrelated test file
    if [[ "$TESTED_LINE" == *"test-unrelated"* ]]; then
        (( ++FAIL ))
        printf "FAIL: worktree_cwd: tested_files must NOT contain DSO worktree's unrelated test\n  actual: %s\n" \
            "$TESTED_LINE" >&2
    else
        (( ++PASS ))
    fi
else
    assert_eq "worktree_cwd: test-gate-status file exists in host artifacts dir" "exists" "missing"
fi

rm -rf "$HOST_PROJECT" "$HOST_ARTIFACTS" "$DSO_WORKTREE"
trap - EXIT

assert_pass_if_clean "test_worktree_cwd_uses_project_root"

# ============================================================
# test_worktree_cwd_claude_project_dir_fallback
#
# Scenario: same as above, but CLAUDE_PROJECT_DIR is used instead of
# PROJECT_ROOT. CLAUDE_PROJECT_DIR is the official Claude Code env var
# set at runtime (listed in deps.sh resolve_repo_root fallback chain).
# ============================================================
echo ""
echo "=== test_worktree_cwd_claude_project_dir_fallback ==="
_snapshot_fail

HOST_PROJECT2=$(create_test_repo)
HOST_ARTIFACTS2=$(mktemp -d "${TMPDIR:-/tmp}/test-rts-wt-artifacts2-XXXXXX")
DSO_WORKTREE2=$(create_test_repo)
trap 'rm -rf "$HOST_PROJECT2" "$HOST_ARTIFACTS2" "$DSO_WORKTREE2"' EXIT

mkdir -p "$HOST_PROJECT2/src" "$HOST_PROJECT2/tests"
cat > "$HOST_PROJECT2/src/setup.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "setup"
SHEOF
cat > "$HOST_PROJECT2/tests/test-setup.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_setup_ok: PASS"
exit 0
SHEOF
chmod +x "$HOST_PROJECT2/tests/test-setup.sh"
git -C "$HOST_PROJECT2" add -A
git -C "$HOST_PROJECT2" commit -m "add setup" --quiet 2>/dev/null
echo "# changed" >> "$HOST_PROJECT2/src/setup.sh"
git -C "$HOST_PROJECT2" add src/setup.sh

mkdir -p "$DSO_WORKTREE2/tests"
cat > "$DSO_WORKTREE2/tests/test-dso-stuff.sh" << 'SHEOF'
#!/usr/bin/env bash
echo "test_dso_stuff: PASS"
exit 0
SHEOF
chmod +x "$DSO_WORKTREE2/tests/test-dso-stuff.sh"
git -C "$DSO_WORKTREE2" add -A
git -C "$DSO_WORKTREE2" commit -m "dso worktree" --quiet 2>/dev/null

EXIT_CODE_CD=$(
    cd "$DSO_WORKTREE2"
    CLAUDE_PROJECT_DIR="$HOST_PROJECT2" \
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$HOST_ARTIFACTS2" \
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    bash "$HOOK" --source-file "src/setup.sh" 2>/dev/null || echo $?
)
EXIT_CODE_CD="${EXIT_CODE_CD:-0}"

assert_eq "claude_project_dir_fallback: hook exits 0" "0" "$EXIT_CODE_CD"

if [[ -f "$HOST_ARTIFACTS2/test-gate-status" ]]; then
    STATUS_CD=$(head -1 "$HOST_ARTIFACTS2/test-gate-status" 2>/dev/null || echo "missing")
    assert_eq "claude_project_dir_fallback: status is passed" "passed" "$STATUS_CD"
    TESTED_CD=$(grep '^tested_files=' "$HOST_ARTIFACTS2/test-gate-status" 2>/dev/null || echo "")
    assert_contains "claude_project_dir_fallback: tested_files contains host test" "test-setup" "$TESTED_CD"

    # Must NOT contain DSO worktree's test
    if [[ "$TESTED_CD" == *"test-dso-stuff"* ]]; then
        (( ++FAIL ))
        printf "FAIL: claude_project_dir_fallback: tested_files must NOT contain DSO worktree test\n  actual: %s\n" \
            "$TESTED_CD" >&2
    else
        (( ++PASS ))
    fi
else
    assert_eq "claude_project_dir_fallback: test-gate-status exists in host artifacts" "exists" "missing"
fi

rm -rf "$HOST_PROJECT2" "$HOST_ARTIFACTS2" "$DSO_WORKTREE2"
trap - EXIT

assert_pass_if_clean "test_worktree_cwd_claude_project_dir_fallback"

print_summary
