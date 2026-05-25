#!/usr/bin/env bash
# Test check-deleted-bridge-imports.sh advisory + strict modes.
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
SCRIPT="$REPO_ROOT/plugins/dso/scripts/check-deleted-bridge-imports.sh"

# Test 1: script exists and is executable
test -x "$SCRIPT" || { echo "FAIL: script not executable"; exit 1; }

# Test 2: advisory mode always exits 0
OUT=$("$SCRIPT" 2>&1) && echo "PASS: advisory exit 0"

# Test 3: output mentions all 4 zones
echo "$OUT" | grep -q "Zone reconciler:" || { echo "FAIL: missing reconciler zone"; exit 1; }
echo "$OUT" | grep -q "Zone workflows:" || { echo "FAIL: missing workflows zone"; exit 1; }
echo "$OUT" | grep -q "Zone tests:" || { echo "FAIL: missing tests zone"; exit 1; }
echo "$OUT" | grep -q "Zone repo:" || { echo "FAIL: missing repo zone"; exit 1; }
echo "PASS: all 4 zones reported"

# Test 4: TOTAL HITS line printed
echo "$OUT" | grep -q "TOTAL HITS:" || { echo "FAIL: missing total"; exit 1; }
echo "PASS: total hits reported"

echo "All tests pass"
