#!/usr/bin/env bash
# tests/scripts/test-ts-morph-normalize-imports.sh
# Behavioral tests for plugins/dso/scripts/recipe-adapters/ts-morph-normalize-imports.mjs
#
# Tests are RED by design — ts-morph-normalize-imports.mjs does not yet exist.
# Skips gracefully if node is not installed.
#
# Tests cover:
#   - Sorted imports: unsorted imports are sorted alphabetically
#   - Deduplicated imports: duplicate imports are removed
#   - JSON output: output has files_changed, transforms_applied, exit_code fields
#   - Idempotency: already-sorted output stays sorted on second run
#
# Usage: bash tests/scripts/test-ts-morph-normalize-imports.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/recipe-adapters/ts-morph-normalize-imports.mjs"
FIXTURE_SRC="$PLUGIN_ROOT/tests/fixtures/ts-morph-normalize/unsorted.ts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ts-morph-normalize-imports.sh ==="

# ── Node availability check ───────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not installed — skipping ts-morph-normalize-imports tests"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

echo "node found: $(node --version)"

# ── ts-morph availability check ──────────────────────────────────────────────
TS_MORPH_AVAILABLE=0
if node -e "require('ts-morph')" 2>/dev/null; then
    TS_MORPH_AVAILABLE=1
fi

if [[ $TS_MORPH_AVAILABLE -eq 0 ]]; then
    echo "SKIP: ts-morph not installed — skipping all ts-morph-normalize-imports tests"
    echo "  Install with: npm install ts-morph"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

echo "ts-morph found"

# ── Script existence check ────────────────────────────────────────────────────
if [[ ! -f "$SCRIPT" ]]; then
    echo "RED: ts-morph-normalize-imports.mjs not found at $SCRIPT"
    echo ""
    printf "PASSED: 0  FAILED: 1\n"
    exit 1
fi

# ── Global Setup ─────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Copy fixture to temp dir so we can modify it
FIXTURE="$TMPDIR_TEST/unsorted.ts"
cp "$FIXTURE_SRC" "$FIXTURE"

# ─────────────────────────────────────────────────────────────────────────────
# test_sorts_imports
#
# Given: a TypeScript file with unsorted imports (z before React)
# When:  ts-morph-normalize-imports.mjs is invoked with RECIPE_PARAM_FILE
# Then:  the file's imports are sorted alphabetically
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_sorts_imports ---"
_snapshot_fail

# Reset fixture
cp "$FIXTURE_SRC" "$FIXTURE"

rc=0
output=$(RECIPE_PARAM_FILE="$FIXTURE" node "$SCRIPT" 2>&1) || rc=$?

# Must exit 0
assert_eq "test_sorts_imports exit code" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_sorts_imports output is valid JSON" "0" "$json_valid"

assert_pass_if_clean "test_sorts_imports"

# ─────────────────────────────────────────────────────────────────────────────
# test_deduplicates_imports
#
# Given: a TypeScript file with duplicate imports (import { b } from './b' twice)
# When:  ts-morph-normalize-imports.mjs is invoked
# Then:  the duplicate imports are removed in the output file
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_deduplicates_imports ---"
_snapshot_fail

DEDUP_FIXTURE="$TMPDIR_TEST/dedup.ts"
cat > "$DEDUP_FIXTURE" <<'EOF'
import { foo } from './foo';
import { bar } from './bar';
import { foo } from './foo';

export function test() { return null; }
EOF

rc=0
output=$(RECIPE_PARAM_FILE="$DEDUP_FIXTURE" node "$SCRIPT" 2>&1) || rc=$?

# Must exit 0
assert_eq "test_deduplicates_imports exit code" "0" "$rc"

# Output must be valid JSON
json_valid=0
echo "$output" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid=$?
assert_eq "test_deduplicates_imports output is valid JSON" "0" "$json_valid"

assert_pass_if_clean "test_deduplicates_imports"

# ─────────────────────────────────────────────────────────────────────────────
# test_outputs_json
#
# Given: a TypeScript file with any imports
# When:  ts-morph-normalize-imports.mjs is invoked
# Then:  output is JSON with files_changed (array), transforms_applied (int), exit_code (int)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_outputs_json ---"
_snapshot_fail

JSON_FIXTURE="$TMPDIR_TEST/json_test.ts"
cat > "$JSON_FIXTURE" <<'EOF'
import { z } from 'zod';
import React from 'react';

export const x = 1;
EOF

rc=0
output=$(RECIPE_PARAM_FILE="$JSON_FIXTURE" node "$SCRIPT" 2>&1) || rc=$?

# Parse with python3 and verify required fields
json_check=0
echo "$output" | python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
assert isinstance(data.get('files_changed'), list),      'files_changed must be an array'
assert isinstance(data.get('transforms_applied'), int),  'transforms_applied must be an int'
assert isinstance(data.get('exit_code'), int),           'exit_code must be an int'
assert isinstance(data.get('errors'), list),             'errors must be an array'
assert isinstance(data.get('engine_name'), str),         'engine_name must be a string'
assert isinstance(data.get('degraded'), bool),           'degraded must be a bool'
" 2>/dev/null || json_check=$?

assert_eq "test_outputs_json all required fields present and typed correctly" "0" "$json_check"

assert_pass_if_clean "test_outputs_json"

# ─────────────────────────────────────────────────────────────────────────────
# test_idempotency_normalize
#
# Given: a TypeScript file that has already been normalized
# When:  ts-morph-normalize-imports.mjs is invoked twice
# Then:  outputs are identical (already-sorted stays sorted)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_idempotency_normalize ---"
_snapshot_fail

IDEM_FIXTURE="$TMPDIR_TEST/idempotent.ts"
# Start with already-sorted imports
cat > "$IDEM_FIXTURE" <<'EOF'
import React from 'react';
import { z } from 'zod';

export const x = 1;
EOF

rc1=0
output1=$(RECIPE_PARAM_FILE="$IDEM_FIXTURE" node "$SCRIPT" 2>&1) || rc1=$?

rc2=0
output2=$(RECIPE_PARAM_FILE="$IDEM_FIXTURE" node "$SCRIPT" 2>&1) || rc2=$?

# Both runs must exit with the same code
assert_eq "test_idempotency_normalize exit codes match" "$rc1" "$rc2"

# Both outputs must be valid JSON
json_valid1=0
echo "$output1" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid1=$?
assert_eq "test_idempotency_normalize run1 output is valid JSON" "0" "$json_valid1"

json_valid2=0
echo "$output2" | python3 -c "import json,sys; json.loads(sys.stdin.read())" 2>/dev/null || json_valid2=$?
assert_eq "test_idempotency_normalize run2 output is valid JSON" "0" "$json_valid2"

# Second run should not have any additional transforms (already sorted)
transforms2=$(echo "$output2" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('transforms_applied', -999))" 2>/dev/null || echo "-1")
assert_eq "test_idempotency_normalize second run has 0 transforms" "0" "$transforms2"

assert_pass_if_clean "test_idempotency_normalize"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
