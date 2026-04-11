#!/usr/bin/env bash
# tests/scripts/test-skill-dispatch-pattern.sh
# Tests that skill files do not use invalid dso:* subagent_type values.
#
# Bug 2c4d-490b: Same anti-pattern as a541-0ad7 (REVIEW-WORKFLOW.md).
# Affected files: update-docs/SKILL.md, brainstorm/SKILL.md,
#   resolve-conflicts/SKILL.md, preplanning/SKILL.md,
#   preplanning/prompts/ui-designer-dispatch-protocol.md,
#   plan-review/SKILL.md
#
# The Agent tool only accepts built-in subagent_type values (general-purpose,
# Explore, Plan, etc.) — dso:* labels are agent file identifiers, NOT valid
# subagent_type values.
#
# Usage: bash tests/scripts/test-skill-dispatch-pattern.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-skill-dispatch-pattern.sh ==="

# Files to check
declare -A FILES
FILES["update-docs"]="$PLUGIN_ROOT/plugins/dso/skills/update-docs/SKILL.md"
FILES["brainstorm"]="$PLUGIN_ROOT/plugins/dso/skills/brainstorm/SKILL.md"
FILES["resolve-conflicts"]="$PLUGIN_ROOT/plugins/dso/skills/resolve-conflicts/SKILL.md"
FILES["preplanning"]="$PLUGIN_ROOT/plugins/dso/skills/preplanning/SKILL.md"
FILES["ui-designer-dispatch-protocol"]="$PLUGIN_ROOT/plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md"
FILES["plan-review"]="$PLUGIN_ROOT/plugins/dso/skills/plan-review/SKILL.md"

# ── Test 1: No invalid dso: subagent_type values in any skill file ────────────
# The Agent tool only accepts built-in subagent types (general-purpose, Explore, etc.).
# dso:* values are agent file identifiers — using them as subagent_type is invalid.
# This test catches both code block and inline prose occurrences.
echo "Test 1: Skill files do not use invalid subagent_type: \"dso:\" values"
_found_invalid=0
_bad_files=()
for _label in "${!FILES[@]}"; do
    _file="${FILES[$_label]}"
    if [[ ! -f "$_file" ]]; then
        echo "  WARN: $_label file not found: $_file" >&2
        continue
    fi
    if grep -qE 'subagent_type:[[:space:]]*"dso:' "$_file" 2>/dev/null; then
        _found_invalid=1
        _bad_files+=("$_label")
    fi
done
if [[ "$_found_invalid" -eq 1 ]]; then
    echo "  FAIL: invalid subagent_type: \"dso:*\" found in: ${_bad_files[*]}" >&2
    echo "        Replace with subagent_type: \"general-purpose\" + inline agent file content" >&2
    (( FAIL++ ))
else
    echo "  PASS: no invalid dso: subagent_type values in skill files"
    (( PASS++ ))
fi

# ── Test 2: Inline dispatch guidance present in update-docs/SKILL.md ─────────
# The skill must instruct the orchestrator to read the agent file inline.
echo "Test 2: update-docs/SKILL.md contains inline dispatch guidance"
_file="${FILES["update-docs"]}"
if [[ -f "$_file" ]] && \
   grep -q "subagent_type.*general-purpose" "$_file" 2>/dev/null && \
   grep -qiE "read.*doc-writer\.md|doc-writer\.md.*inline|inline.*agent" "$_file" 2>/dev/null; then
    echo "  PASS: update-docs/SKILL.md contains inline dispatch guidance"
    (( PASS++ ))
else
    echo "  FAIL: update-docs/SKILL.md missing inline dispatch guidance" >&2
    echo "        Must instruct: read plugins/dso/agents/doc-writer.md inline, use subagent_type: \"general-purpose\"" >&2
    (( FAIL++ ))
fi

# ── Test 3: Inline dispatch guidance present in plan-review/SKILL.md ─────────
echo "Test 3: plan-review/SKILL.md contains inline dispatch guidance"
_file="${FILES["plan-review"]}"
if [[ -f "$_file" ]] && \
   grep -q "subagent_type.*general-purpose" "$_file" 2>/dev/null && \
   grep -qiE "read.*plan-review\.md|plan-review\.md.*inline|inline.*agent" "$_file" 2>/dev/null; then
    echo "  PASS: plan-review/SKILL.md contains inline dispatch guidance"
    (( PASS++ ))
else
    echo "  FAIL: plan-review/SKILL.md missing inline dispatch guidance" >&2
    echo "        Must instruct: read plugins/dso/agents/plan-review.md inline, use subagent_type: \"general-purpose\"" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
