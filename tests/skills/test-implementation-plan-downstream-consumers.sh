#!/usr/bin/env bash
# tests/skills/test-implementation-plan-downstream-consumers.sh
# Structural boundary test: implementation-plan SKILL.md must contain a
# "### Consumer Detection Pass" subsection in Step 3.
#
# Regression guard for story c8f2-1aee (ticket 2f80-2246):
# Enriched task descriptions: Downstream consumer detection.
#
# Per behavioral-testing-standard.md Rule 5, instruction-file tests check the
# STRUCTURAL BOUNDARY — the presence of required section headings and their
# key structural markers — not wording or content assertions.
#
# What we test (structural boundary):
#   1. "### Consumer Detection Pass" heading exists in the SKILL.md
#   2. The section references ast-grep / sg as the consumer-detection tool
#   3. The section mentions what to do when external consumers are found
#      (structural marker: "external consumer", "callsite", or "caller" present)
#
# All 3 tests FAIL (RED) until the ### Consumer Detection Pass subsection is
# added to SKILL.md.
#
# Usage:
#   bash tests/skills/test-implementation-plan-downstream-consumers.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-downstream-consumers.sh ==="
echo ""

# Helper: extract the "### Consumer Detection Pass" section from SKILL.md
# (from that heading to the next ### heading)
_extract_consumer_section() {
  awk '/^### Consumer Detection Pass/{found=1} found && /^### / && !/^### Consumer Detection Pass/{exit} found{print}' "$SKILL_FILE"
}

# ===========================================================================
# test_downstream_consumers_heading_present
#
# Given: implementation-plan/SKILL.md
# When: we search for the "### Consumer Detection Pass" heading
# Then: the heading must exist (structural boundary: section presence)
#
# Structural boundary: the heading itself is the contract — not its content.
# RED before implementation: heading absent → section contract not met.
# GREEN after implementation: heading present → section exists.
# ===========================================================================
test_downstream_consumers_heading_present() {
  local _found=0
  grep -q "^### Consumer Detection Pass" "$SKILL_FILE" && _found=1

  assert_eq \
    "test_downstream_consumers_heading_present: '### Consumer Detection Pass' heading must exist in SKILL.md" \
    "1" "$_found"
}

# ===========================================================================
# test_downstream_consumers_ast_grep_pattern
#
# Given: implementation-plan/SKILL.md "### Consumer Detection Pass" section
# When: we extract the section and check for ast-grep / sg tool reference
# Then: the section must mention "ast-grep" or "sg" as the detection tool
#
# Structural boundary: tool name presence in the section is the contract.
# RED before implementation: section absent / tool not mentioned.
# GREEN after implementation: "ast-grep" or the "sg" command appears in the section.
# ===========================================================================
test_downstream_consumers_ast_grep_pattern() {
  local _section
  _section=$(_extract_consumer_section)

  local _found=0
  echo "$_section" | grep -qE "ast-grep|\bsg\b" && _found=1

  assert_eq \
    "test_downstream_consumers_ast_grep_pattern: Consumer Detection Pass section must reference 'ast-grep' or 'sg' tool" \
    "1" "$_found"
}

# ===========================================================================
# test_downstream_consumers_external_consumer_rule
#
# Given: implementation-plan/SKILL.md "### Consumer Detection Pass" section
# When: we extract the section and check for external-consumer guidance
# Then: the section must mention what to do when external consumers exist
#       (structural marker: "external consumer", "callsite", or "caller")
#
# Structural boundary: a key domain term — not specific wording — must appear.
# RED before implementation: section absent / no external-consumer guidance.
# GREEN after implementation: at least one structural marker term is present.
# ===========================================================================
test_downstream_consumers_external_consumer_rule() {
  local _section
  _section=$(_extract_consumer_section)

  local _found=0
  echo "$_section" | grep -qE "external.consumer|callsite|caller" && _found=1

  assert_eq \
    "test_downstream_consumers_external_consumer_rule: Consumer Detection Pass section must describe external consumer handling ('external consumer', 'callsite', or 'caller')" \
    "1" "$_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_downstream_consumers_heading_present
test_downstream_consumers_ast_grep_pattern
test_downstream_consumers_external_consumer_rule

print_summary
