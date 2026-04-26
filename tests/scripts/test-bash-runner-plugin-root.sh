#!/usr/bin/env bash
# tests/scripts/test-bash-runner-plugin-root.sh
#
# Behavioral test for CLAUDE_PLUGIN_ROOT export in
# plugins/dso/scripts/runners/bash-runner.sh.
#
# Mirrors the export performed by tests/hooks/run-hook-tests.sh so that
# test-batched.sh / validate.sh paths produce equivalent results to the
# hook-test harness. Without this export, tests that cd into temp git
# repos and invoke `.claude/scripts/dso ticket exists ...` fail because
# the shim cannot resolve plugin root from a freshly-init'd git repo.
#
# Verifies (behavioral):
#   - When CLAUDE_PLUGIN_ROOT is UNSET in the parent, child test
#     processes launched by bash-runner.sh observe CLAUDE_PLUGIN_ROOT
#     pointing to the plugin directory (derived from bash-runner.sh's
#     own location).
#   - When CLAUDE_PLUGIN_ROOT IS SET in the parent, child test
#     processes inherit it unchanged (no override).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TEST_BATCHED="$REPO_ROOT/plugins/dso/scripts/test-batched.sh"
EXPECTED_PLUGIN_ROOT="$REPO_ROOT/plugins/dso"

PASS=0
FAIL=0
fail_msg() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass_msg() { PASS=$((PASS + 1)); }

# Build a fixture test that prints the value of CLAUDE_PLUGIN_ROOT
# observed inside the child process.
FIXTURE=$(mktemp -d)
FIXTURE=$(cd "$FIXTURE" && pwd -P)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/tests/hooks"

cat > "$FIXTURE/tests/hooks/test-plugin-root-probe.sh" <<'TESTSH'
#!/usr/bin/env bash
echo "PROBE_CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-UNSET}"
echo "PASSED: 1  FAILED: 0"
exit 0
TESTSH
chmod +x "$FIXTURE/tests/hooks/test-plugin-root-probe.sh"

git -C "$FIXTURE" init -q 2>/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t add . 2>/dev/null
git -C "$FIXTURE" -c user.email=t@t -c user.name=t commit -q -m "fixture" 2>/dev/null

# ── Test 1: parent UNSET → child observes EXPECTED_PLUGIN_ROOT ────────────
unset CLAUDE_PLUGIN_ROOT
STATE_FILE_1=$(mktemp -u)
out1=$(cd "$FIXTURE" && \
    TEST_BATCHED_STATE_FILE="$STATE_FILE_1" \
    timeout 30 bash "$TEST_BATCHED" --timeout=20 --per-test-timeout=20 \
    --runner=bash --test-dir=tests/hooks "x" 2>&1)
if echo "$out1" | grep -qF "PROBE_CLAUDE_PLUGIN_ROOT=$EXPECTED_PLUGIN_ROOT"; then
    pass_msg
else
    fail_msg "Test 1: child should observe CLAUDE_PLUGIN_ROOT=$EXPECTED_PLUGIN_ROOT when parent is unset. Output: $out1"
fi
rm -f "$STATE_FILE_1"

# ── Test 2: parent SET → child inherits parent's value ────────────────────
EXTERNAL_ROOT="/some/external/plugin/root"
STATE_FILE_2=$(mktemp -u)
out2=$(cd "$FIXTURE" && \
    CLAUDE_PLUGIN_ROOT="$EXTERNAL_ROOT" \
    TEST_BATCHED_STATE_FILE="$STATE_FILE_2" \
    timeout 30 bash "$TEST_BATCHED" --timeout=20 --per-test-timeout=20 \
    --runner=bash --test-dir=tests/hooks "x" 2>&1)
if echo "$out2" | grep -qF "PROBE_CLAUDE_PLUGIN_ROOT=$EXTERNAL_ROOT"; then
    pass_msg
else
    fail_msg "Test 2: child should inherit parent's CLAUDE_PLUGIN_ROOT=$EXTERNAL_ROOT. Output: $out2"
fi
rm -f "$STATE_FILE_2"

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
