#!/usr/bin/env bash
# tests/scripts/test-tag-release.sh
# Tests for scripts/tag-release.sh
#
# Usage: bash tests/scripts/test-tag-release.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/tag-release.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-tag-release.sh ==="

# ── test_tag_release_exists_and_executable ────────────────────────────────────
if [[ -x "$SCRIPT" ]]; then
    actual="executable"
else
    actual="not_executable"
fi
assert_eq "test_tag_release_exists_and_executable" "executable" "$actual"

# ── test_tag_release_no_syntax_errors ─────────────────────────────────────────
if bash -n "$SCRIPT" 2>/dev/null; then
    actual="valid"
else
    actual="syntax_error"
fi
assert_eq "test_tag_release_no_syntax_errors" "valid" "$actual"

# ── test_tag_release_rejects_no_args ──────────────────────────────────────────
exit_code=0
bash "$SCRIPT" 2>/dev/null || exit_code=$?
assert_eq "test_tag_release_rejects_no_args" "1" "$exit_code"

# ── test_tag_release_rejects_invalid_semver ───────────────────────────────────
exit_code=0
bash "$SCRIPT" "not-a-version" 2>/dev/null || exit_code=$?
assert_eq "test_tag_release_rejects_invalid_semver" "1" "$exit_code"

# ── test_tag_release_rejects_v_prefix ─────────────────────────────────────────
exit_code=0
bash "$SCRIPT" "v1.0.0" 2>/dev/null || exit_code=$?
assert_eq "test_tag_release_rejects_v_prefix" "1" "$exit_code"

# ── test_tag_release_dry_run_does_not_modify ──────────────────────────────────
# Capture current plugin.json version before dry-run
PLUGIN_JSON="$DSO_PLUGIN_DIR/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_JSON" ]]; then
    version_before=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])" 2>/dev/null)
    exit_code=0
    output=$(bash "$SCRIPT" "9.9.9" --dry-run 2>&1) || exit_code=$?
    version_after=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])" 2>/dev/null)
    assert_eq "test_tag_release_dry_run_exits_zero" "0" "$exit_code"
    assert_eq "test_tag_release_dry_run_does_not_modify" "$version_before" "$version_after"
else
    assert_eq "test_tag_release_dry_run_exits_zero: plugin.json exists" "exists" "missing"
    assert_eq "test_tag_release_dry_run_does_not_modify: plugin.json exists" "exists" "missing"
fi

# ── test_tag_release_dry_run_shows_tag ────────────────────────────────────────
if echo "$output" | grep -q "v9.9.9"; then
    actual="shows_tag"
else
    actual="missing_tag"
fi
assert_eq "test_tag_release_dry_run_shows_tag" "shows_tag" "$actual"

print_summary
