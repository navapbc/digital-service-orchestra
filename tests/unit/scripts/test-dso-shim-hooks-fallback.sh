#!/usr/bin/env bash
# tests/unit/scripts/test-dso-shim-hooks-fallback.sh
# RED tests for dso shim hooks/ fallback (tickets: 7f36-1317, d122-20d3)
#
# The shim dispatches commands via $DSO_ROOT/scripts/<cmd>. Hook scripts
# like record-test-status.sh live in $DSO_ROOT/hooks/ and must also be
# accessible via the shim.
#
# Usage: bash tests/unit/scripts/test-dso-shim-hooks-fallback.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SHIM="$REPO_ROOT/.claude/scripts/dso"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-dso-shim-hooks-fallback.sh ==="

# ── Fixtures ──────────────────────────────────────────────────────────────────
FAKE_PLUGIN="$(mktemp -d)"
mkdir -p "$FAKE_PLUGIN/scripts"
mkdir -p "$FAKE_PLUGIN/hooks"

cat > "$FAKE_PLUGIN/hooks/test-hook-cmd.sh" <<'EOF'
#!/usr/bin/env bash
echo "hook-cmd-output"
exit 0
EOF
chmod +x "$FAKE_PLUGIN/hooks/test-hook-cmd.sh"

trap 'rm -rf "$FAKE_PLUGIN"' EXIT

# ── Test 1: hook script reachable via shim (hooks/ fallback) ──────────────────
echo "Test 1: shim dispatches hook script via hooks/ fallback"
RESULT=$(CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" bash "$SHIM" test-hook-cmd.sh 2>&1)
EXIT_CODE=$?
assert_eq "shim exit code for hook cmd" "0" "$EXIT_CODE"
assert_contains "hook output" "hook-cmd-output" "$RESULT"

# ── Test 2: unknown command still fails with exit 127 ─────────────────────────
echo "Test 2: shim correctly fails for unknown command"
if CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN" bash "$SHIM" nonexistent-cmd.sh >/dev/null 2>&1; then
    (( ++FAIL ))
    echo "FAIL: unknown command should not succeed" >&2
else
    ECODE=$?
    assert_eq "unknown command exit code" "127" "$ECODE"
fi

# ── Test 3: real record-test-status.sh reachable via shim in this repo ────────
echo "Test 3: record-test-status.sh accessible via shim in this repo"
RTS_OUTPUT=$(CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" bash "$SHIM" record-test-status.sh --help 2>&1 || true)
if echo "$RTS_OUTPUT" | grep -q "command not found"; then
    (( ++FAIL ))
    printf "FAIL: record-test-status.sh not reachable via dso shim\n  got: %s\n" "$RTS_OUTPUT" >&2
else
    (( ++PASS ))
fi

print_summary
