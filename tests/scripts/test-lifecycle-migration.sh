#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-lifecycle-migration.sh
# Tests for the agent-batch-lifecycle.sh migration to lockpick-workflow/scripts/.
#
# Validates:
#   1. Canonical script exists at lockpick-workflow/scripts/ and is executable
#   2. Wrapper at scripts/ is thin (< 15 lines) and delegates via exec
#   3. Zero hardcoded project-specific values in migrated script
#   4. DB preflight uses database.ensure_cmd from config
#   5. Session usage uses session.usage_check_cmd from config
#   6. Container cleanup uses infrastructure.container_prefix from config
#   7. Container cleanup uses infrastructure.compose_project from config
#   8. Wrapper passes through subcommands correctly
#
# Usage: bash lockpick-workflow/tests/scripts/test-lifecycle-migration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
CANONICAL="$REPO_ROOT/lockpick-workflow/scripts/agent-batch-lifecycle.sh"
WRAPPER="$REPO_ROOT/scripts/agent-batch-lifecycle.sh"

source "$ASSERT_LIB"

echo "=== test-lifecycle-migration.sh ==="

# ---------------------------------------------------------------------------
# Test 1: Canonical script exists and is executable
# ---------------------------------------------------------------------------
echo "Test 1: Canonical script exists at lockpick-workflow/scripts/ and is executable"
canonical_exec=0
if [ -x "$CANONICAL" ]; then
    canonical_exec=1
fi
assert_eq "test_canonical_exists_and_executable" "1" "$canonical_exec"

# ---------------------------------------------------------------------------
# Test 2: Wrapper is thin (< 15 lines)
# ---------------------------------------------------------------------------
echo "Test 2: Wrapper at scripts/ is thin (< 15 lines)"
wrapper_lines=0
if [ -f "$WRAPPER" ]; then
    wrapper_lines=$(wc -l < "$WRAPPER" | tr -d ' ')
fi
wrapper_thin=0
if [ "$wrapper_lines" -gt 0 ] && [ "$wrapper_lines" -le 15 ]; then
    wrapper_thin=1
fi
assert_eq "test_wrapper_is_thin" "1" "$wrapper_thin"

# ---------------------------------------------------------------------------
# Test 3: Wrapper contains exec delegation
# ---------------------------------------------------------------------------
echo "Test 3: Wrapper delegates via exec"
wrapper_has_exec=0
if grep -q 'exec.*lockpick-workflow/scripts/agent-batch-lifecycle.sh' "$WRAPPER" 2>/dev/null; then
    wrapper_has_exec=1
fi
assert_eq "test_wrapper_delegates_via_exec" "1" "$wrapper_has_exec"

# ---------------------------------------------------------------------------
# Test 4: Zero hardcoded project-specific values in migrated script
# ---------------------------------------------------------------------------
echo "Test 4: No hardcoded make targets in canonical script"
hardcoded_make=0
hardcoded_make=$(grep -cE 'make (db-start|db-status|db-stop|format|lint|test)' "$CANONICAL" 2>/dev/null) || true
assert_eq "test_no_hardcoded_make_targets" "0" "$hardcoded_make"

echo "Test 4b: No hardcoded lockpick-postgres in canonical script"
hardcoded_postgres=0
hardcoded_postgres=$(grep -c 'lockpick-postgres' "$CANONICAL" 2>/dev/null) || true
assert_eq "test_no_hardcoded_lockpick_postgres" "0" "$hardcoded_postgres"

echo "Test 4c: No hardcoded worktree-port.sh in canonical script"
hardcoded_worktree_port=0
hardcoded_worktree_port=$(grep -c 'worktree-port\.sh' "$CANONICAL" 2>/dev/null) || true
assert_eq "test_no_hardcoded_worktree_port" "0" "$hardcoded_worktree_port"

echo "Test 4d: No hardcoded check-local-env.sh in canonical script"
hardcoded_check_local=0
hardcoded_check_local=$(grep -c 'check-local-env\.sh' "$CANONICAL" 2>/dev/null) || true
assert_eq "test_no_hardcoded_check_local_env" "0" "$hardcoded_check_local"

# ---------------------------------------------------------------------------
# Test 5: DB preflight uses read-config.sh for database.ensure_cmd
# ---------------------------------------------------------------------------
echo "Test 5: DB preflight uses read-config.sh for database.ensure_cmd"
db_ensure_config=0
if grep -qE '(_read_cfg|read-config\.sh).*database\.ensure_cmd|(_read_cfg|read-config\.sh).*database\.ensure' "$CANONICAL" 2>/dev/null; then
    db_ensure_config=1
fi
assert_eq "test_db_preflight_uses_config_ensure" "1" "$db_ensure_config"

# ---------------------------------------------------------------------------
# Test 6: DB status check uses read-config.sh for database.status_cmd
# ---------------------------------------------------------------------------
echo "Test 6: DB status uses read-config.sh for database.status_cmd"
db_status_config=0
if grep -qE '(_read_cfg|read-config\.sh).*database\.status_cmd|(_read_cfg|read-config\.sh).*database\.status' "$CANONICAL" 2>/dev/null; then
    db_status_config=1
