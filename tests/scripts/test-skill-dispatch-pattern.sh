#!/usr/bin/env bash
# tests/scripts/test-skill-dispatch-pattern.sh
# Tests skill files for the two real dispatch failure modes from bug 2c4d-490b:
#   (1) double-prefix: `dso:dso:<name>` — an agent appending its own dso: prefix
#       to an already-prefixed name
#   (2) missing fallback: a named `subagent_type: "dso:<name>"` dispatch with no
#       fallback to `general-purpose` for environments where the named type is
#       unregistered (e.g., local plugin development)
#
# Named-first dispatch IS valid when paired with an explicit fallback — this
# matches CLAUDE.md guidance: "Use subagent_type: 'dso:<name>' directly when the
# agent is registered. Fall back to subagent_type: 'general-purpose' with the
# agent file loaded verbatim only when the named type is not registered."
#
# Files checked: update-docs/SKILL.md, brainstorm/SKILL.md,
#   resolve-conflicts/SKILL.md, preplanning/SKILL.md,
#   preplanning/prompts/ui-designer-dispatch-protocol.md,
#   plan-review/SKILL.md
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

# ── Test 1a: No double-prefix `dso:dso:<name>` anywhere ───────────────────────
# Failure mode 1 from bug 2c4d-490b: an agent appending its own dso: prefix to
# an already-prefixed name. Block this everywhere — there is no valid use.
echo "Test 1a: Skill files do not contain double-prefix dso:dso:<name>"
_double_prefix_files=()
for _label in "${!FILES[@]}"; do
    _file="${FILES[$_label]}"
    [[ -f "$_file" ]] || continue
    if grep -qE 'dso:dso:' "$_file" 2>/dev/null; then
        _double_prefix_files+=("$_label")
    fi
done
if [[ "${#_double_prefix_files[@]}" -gt 0 ]]; then
    echo "  FAIL: double-prefix dso:dso:<name> found in: ${_double_prefix_files[*]}" >&2
    (( FAIL++ ))
else
    echo "  PASS: no double-prefix dso:dso: occurrences"
    (( PASS++ ))
fi

# ── Test 1b: Named `subagent_type: "dso:<name>"` must be paired with fallback ─
# Failure mode 2 from bug 2c4d-490b: a named dispatch with no fallback breaks in
# environments where the dso:* type is unregistered (e.g., local plugin dev).
# Per CLAUDE.md, named dispatch is valid when paired with an explicit fallback
# clause to `subagent_type: "general-purpose"`. This test asserts: if the file
# uses named dispatch at all, it MUST also contain fallback guidance.
echo "Test 1b: Named subagent_type: \"dso:<name>\" dispatch is paired with general-purpose fallback"
_missing_fallback_files=()
for _label in "${!FILES[@]}"; do
    _file="${FILES[$_label]}"
    [[ -f "$_file" ]] || continue
    if grep -qE 'subagent_type:[[:space:]]*"dso:' "$_file" 2>/dev/null; then
        # Named dispatch present — require an explicit general-purpose fallback
        # clause somewhere in the same file. The fallback phrase indicates
        # the orchestrator should switch to general-purpose when the named
        # type is unavailable.
        if ! grep -qiE 'fall back to[^"]*subagent_type:[[:space:]]*"general-purpose"|unregistered.*general-purpose|general-purpose.*if.*unregistered|fallback.*general-purpose' "$_file" 2>/dev/null; then
            _missing_fallback_files+=("$_label")
        fi
    fi
done
if [[ "${#_missing_fallback_files[@]}" -gt 0 ]]; then
    echo "  FAIL: named subagent_type: \"dso:<name>\" dispatch without general-purpose fallback in: ${_missing_fallback_files[*]}" >&2
    echo "        Either remove named dispatch (use subagent_type: \"general-purpose\" + inline agent file content) or add explicit fallback clause." >&2
    (( FAIL++ ))
else
    echo "  PASS: all named dso: dispatches are paired with general-purpose fallback (or no named dispatch present)"
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
