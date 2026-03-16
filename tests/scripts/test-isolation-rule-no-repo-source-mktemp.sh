#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-isolation-rule-no-repo-source-mktemp.sh
# Tests for scripts/test-isolation-rules/no-repo-source-mktemp.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-isolation-rule-no-repo-source-mktemp.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
RULE="$REPO_ROOT/scripts/test-isolation-rules/no-repo-source-mktemp.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-isolation-rule-no-repo-source-mktemp.sh ==="

# ── test_rule_exists_and_executable ──────────────────────────────────────────
_snapshot_fail
rule_exec=0
[ -x "$RULE" ] && rule_exec=1
assert_eq "test_rule_exists_and_executable" "1" "$rule_exec"
assert_pass_if_clean "test_rule_exists_and_executable"

# ── test_catches_mktemp_in_repo_root ─────────────────────────────────────────
# Fixture with mktemp "$REPO_ROOT/..." should trigger violation
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/bad-repo-source-mktemp.sh" 2>/dev/null)
assert_ne "test_catches_mktemp_in_repo_root: has output" "" "$output"
assert_contains "test_catches_mktemp_in_repo_root: rule name" "no-repo-source-mktemp" "$output"
assert_contains "test_catches_mktemp_in_repo_root: file in output" "bad-repo-source-mktemp.sh" "$output"
assert_pass_if_clean "test_catches_mktemp_in_repo_root"

# ── test_passes_mktemp_in_tmp ────────────────────────────────────────────────
# Fixture with mktemp in /tmp should pass (no output)
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/good-repo-source-mktemp.sh" 2>/dev/null)
assert_eq "test_passes_mktemp_in_tmp: no output" "" "$output"
assert_pass_if_clean "test_passes_mktemp_in_tmp"

# ── test_ignores_non_bash_files ──────────────────────────────────────────────
_snapshot_fail
_TEMP_PY=$(mktemp /tmp/test-isolation-XXXXXX.py)
trap 'rm -f "$_TEMP_PY"' EXIT
cat > "$_TEMP_PY" << 'PYEOF'
import os
result = os.path.join(REPO_ROOT, "app/src/fake.py")
PYEOF
output=$("$RULE" "$_TEMP_PY" 2>/dev/null)
assert_eq "test_ignores_non_bash_files: no output for .py" "" "$output"
assert_pass_if_clean "test_ignores_non_bash_files"

# ── test_respects_isolation_ok_comment ───────────────────────────────────────
_snapshot_fail
_TEMP_SH=$(mktemp /tmp/test-isolation-XXXXXX.sh)
cat > "$_TEMP_SH" << 'SHEOF'
#!/usr/bin/env bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
_F=$(mktemp "$REPO_ROOT/app/src/fake_XXXXXX.py") # isolation-ok: required for hook path matching
SHEOF
output=$("$RULE" "$_TEMP_SH" 2>/dev/null)
assert_eq "test_respects_isolation_ok_comment: suppressed" "" "$output"
rm -f "$_TEMP_SH"
assert_pass_if_clean "test_respects_isolation_ok_comment"

print_summary
