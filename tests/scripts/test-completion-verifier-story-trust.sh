#!/usr/bin/env bash
# tests/scripts/test-completion-verifier-story-trust.sh
# Structural boundary tests for completion-verifier.md Step 3a and Step 3b.
#
# Tests:
#  1. Step 3a section exists in completion-verifier.md
#  2. Step 3a is positioned between Step 3 and Step 4
#  3. Step 3b section exists in completion-verifier.md
#  4. Step 3b is positioned between Step 3a and Step 4
#
# Usage: bash tests/scripts/test-completion-verifier-story-trust.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_MD="$PLUGIN_ROOT/plugins/dso/agents/completion-verifier.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-completion-verifier-story-trust.sh ==="

# ── test_step_3a_section_exists ──────────────────────────────────────────────
_snapshot_fail
_has=0
if grep -q "^### Step 3a: Epic-Level Story Verdict Trust" "$AGENT_MD"; then
    _has=1
fi
assert_eq "test_step_3a_section_exists: Step 3a section must exist" "1" "$_has"
assert_pass_if_clean "test_step_3a_section_exists"

# ── test_step_3a_between_3_and_4 ────────────────────────────────────────────
_snapshot_fail
_step3_line=$(grep -n "^### Step 3:" "$AGENT_MD" | head -1 | cut -d: -f1)
_step3a_line=$(grep -n "^### Step 3a:" "$AGENT_MD" | head -1 | cut -d: -f1)
_step4_line=$(grep -n "^### Step 4:" "$AGENT_MD" | head -1 | cut -d: -f1)
_ordered=0
if [[ -n "$_step3_line" && -n "$_step3a_line" && -n "$_step4_line" ]]; then
    if (( _step3_line < _step3a_line && _step3a_line < _step4_line )); then
        _ordered=1
    fi
fi
assert_eq "test_step_3a_between_3_and_4: Step 3a must be between Step 3 and Step 4" "1" "$_ordered"
assert_pass_if_clean "test_step_3a_between_3_and_4"

# ── test_step_3b_section_exists ──────────────────────────────────────────────
_snapshot_fail
_has=0
if grep -q "^### Step 3b: Manual Story Sentinel Check" "$AGENT_MD"; then
    _has=1
fi
assert_eq "test_step_3b_section_exists: Step 3b section must exist" "1" "$_has"
assert_pass_if_clean "test_step_3b_section_exists"

# ── test_step_3b_between_3a_and_4 ───────────────────────────────────────────
_snapshot_fail
_step3a_line=$(grep -n "^### Step 3a:" "$AGENT_MD" | head -1 | cut -d: -f1)
_step3b_line=$(grep -n "^### Step 3b:" "$AGENT_MD" | head -1 | cut -d: -f1)
_step4_line=$(grep -n "^### Step 4:" "$AGENT_MD" | head -1 | cut -d: -f1)
_ordered=0
if [[ -n "$_step3a_line" && -n "$_step3b_line" && -n "$_step4_line" ]]; then
    if (( _step3a_line < _step3b_line && _step3b_line < _step4_line )); then
        _ordered=1
    fi
fi
assert_eq "test_step_3b_between_3a_and_4: Step 3b must be between Step 3a and Step 4" "1" "$_ordered"
assert_pass_if_clean "test_step_3b_between_3a_and_4"

print_summary