fi
assert_eq "test_db_status_uses_config" "1" "$db_status_config"

# ---------------------------------------------------------------------------
# Test 7: Container cleanup uses read-config.sh for infrastructure.container_prefix
# ---------------------------------------------------------------------------
echo "Test 7: Container cleanup uses infrastructure.container_prefix from config"
container_prefix_config=0
if grep -qE '(_read_cfg|read-config\.sh).*infrastructure\.container_prefix' "$CANONICAL" 2>/dev/null; then
    container_prefix_config=1
fi
assert_eq "test_container_prefix_from_config" "1" "$container_prefix_config"

# ---------------------------------------------------------------------------
# Test 8: Container cleanup uses read-config.sh for infrastructure.compose_project
# ---------------------------------------------------------------------------
echo "Test 8: Container cleanup uses infrastructure.compose_project from config"
compose_project_config=0
if grep -qE '(_read_cfg|read-config\.sh).*infrastructure\.compose_project' "$CANONICAL" 2>/dev/null; then
    compose_project_config=1
fi
assert_eq "test_compose_project_from_config" "1" "$compose_project_config"

# ---------------------------------------------------------------------------
# Test 9: Session usage check uses read-config.sh for session.usage_check_cmd
# ---------------------------------------------------------------------------
echo "Test 9: Session usage uses session.usage_check_cmd from config"
session_config=0
if grep -qE '(_read_cfg|read-config\.sh).*session\.usage_check_cmd' "$CANONICAL" 2>/dev/null; then
    session_config=1
fi
assert_eq "test_session_usage_from_config" "1" "$session_config"

# ---------------------------------------------------------------------------
# Test 10: DB port resolution uses read-config.sh for database.port_cmd
# ---------------------------------------------------------------------------
echo "Test 10: DB port uses database.port_cmd from config"
db_port_config=0
if grep -qE '(_read_cfg|read-config\.sh).*database\.port_cmd' "$CANONICAL" 2>/dev/null; then
    db_port_config=1
fi
assert_eq "test_db_port_from_config" "1" "$db_port_config"

# ---------------------------------------------------------------------------
# Test 11: Canonical script does NOT source project-specific files
# ---------------------------------------------------------------------------
echo "Test 11: Canonical script does not source project-specific files"
# It should only source read-config.sh and plugin-internal siblings
project_sources=0
# Check for source/. commands that reference scripts/ outside lockpick-workflow
project_sources=$(grep -cE '(source|\.)\s+.*scripts/' "$CANONICAL" 2>/dev/null | head -1) || true
# Subtract references to lockpick-workflow/scripts/ (those are OK)
plugin_sources=0
plugin_sources=$(grep -cE '(source|\.)\s+.*lockpick-workflow/scripts/' "$CANONICAL" 2>/dev/null | head -1) || true
# Also subtract self-references via SCRIPT_DIR
self_sources=0
self_sources=$(grep -cE '(source|\.)\s+"\$SCRIPT_DIR/' "$CANONICAL" 2>/dev/null | head -1) || true
external_sources=$((project_sources - plugin_sources - self_sources))
if [ "$external_sources" -lt 0 ]; then external_sources=0; fi
assert_eq "test_no_external_sources" "0" "$external_sources"

# ---------------------------------------------------------------------------
# Test 12: Wrapper passes through arguments (behavioral test)
# Run the wrapper with no args; should exit 2 (usage error) — same as canonical
# ---------------------------------------------------------------------------
echo "Test 12: Wrapper passes through arguments and preserves exit codes"
wrapper_exit=0
bash "$WRAPPER" >/dev/null 2>&1 || wrapper_exit=$?
assert_eq "test_wrapper_passthrough_exit_code" "2" "$wrapper_exit"

# ---------------------------------------------------------------------------
# Test 13: Canonical script uses read-config.sh relative to SCRIPT_DIR (sibling)
# ---------------------------------------------------------------------------
echo "Test 13: Canonical script references read-config.sh as sibling"
sibling_config=0
if grep -qE '\$SCRIPT_DIR/read-config\.sh|\$\{SCRIPT_DIR\}/read-config\.sh' "$CANONICAL" 2>/dev/null; then
    sibling_config=1
fi
# Also accept "$SCRIPT_DIR"/read-config.sh
if grep -q '"$SCRIPT_DIR"/read-config.sh' "$CANONICAL" 2>/dev/null; then
    sibling_config=1
fi
assert_eq "test_read_config_as_sibling" "1" "$sibling_config"

# ---------------------------------------------------------------------------
# Test 14: No hardcoded APP_DIR="$REPO_ROOT/app" in canonical (should be from config)
# ---------------------------------------------------------------------------
echo "Test 14: No hardcoded app/ path in canonical script"
# The script may still reference REPO_ROOT but should not hardcode app/ path
hardcoded_app=0
hardcoded_app=$(grep -c 'APP_DIR=.*app' "$CANONICAL" 2>/dev/null) || true
assert_eq "test_no_hardcoded_app_dir" "0" "$hardcoded_app"

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary
