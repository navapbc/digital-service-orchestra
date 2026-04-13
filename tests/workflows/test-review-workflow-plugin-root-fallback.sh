#!/usr/bin/env bash
# tests/workflows/test-review-workflow-plugin-root-fallback.sh
# Asserts that REVIEW-WORKFLOW.md includes a CLAUDE_PLUGIN_ROOT fallback resolution
# block matching the pattern in COMMIT-WORKFLOW.md Step 0.
#
# Bug w22-w5wt: REVIEW-WORKFLOW.md used ${CLAUDE_PLUGIN_ROOT} without a fallback,
# causing failures when the env var is unset (e.g., manual runs outside Claude Code).
#
# Usage: bash tests/workflows/test-review-workflow-plugin-root-fallback.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
WORKFLOW_FILE="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-workflow-plugin-root-fallback.sh ==="
echo ""

# ── test_fallback_guard_present ───────────────────────────────────────────────
# REVIEW-WORKFLOW.md must contain the CLAUDE_PLUGIN_ROOT fallback guard so that
# commands like `source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"` work even
# when CLAUDE_PLUGIN_ROOT is not set in the environment.
echo "--- test_fallback_guard_present ---"
_snapshot_fail

# The guard uses the ${VAR:-} expansion and sets CLAUDE_PLUGIN_ROOT from config
_has_fallback=0
grep -q 'CLAUDE_PLUGIN_ROOT:-' "$WORKFLOW_FILE" && _has_fallback=1 || true
assert_eq "test_fallback_guard_present: CLAUDE_PLUGIN_ROOT fallback guard exists" \
    "1" "$_has_fallback"
assert_pass_if_clean "test_fallback_guard_present"

# ── test_fallback_reads_dso_config ────────────────────────────────────────────
# The fallback must read the plugin root from .claude/dso-config.conf
# (key: dso.plugin_root) — same source as COMMIT-WORKFLOW.md.
echo ""
echo "--- test_fallback_reads_dso_config ---"
_snapshot_fail

_has_config_read=0
grep -qF 'dso\.plugin_root' "$WORKFLOW_FILE" && _has_config_read=1 || true
assert_eq "test_fallback_reads_dso_config: fallback reads dso.plugin_root from config" \
    "1" "$_has_config_read"
assert_pass_if_clean "test_fallback_reads_dso_config"

# ── test_fallback_final_default ───────────────────────────────────────────────
# The fallback must construct a default plugin path as a safety net when both
# the env var and config read fail. Uses a variable-constructed path to avoid
# literal plugin path strings (blocked by plugin-self-ref hook).
echo ""
echo "--- test_fallback_final_default ---"
_snapshot_fail

_has_final_default=0
# The fallback assigns CLAUDE_PLUGIN_ROOT from a constructed path using $REPO_ROOT/plugins/
grep -q 'CLAUDE_PLUGIN_ROOT=.*REPO_ROOT.*/plugins/' "$WORKFLOW_FILE" && _has_final_default=1 || true
assert_eq "test_fallback_final_default: fallback constructs default plugin path" \
    "1" "$_has_final_default"
assert_pass_if_clean "test_fallback_final_default"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
