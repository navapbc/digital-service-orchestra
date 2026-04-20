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

# ── test_fallback_uses_shim ───────────────────────────────────────────────────
# The final fallback must resolve via the dso shim (--lib mode) rather than
# constructing $REPO_ROOT/plugins/<name> directly. The shim handles plugin-cache
# installs (worktree sessions) where the plugin is NOT in the repo tree.
# Bug dcdc-8c7b: direct REPO_ROOT/plugins path injection causes exit 127 in
# worktree sessions.
echo ""
echo "--- test_fallback_uses_shim ---"
_snapshot_fail

_has_shim_fallback=0
# The fallback must use the shim in --lib mode to get DSO_ROOT, not construct
# a raw path from $REPO_ROOT/plugins/<name>.
grep -q '\.claude/scripts/dso.*--lib\|--lib.*\.claude/scripts/dso' "$WORKFLOW_FILE" && _has_shim_fallback=1 || true
assert_eq "test_fallback_uses_shim: final fallback resolves via dso shim --lib mode" \
    "1" "$_has_shim_fallback"
assert_pass_if_clean "test_fallback_uses_shim"

# Ensure the old broken pattern (constructing CLAUDE_PLUGIN_ROOT from REPO_ROOT/plugins/)
# is NOT present — that pattern breaks in worktree sessions.
_has_broken_path_construction=0
# shellcheck disable=SC2016  # single quotes intentional: searching for literal $REPO_ROOT text in file
grep -qE 'CLAUDE_PLUGIN_ROOT=.*\$REPO_ROOT/plugins/|CLAUDE_PLUGIN_ROOT=.*\$\{REPO_ROOT\}/plugins/' "$WORKFLOW_FILE" && _has_broken_path_construction=1 || true
assert_eq "test_fallback_no_broken_repo_root_path: fallback must NOT construct path via REPO_ROOT/plugins/" \
    "0" "$_has_broken_path_construction"
assert_pass_if_clean "test_fallback_no_broken_repo_root_path"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
