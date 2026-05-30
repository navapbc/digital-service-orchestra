#!/usr/bin/env bash
# Test check-deleted-bridge-imports.sh advisory + strict modes.
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
SCRIPT="$REPO_ROOT/plugins/dso/scripts/check-deleted-bridge-imports.sh"

# Test 1: script exists and is executable
test -x "$SCRIPT" || { echo "FAIL: script not executable"; exit 1; }

# Test 2: advisory mode always exits 0
OUT=$("$SCRIPT" --advisory 2>&1) && echo "PASS: advisory exit 0"

# Test 3: output mentions all 4 zones
echo "$OUT" | grep -q "Zone reconciler:" || { echo "FAIL: missing reconciler zone"; exit 1; }
echo "$OUT" | grep -q "Zone workflows:" || { echo "FAIL: missing workflows zone"; exit 1; }
echo "$OUT" | grep -q "Zone tests:" || { echo "FAIL: missing tests zone"; exit 1; }
echo "$OUT" | grep -q "Zone repo:" || { echo "FAIL: missing repo zone"; exit 1; }
echo "PASS: all 4 zones reported"

# Test 4: TOTAL HITS line printed
echo "$OUT" | grep -q "TOTAL HITS:" || { echo "FAIL: missing total"; exit 1; }
echo "PASS: total hits reported"

# Test 5: strict mode exits 0 with CLAUDE_PLUGIN_ROOT unset
if ( unset CLAUDE_PLUGIN_ROOT; "$SCRIPT" --strict >/dev/null 2>&1 ); then
    echo "PASS: strict + CLAUDE_PLUGIN_ROOT unset -> exit 0"
else
    echo "FAIL: strict + CLAUDE_PLUGIN_ROOT unset"; exit 1
fi

# Test 6: strict mode exits 0 with CLAUDE_PLUGIN_ROOT pointing at an external
# path (simulating the normal session env where CLAUDE_PLUGIN_ROOT points at
# the main repo's plugin cache, outside the worktree). The script must derive
# the reconciler zone from $0 (its own location), not from CLAUDE_PLUGIN_ROOT.
FAKE_PLUGIN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fake-plugin-root-XXXXXX")
trap 'rm -rf "$FAKE_PLUGIN_ROOT"' EXIT
RC=0
CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN_ROOT" "$SCRIPT" --strict >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 0 ]]; then
    echo "PASS: strict + CLAUDE_PLUGIN_ROOT external -> exit 0"
else
    echo "FAIL: strict + CLAUDE_PLUGIN_ROOT external (got $RC)"; exit 1
fi

echo "All tests pass"
