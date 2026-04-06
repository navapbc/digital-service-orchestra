#!/usr/bin/env bash
# tests/skills/test-cli-lifecycle-migration.sh
# RED tests: debug-everything, end-session, and cleanup-claude-session.sh must use
# @playwright/cli patterns instead of Playwright MCP.
#
# All tests intentionally fail (RED) until the CLI lifecycle migration is complete.
# Tracked by ticket 1ef2-fd6b (parent story: 33ab-880a).
#
# Tests:
#   test_debug_everything_no_mcp_dispatch      — debug-everything/SKILL.md must not reference
#                                                 "full MCP only as last resort" for Playwright
#   test_end_session_cli_cleanup               — end-session/SKILL.md must reference .playwright-cli/
#   test_cleanup_script_cli_directory          — cleanup-claude-session.sh --dry-run reports
#                                                 .playwright-cli/ cleanup when dir is present
#   test_cleanup_script_orphan_processes       — cleanup-claude-session.sh --dry-run mentions
#                                                 CLI browser process cleanup
#
# Usage: bash tests/skills/test-cli-lifecycle-migration.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
PLUGIN_ROOT="$REPO_ROOT/plugins/dso"

source "$REPO_ROOT/tests/lib/assert.sh"

DEBUG_SKILL_MD="$PLUGIN_ROOT/skills/debug-everything/SKILL.md"
END_SKILL_MD="$PLUGIN_ROOT/skills/end-session/SKILL.md"
CLEANUP_SCRIPT="$PLUGIN_ROOT/scripts/cleanup-claude-session.sh"

_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

echo "=== test-cli-lifecycle-migration.sh ==="

# ---------------------------------------------------------------------------
# test_debug_everything_no_mcp_dispatch
#
# debug-everything/SKILL.md currently instructs agents to use
# "full MCP only as last resort" for Playwright debugging. After the CLI
# migration this phrase must be absent — replaced with a CLI-based dispatch
# pattern. This test asserts the MCP fallback phrase is gone.
#
# RED condition: phrase IS present → test fails.
# GREEN condition: phrase is absent (CLI patterns used instead) → test passes.
# ---------------------------------------------------------------------------
_snapshot_fail

_de_content=$(cat "$DEBUG_SKILL_MD" 2>/dev/null || true)
if grep -q "full MCP only as last resort" <<< "$_de_content"; then
    _de_has_mcp_dispatch="yes"
else
    _de_has_mcp_dispatch="no"
fi
# After migration: must be "no" (phrase removed). Currently "yes" → FAIL (RED).
assert_eq "test_debug_everything_no_mcp_dispatch" "no" "$_de_has_mcp_dispatch"

assert_pass_if_clean "test_debug_everything_no_mcp_dispatch"

# ---------------------------------------------------------------------------
# test_end_session_cli_cleanup
#
# end-session/SKILL.md currently says "Playwright MCP authorized" and does not
# reference .playwright-cli/. After migration the skill must direct cleanup to
# the .playwright-cli/ state directory, not .playwright-mcp/.
#
# RED condition: .playwright-cli/ is absent from the skill → test fails.
# GREEN condition: .playwright-cli/ appears in the skill → test passes.
# ---------------------------------------------------------------------------
_snapshot_fail

_es_content=$(cat "$END_SKILL_MD" 2>/dev/null || true)
if grep -q "\.playwright-cli/" <<< "$_es_content"; then
    _es_has_cli_ref="yes"
else
    _es_has_cli_ref="no"
fi
# After migration: must be "yes" (.playwright-cli/ added). Currently "no" → FAIL (RED).
assert_eq "test_end_session_cli_cleanup" "yes" "$_es_has_cli_ref"

assert_pass_if_clean "test_end_session_cli_cleanup"

# ---------------------------------------------------------------------------
# test_cleanup_script_cli_directory
#
# cleanup-claude-session.sh step 13 currently handles .playwright-mcp/ only.
# After migration, step 13 must detect and report (in --dry-run) the presence
# of .playwright-cli/ directories.
#
# Behavioral test: run the cleanup script with --dry-run against a temp REPO_ROOT
# containing a .playwright-cli/ directory. Assert that stdout contains
# ".playwright-cli/" in the output (indicating the script recognizes it).
#
# RED condition: script output does not mention .playwright-cli/ → FAIL.
# GREEN condition: dry-run output says "Would remove .playwright-cli/ state" → PASS.
#
# GC_PLUGIN_GLOB is set to a nonexistent path to prevent the internal
# gc_stale_state_files() function from running "find /" (which exceeds test timeout).
# ---------------------------------------------------------------------------
_snapshot_fail

_t3_tmp=$(mktemp -d -p "$REPO_ROOT/tests")
_TEST_TMPDIRS+=("$_t3_tmp")
mkdir -p "$_t3_tmp/.playwright-cli/session1"

_t3_output=$(
    PROJECT_ROOT="$_t3_tmp" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    GC_PLUGIN_GLOB="$_t3_tmp/no-plugin-dirs" \
    timeout 30 bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null \
    || true
)

if grep -q "\.playwright-cli" <<< "$_t3_output"; then
    _t3_has_cli="yes"
else
    _t3_has_cli="no"
fi
# After migration: must be "yes" (script reports .playwright-cli/ cleanup).
# Currently "no" → FAIL (RED).
assert_eq "test_cleanup_script_cli_directory" "yes" "$_t3_has_cli"

assert_pass_if_clean "test_cleanup_script_cli_directory"

# ---------------------------------------------------------------------------
# test_cleanup_script_orphan_processes
#
# cleanup-claude-session.sh currently only kills orphaned Claude shell wrapper
# processes (matching "shell-snapshots.*claude"). After migration it must also
# handle orphaned CLI browser processes spawned by @playwright/cli sub-agents.
#
# Behavioral test: run the cleanup script with --dry-run and assert that stdout
# contains a reference to browser/CLI process cleanup. Currently no such section
# exists → dry-run output will not mention CLI browser processes.
#
# RED condition: output lacks any mention of CLI browser process cleanup → FAIL.
# GREEN condition: output mentions CLI browser process cleanup → PASS.
#
# GC_PLUGIN_GLOB is set to a nonexistent path to short-circuit find / scan.
# ---------------------------------------------------------------------------
_snapshot_fail

_t4_tmp=$(mktemp -d -p "$REPO_ROOT/tests")
_TEST_TMPDIRS+=("$_t4_tmp")

_t4_output=$(
    PROJECT_ROOT="$_t4_tmp" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" \
    GC_PLUGIN_GLOB="$_t4_tmp/no-plugin-dirs" \
    timeout 30 bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null \
    || true
)

# After migration the script should mention CLI browser process cleanup in its
# dry-run output (e.g. "Checking for orphaned Playwright CLI browser processes..."
# or "Would kill N Playwright CLI browser process(es)").
if grep -qiE "playwright.*cli.*process|cli.*browser.*process|orphan.*playwright.*cli|playwright.*cli.*browser" <<< "$_t4_output"; then
    _t4_has_cli_proc="yes"
else
    _t4_has_cli_proc="no"
fi
# After migration: must be "yes". Currently "no" → FAIL (RED).
assert_eq "test_cleanup_script_orphan_processes" "yes" "$_t4_has_cli_proc"

assert_pass_if_clean "test_cleanup_script_orphan_processes"

print_summary
