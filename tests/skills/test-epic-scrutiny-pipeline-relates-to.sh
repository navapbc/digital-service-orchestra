#!/usr/bin/env bash
# Structural boundary tests for the relates_to link suggestion behavior in
# epic-scrutiny-pipeline.md Part C.
#
# RATIONALE FOR SOURCE-GREPPING:
# epic-scrutiny-pipeline.md is a non-executable instruction document — its section
# headings, mandatory markers, and structural elements ARE the behavioral contract
# consumed by LLM agents at runtime. The established pattern in this codebase
# (see tests/skills/test-epic-scrutiny-pipeline.sh, test-prompt-alignment-step.sh)
# is to verify instruction documents by grepping for structural contract markers —
# section headings, required keys, and integration-point references. These tests
# follow that established pattern per behavioral testing standard Rule 5.
#
# Rule 5 compliance: all assertions target structural elements (section heading,
# mandatory gate marker, required filter term, required CLI reference) — not
# wording or prose content. These are the deterministic integration interface
# of the instruction document.
#
# All 4 tests FAIL in RED state because the relates_to link suggestion has not
# yet been added to Part C of epic-scrutiny-pipeline.md.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Part C section contains a relates_to link suggestion subsection
# (structural contract: the section heading / label must exist in Part C)
# ---------------------------------------------------------------------------
test_part_c_contains_relates_to_suggestion() {
  echo "=== test_part_c_contains_relates_to_suggestion ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for relates_to suggestion"
    return
  fi

  # Extract the Part C section (from '### Part C' to the next '###' or '##' heading)
  local part_c_start
  part_c_start=$(grep -n "^### Part C" "$PIPELINE_MD" | head -1 | cut -d: -f1)

  if [ -z "$part_c_start" ]; then
    fail "Part C section not found in pipeline — cannot check for relates_to suggestion"
    return
  fi

  local part_c_content
  part_c_content=$(awk "NR==${part_c_start}{found=1} found && NR>${part_c_start} && /^##/{exit} found{print}" "$PIPELINE_MD")

  # The relates_to link suggestion must appear within the Part C section
  if echo "$part_c_content" | grep -qiE "relates_to|relates-to"; then
    pass "Part C section contains relates_to link suggestion"
  else
    fail "Part C section missing relates_to link suggestion (grep: 'relates_to|relates-to' in Part C)"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: User approval gate is present before relates_to link creation
# (structural contract: user confirmation gate must be explicitly required
# before any automated link is created)
# ---------------------------------------------------------------------------
test_relates_to_has_user_approval_gate() {
  echo ""
  echo "=== test_relates_to_has_user_approval_gate ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for user approval gate"
    return
  fi

  # Extract Part C section content
  local part_c_start
  part_c_start=$(grep -n "^### Part C" "$PIPELINE_MD" | head -1 | cut -d: -f1)

  if [ -z "$part_c_start" ]; then
    fail "Part C section not found in pipeline — cannot check for user approval gate"
    return
  fi

  local part_c_content
  part_c_content=$(awk "NR==${part_c_start}{found=1} found && NR>${part_c_start} && /^##/{exit} found{print}" "$PIPELINE_MD")

  # The relates_to suggestion must include a user approval step before creating links.
  # Look for approval/confirmation/AskUser gate markers within Part C
  if echo "$part_c_content" | grep -qiE "(AskUser|user.*approv|user.*confirm|confirm.*user|approv.*link|before.*creat)"; then
    pass "Part C contains user approval gate for relates_to link creation"
  else
    fail "Part C missing user approval gate for relates_to link creation (grep: AskUser/user approval/confirm in Part C)"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Open-only filter is documented (status=open)
# (structural contract: relates_to suggestion must specify filtering to open
# tickets only — not all tickets)
# ---------------------------------------------------------------------------
test_relates_to_open_only_filter() {
  echo ""
  echo "=== test_relates_to_open_only_filter ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for open-only filter"
    return
  fi

  # Extract Part C section content
  local part_c_start
  part_c_start=$(grep -n "^### Part C" "$PIPELINE_MD" | head -1 | cut -d: -f1)

  if [ -z "$part_c_start" ]; then
    fail "Part C section not found in pipeline — cannot check for open-only filter"
    return
  fi

  local part_c_content
  part_c_content=$(awk "NR==${part_c_start}{found=1} found && NR>${part_c_start} && /^##/{exit} found{print}" "$PIPELINE_MD")

  # The open-only filter must appear in Part C — either via 'status=open', 'open epics',
  # 'open tickets', or the --status open flag
  if echo "$part_c_content" | grep -qiE "(status=open|status.*open|open.*status|open.*epic|open.*ticket|--status open|filter.*open)"; then
    pass "Part C documents open-only filter for relates_to ticket search"
  else
    fail "Part C missing open-only filter for relates_to ticket search (grep: status=open/open tickets/open epics in Part C)"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Link creation references ticket CLI for relates_to relation type
# (structural contract: must reference the ticket link CLI command with
# 'relates_to' as the relation type — not free-form or implied)
# ---------------------------------------------------------------------------
test_relates_to_uses_ticket_link_cli() {
  echo ""
  echo "=== test_relates_to_uses_ticket_link_cli ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for ticket CLI link reference"
    return
  fi

  # Extract Part C section content
  local part_c_start
  part_c_start=$(grep -n "^### Part C" "$PIPELINE_MD" | head -1 | cut -d: -f1)

  if [ -z "$part_c_start" ]; then
    fail "Part C section not found in pipeline — cannot check for ticket CLI link reference"
    return
  fi

  local part_c_content
  part_c_content=$(awk "NR==${part_c_start}{found=1} found && NR>${part_c_start} && /^##/{exit} found{print}" "$PIPELINE_MD")

  # The link creation must reference the ticket link CLI command
  # Pattern: 'ticket link' (the CLI subcommand) in the Part C section
  local has_ticket_link=false
  local has_relates_to=false

  echo "$part_c_content" | grep -qiE "(ticket link|dso ticket link)" && has_ticket_link=true
  echo "$part_c_content" | grep -qiE "relates_to" && has_relates_to=true

  if [ "$has_ticket_link" = "true" ] && [ "$has_relates_to" = "true" ]; then
    pass "Part C references ticket link CLI command with relates_to relation type"
  else
    local what_missing=()
    [ "$has_ticket_link" = "false" ] && what_missing+=("ticket link CLI reference")
    [ "$has_relates_to" = "false" ]  && what_missing+=("relates_to relation type")
    fail "Part C missing for ticket link CLI: ${what_missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_part_c_contains_relates_to_suggestion
test_relates_to_has_user_approval_gate
test_relates_to_open_only_filter
test_relates_to_uses_ticket_link_cli

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
