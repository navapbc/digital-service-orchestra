#!/usr/bin/env bash
# tests/hooks/test-performance-validation.sh
# Performance validation tests for dispatcher consolidation (task 0tin)
# Validates epic success criteria: subprocess count, config resolution,
# no inline worktree detection, no duplicate exclusion patterns.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; ((PASS++)); }
fail() { echo "  FAIL: $1"; ((FAIL++)); }
skip() { echo "  SKIP: $1"; ((SKIP++)); }

echo "=== Performance Validation Tests ==="

# Test 1: Hook chain subprocess count equals 1 per matcher
echo ""
echo "--- test_hook_chain_subprocess_count_equals_1 ---"
python3 << 'PYEOF'
import json, sys
with open('.claude/settings.json') as f:
    data = json.load(f)
hooks = data['hooks']
failures = []
for event, matchers in hooks.items():
    for m in matchers:
        matcher = m.get('matcher', '(all)')
        count = len(m.get('hooks', []))
        if count > 1:
            failures.append(f"{event}/{matcher}: {count} hooks (expected 1)")
if failures:
    for f in failures:
        print(f"  FAIL: {f}")
    sys.exit(1)
else:
    print("  All matchers have exactly 1 hook entry")
    sys.exit(0)
PYEOF
if [ $? -eq 0 ]; then pass "hook_chain_subprocess_count_equals_1"; else fail "hook_chain_subprocess_count_equals_1"; fi

# Test 2: No inline worktree detection in hooks (exclude deps.sh)
echo ""
echo "--- test_no_inline_worktree_detection_in_hooks ---"
# Guard: verify target files exist to prevent vacuous pass
func_count=$(find "$PLUGIN_ROOT/hooks/lib/" -name "*-functions.sh" | wc -l)
disp_count=$(find "$PLUGIN_ROOT/hooks/dispatchers/" -name "*.sh" | wc -l)
if [ "$func_count" -eq 0 ] || [ "$disp_count" -eq 0 ]; then
    echo "  No function files ($func_count) or dispatchers ($disp_count) found"
    fail "no_inline_worktree_detection_in_hooks (no files to scan)"
else
    echo "  Scanning $func_count function files and $disp_count dispatchers"
    inline_checks=$(grep -rn '\[ -d \.git \]\|test -d \.git' \
        "$PLUGIN_ROOT/hooks/lib/"*-functions.sh \
        "$PLUGIN_ROOT/hooks/dispatchers/"*.sh 2>/dev/null || true)
    if [ -z "$inline_checks" ]; then
        pass "no_inline_worktree_detection_in_hooks"
    else
        echo "  Found inline worktree detection:"
        echo "$inline_checks"
        fail "no_inline_worktree_detection_in_hooks"
    fi
fi

# Test 3: No duplicate exclusion patterns in hooks
echo ""
echo "--- test_no_duplicate_exclusion_patterns_in_hooks ---"
# Guard: verify target files exist
if [ "$func_count" -eq 0 ] || [ "$disp_count" -eq 0 ]; then
    fail "no_duplicate_exclusion_patterns_in_hooks (no files to scan)"
else
    dup_patterns=$(grep -rn "EXCLUDE_PATHSPECS\|':!\\.tickets/'" \
        "$PLUGIN_ROOT/hooks/lib/"*-functions.sh \
        "$PLUGIN_ROOT/hooks/dispatchers/"*.sh 2>/dev/null || true)
    if [ -z "$dup_patterns" ]; then
        pass "no_duplicate_exclusion_patterns_in_hooks"
    else
        echo "  Found exclusion pattern references (should only be in compute-diff-hash.sh):"
        echo "$dup_patterns"
        fail "no_duplicate_exclusion_patterns_in_hooks"
    fi
fi

# Test 4: All dispatchers are executable
echo ""
echo "--- test_all_dispatchers_executable ---"
non_exec=$(find "$PLUGIN_ROOT/hooks/dispatchers/" -name "*.sh" ! -perm -u+x 2>/dev/null || true)
if [ -z "$non_exec" ]; then
    pass "all_dispatchers_executable"
else
    echo "  Non-executable dispatchers:"
    echo "$non_exec"
    fail "all_dispatchers_executable"
fi

# Test 5: settings.json hooks all use dispatchers
echo ""
echo "--- test_settings_hooks_use_dispatchers ---"
python3 << 'PYEOF'
import json, sys

with open('.claude/settings.json') as f:
    settings = json.load(f)
with open('hooks.json') as f:
    hooks_json = json.load(f)

assert 'hooks' in settings, "settings.json missing 'hooks'"
assert 'hooks' in hooks_json, "hooks.json missing 'hooks'"

# Verify all settings.json hook commands point to dispatchers or run-hook.sh
non_dispatcher = []
for event, matchers in settings['hooks'].items():
    for m in matchers:
        for h in m.get('hooks', []):
            cmd = h.get('command', '')
            if 'dispatchers/' in cmd:
                continue
            # PreCompact is not consolidated (only 1 hook, kept as-is)
            non_dispatcher.append(f"{event}/{m.get('matcher', '(all)')}: {cmd}")

if non_dispatcher:
    print(f"  Found {len(non_dispatcher)} non-dispatcher hook(s):")
    for nd in non_dispatcher:
        print(f"    {nd}")
    sys.exit(1)
else:
    print("  All hook entries point to dispatchers")
    sys.exit(0)
PYEOF
if [ $? -eq 0 ]; then pass "settings_hooks_use_dispatchers"; else fail "settings_hooks_use_dispatchers"; fi

# Test 6: Passing --snapshot does NOT create a snapshot file
echo ""
echo "--- test_no_snapshot_file_created ---"
SNAP="/tmp/test-snapshot-verify-$$"
rm -f "$SNAP"
"$PLUGIN_ROOT/hooks/compute-diff-hash.sh" --snapshot "$SNAP" >/dev/null 2>&1 || true
if [ ! -f "$SNAP" ]; then
    pass "no_snapshot_file_created"
else
    echo "  Snapshot file was created at $SNAP (should not exist)"
    rm -f "$SNAP"
    fail "no_snapshot_file_created"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
