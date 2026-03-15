#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-claude-safe-compose-cleanup.sh
# Tests for _cleanup_docker_for_worktree in lockpick-workflow/scripts/claude-safe.
#
# Verifies that the function reads compose file paths from infrastructure.compose_files
# via read-config.sh --list rather than using hardcoded paths.
#
# Usage: bash lockpick-workflow/tests/scripts/test-claude-safe-compose-cleanup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CLAUDE_SAFE="$REPO_ROOT/lockpick-workflow/scripts/claude-safe"
PLUGIN_SCRIPTS="$REPO_ROOT/lockpick-workflow/scripts"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-claude-safe-compose-cleanup.sh ==="

# ── Setup: shared tmpdir, cleaned on EXIT ─────────────────────────────────────
TMPDIR_BASE=$(mktemp -d /tmp/test-claude-safe-cleanup.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Helper: extract and run _cleanup_docker_for_worktree in a subshell ────────
# Uses _CLAUDE_SAFE_SOURCE_ONLY=1 guard so claude-safe's main body does not run.
# Injects a stub docker binary via PATH prepend.
# Args:
#   $1 — path to workflow-config.conf for this test
#   $2 — path to stub-bin directory (must contain a 'docker' stub if testing with Docker)
#   $3 — wt_name argument for _cleanup_docker_for_worktree
#   $4 — wt_path argument for _cleanup_docker_for_worktree
_run_cleanup_fn() {
    local config_file="$1"
    local stub_bin="$2"
    local wt_name="$3"
    local wt_path="$4"

    PATH="$stub_bin:$PATH" \
    WORKFLOW_CONFIG="$config_file" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    bash -c "
        source \"$CLAUDE_SAFE\"
        _cleanup_docker_for_worktree \"$wt_name\" \"$wt_path\"
    "
}

# ── test_cleanup_docker_iterates_compose_files ────────────────────────────────
# With infrastructure.compose_files containing two entries, both docker compose
# down commands must be called — one per file.
_snapshot_fail

iter_dir="$TMPDIR_BASE/iterate"
mkdir -p "$iter_dir/stub-bin" "$iter_dir/wt-path"
iter_log="$iter_dir/docker.log"
touch "$iter_log"

cat > "$iter_dir/stub-bin/docker" <<DOCKER_STUB
#!/usr/bin/env bash
echo "\$*" >> "$iter_log"
exit 0
DOCKER_STUB
chmod +x "$iter_dir/stub-bin/docker"

cat > "$iter_dir/workflow-config.conf" <<CONF
infrastructure.compose_project=lockpick-db-
infrastructure.compose_files=app/docker-compose.yml
infrastructure.compose_files=app/docker-compose.db.yml
CONF

iter_exit=0
_run_cleanup_fn "$iter_dir/workflow-config.conf" "$iter_dir/stub-bin" \
    "worktree-test-abc" "$iter_dir/wt-path" || iter_exit=$?

iter_log_content=$(cat "$iter_log" 2>/dev/null || echo "")
iter_calls=$(grep -c "compose" "$iter_log" 2>/dev/null || echo "0")

assert_eq "test_cleanup_docker_iterates_compose_files: docker called twice" "2" "$iter_calls"
assert_contains "test_cleanup_docker_iterates_compose_files: docker-compose.yml called" "docker-compose.yml" "$iter_log_content"
assert_contains "test_cleanup_docker_iterates_compose_files: docker-compose.db.yml called" "docker-compose.db.yml" "$iter_log_content"
assert_pass_if_clean "test_cleanup_docker_iterates_compose_files"

# ── test_cleanup_docker_no_op_when_compose_files_absent ──────────────────────
# When infrastructure.compose_files key is absent, docker must NOT be invoked.
_snapshot_fail

absent_dir="$TMPDIR_BASE/absent"
mkdir -p "$absent_dir/stub-bin" "$absent_dir/wt-path"
absent_log="$absent_dir/docker.log"
touch "$absent_log"

cat > "$absent_dir/stub-bin/docker" <<DOCKER_STUB
#!/usr/bin/env bash
echo "\$*" >> "$absent_log"
exit 0
DOCKER_STUB
chmod +x "$absent_dir/stub-bin/docker"

# Config with NO compose_files key (infrastructure exists but compose_files is absent)
cat > "$absent_dir/workflow-config.conf" <<CONF
infrastructure.compose_project=lockpick-db-
CONF

absent_exit=0
_run_cleanup_fn "$absent_dir/workflow-config.conf" "$absent_dir/stub-bin" \
    "worktree-test-abc" "$absent_dir/wt-path" || absent_exit=$?

absent_calls=$(wc -l < "$absent_log" 2>/dev/null | tr -d ' ')
assert_eq "test_cleanup_docker_no_op_when_compose_files_absent: exit 0" "0" "$absent_exit"
assert_eq "test_cleanup_docker_no_op_when_compose_files_absent: docker not called" "0" "$absent_calls"
assert_pass_if_clean "test_cleanup_docker_no_op_when_compose_files_absent"

# ── test_cleanup_docker_skips_silently_when_no_docker ────────────────────────
# When docker is not on PATH, the function must return silently (exit 0, no stderr).
_snapshot_fail

nodock_dir="$TMPDIR_BASE/nodock"
mkdir -p "$nodock_dir/stub-bin" "$nodock_dir/wt-path"
# stub-bin intentionally has NO docker binary

cat > "$nodock_dir/workflow-config.conf" <<CONF
infrastructure.compose_project=lockpick-db-
infrastructure.compose_files=app/docker-compose.yml
infrastructure.compose_files=app/docker-compose.db.yml
CONF

nodock_exit=0
nodock_stderr=""
nodock_stderr=$(
    # Minimal PATH with no docker; stub-bin is empty
    PATH="$nodock_dir/stub-bin:/usr/bin:/bin" \
    WORKFLOW_CONFIG="$nodock_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    bash -c "
        source \"$CLAUDE_SAFE\"
        _cleanup_docker_for_worktree \"worktree-test-abc\" \"$nodock_dir/wt-path\"
    " 2>&1 1>/dev/null
) || nodock_exit=$?

assert_eq "test_cleanup_docker_skips_silently_when_no_docker: exits 0" "0" "$nodock_exit"
assert_eq "test_cleanup_docker_skips_silently_when_no_docker: no stderr output" "" "$nodock_stderr"
assert_pass_if_clean "test_cleanup_docker_skips_silently_when_no_docker"

print_summary
