#!/usr/bin/env bash
# tests/test-brainstorm-copy-needs-writer.sh
# Behavioral tests for brainstorm Phase 1.5 Copy Needs section write mechanism.
#
# Covers story 3136-e839-4f17-4dd0, task b225-2836-ebd2-4595.
# DDs tested:
#   dd-2 (3136): the same brainstorm run writes a ## Copy Needs section into the
#                epic description that passes the schema validator
#   dd-3 (3136): each Copy Needs item written by brainstorm carries stable_id,
#                type, location, page, and validation rule populated
#
# Test plan:
#   1. CLI mechanism: no native --append-section flag; read-append-write workflow documented
#   2. CLI mechanism: ticket edit --description is the write command documented
#   3. Idempotency: existing ## Copy Needs header triggers body-replace, not header-duplication
#   4. Idempotency: replace-body language is documented (not just "don't append")
#   5. Schema: schema_version: 1 is placed at the top of the section
#   6. Step ordering: tag write (Step 4a) is documented as separate from section write (Step 4c)
#   7. Mechanism: python3 is used to extract description before append
#   8. Idempotency re-run: SKILL.md describes stable_id-based deduplication for re-runs
#   9. Mechanism: the _NEW_DESC variable or equivalent assembled before ticket edit call
#  10. Mechanism: no --append-section flag (negative assertion)

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/.." && pwd)"

SKILL_FILE="$_PLUGIN_ROOT/skills/brainstorm/SKILL.md"
CONTRACT_FILE="$_PLUGIN_ROOT/docs/contracts/copy-needs-section.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== brainstorm Phase 1.5 Copy Needs section write mechanism tests ==="

if [[ ! -f "$SKILL_FILE" ]]; then
    echo "FATAL: SKILL.md not found at $SKILL_FILE"
    exit 1
fi

if [[ ! -f "$CONTRACT_FILE" ]]; then
    echo "FATAL: copy-needs-section.md not found at $CONTRACT_FILE"
    exit 1
fi

echo ""
echo "--- Test 1: No native --append-section flag; read-append-write workflow documented ---"
# The skill must clarify that the CLI has no native append-section flag and the
# correct pattern is: read current description → build new block → write back.
if grep -qE 'no.*append.section|append.section.*not|read.*append.*write|read.*description.*append|retrieve.*current.*description' "$SKILL_FILE"; then
    pass "SKILL.md documents the read-current-description → append → write mechanism"
else
    fail "SKILL.md does not document the read-append-write workflow for Copy Needs section"
fi

echo ""
echo "--- Test 2: ticket edit --description is the documented write command ---"
if grep -qE 'ticket edit.*--description|--description.*ticket edit' "$SKILL_FILE"; then
    pass "SKILL.md documents 'ticket edit --description' as the write mechanism"
else
    fail "SKILL.md does not reference 'ticket edit --description' for section write"
fi

echo ""
echo "--- Test 3: Existing ## Copy Needs header triggers body-replace, not header-duplication ---"
# Must say "replace" or "overwrite" body when header already exists — not just skip/skip-if-present
if grep -qiE 'replace.*body|overwrite.*section|replace.*section.*body|body.*replace|section.*replace' "$SKILL_FILE"; then
    pass "SKILL.md documents body-replace when ## Copy Needs header already exists"
else
    fail "SKILL.md does not document replace-body behaviour for existing ## Copy Needs header"
fi

echo ""
echo "--- Test 4: Idempotency language is explicit (not just 'do not append a second section') ---"
# The skill must describe the in-place update/replace pattern with enough detail
# so the agent replaces the existing section body rather than leaving the section unchanged.
if grep -qE 'in-place update|replace.*existing.*section|existing section.*replace|rewrite.*section|section.*rewrite' "$SKILL_FILE"; then
    pass "SKILL.md uses explicit in-place-update / replace language for idempotency"
else
    fail "SKILL.md idempotency description lacks explicit replace/rewrite language"
fi

echo ""
echo "--- Test 5: schema_version: 1 is at the top of the ## Copy Needs section block ---"
# The schema_version line must appear as the first content line under ## Copy Needs,
# not buried later. Check that schema_version appears near (within 5 lines of) ## Copy Needs.
_SECTION_LINE=$(grep -n '^## Copy Needs' "$SKILL_FILE" | head -1 | cut -d: -f1)
if [[ -z "$_SECTION_LINE" ]]; then
    # Not a standalone section — check the code block definition
    _SECTION_LINE=$(grep -n '"## Copy Needs' "$SKILL_FILE" | head -1 | cut -d: -f1)
fi
if [[ -n "$_SECTION_LINE" ]]; then
    # Check if schema_version: 1 appears within 10 lines of the ## Copy Needs occurrence
    _WINDOW_END=$((_SECTION_LINE + 10))
    if sed -n "${_SECTION_LINE},${_WINDOW_END}p" "$SKILL_FILE" | grep -q 'schema_version: 1'; then
        pass "schema_version: 1 appears within 10 lines of ## Copy Needs heading"
    else
        fail "schema_version: 1 does not appear near ## Copy Needs heading (should be first content line)"
    fi
else
    fail "## Copy Needs heading not found in SKILL.md (required for schema_version placement check)"
fi

echo ""
echo "--- Test 6: Tag write (Step 4a) is documented as separate from section write (Step 4c) ---"
# Step 4a and Step 4c must both appear in the file to prove they are distinct steps
if grep -q 'Step 4a' "$SKILL_FILE" && grep -q 'Step 4c' "$SKILL_FILE"; then
    pass "SKILL.md documents Step 4a (tag write) and Step 4c (section write) as separate steps"
else
    fail "SKILL.md does not show Step 4a and Step 4c as separate steps (tag vs. section write)"
fi

echo ""
echo "--- Test 7: python3 (or equivalent) is used to extract description before append ---"
if grep -qE 'python3.*description|python3.*stdin|python.*description' "$SKILL_FILE"; then
    pass "SKILL.md uses python3 to extract the current description before appending"
else
    fail "SKILL.md does not document python3 extraction of current description"
fi

echo ""
echo "--- Test 8: stable_id-based deduplication described for re-runs ---"
# When brainstorm re-runs on an epic with an existing Copy Needs section,
# new items must be merged by stable_id — not blindly appended or cleared.
# Accept any phrasing that links stable_id to dedup/merge/presence check.
if grep -qE 'stable_id.*dedup|dedup.*stable_id|stable_id.*not.*appear|not.*present.*stable_id|stable_id.*not.*present|already.*stable_id|stable_id.*already|by.*stable_id|stable_id.*based|identified.*stable_id|stable_id.*identified' "$SKILL_FILE"; then
    pass "SKILL.md describes stable_id-based deduplication for re-run merges"
else
    fail "SKILL.md does not describe stable_id-based deduplication for re-run merges"
fi

echo ""
echo "--- Test 9: Description assembled into variable before ticket edit call ---"
# The skill must show the pattern: build _NEW_DESC (or equivalent) then pass to ticket edit
if grep -qE '_NEW_DESC|new_desc|NEW_DESC|assembled.*description|description.*assembled' "$SKILL_FILE"; then
    pass "SKILL.md shows description assembled into a variable before ticket edit"
else
    fail "SKILL.md does not show description assembly pattern before ticket edit"
fi

echo ""
echo "--- Test 10: No --append-section flag used as valid command (negative assertion) ---"
# ticket edit does NOT have --append-section; if the skill were to present it as a
# valid command (e.g., '.claude/scripts/dso ticket edit ... --append-section'), that
# would be incorrect. The flag may appear in prose saying it does NOT exist — that is correct.
# We check that the CLI invocation pattern does NOT use --append-section positively.
if grep -qE '^\s*\.claude/scripts/dso ticket edit.*--append-section' "$SKILL_FILE"; then
    fail "SKILL.md has a CLI invocation using --append-section which does not exist"
else
    pass "SKILL.md does not invoke ticket edit with non-existent --append-section flag (correct)"
fi

# ---------------------------------------------------------------------------
# Test idempotent re-run: validate the idempotency contract in the contract file
# ---------------------------------------------------------------------------
echo ""
echo "--- Test 11: Contract file documents idempotency requirements ---"
if grep -qi 'idempoten\|stable_id.*unique\|unique.*stable_id' "$CONTRACT_FILE"; then
    pass "copy-needs-section.md documents idempotency / stable_id uniqueness"
else
    fail "copy-needs-section.md does not document idempotency / stable_id uniqueness requirements"
fi

echo ""
echo "--- Test 12: Contract file schema_version at top of section structure ---"
# The contract should show schema_version as the first field in the section structure
_CONTRACT_SV_LINE=$(grep -n 'schema_version' "$CONTRACT_FILE" | head -1 | cut -d: -f1)
_CONTRACT_ITEMS_LINE=$(grep -n 'stable_id\|items:\|- stable_id' "$CONTRACT_FILE" | head -1 | cut -d: -f1)
if [[ -n "$_CONTRACT_SV_LINE" && -n "$_CONTRACT_ITEMS_LINE" ]]; then
    if (( _CONTRACT_SV_LINE < _CONTRACT_ITEMS_LINE )); then
        pass "Contract file places schema_version before item definitions (top-of-section)"
    else
        fail "Contract file places schema_version AFTER item definitions (should be first)"
    fi
else
    fail "Contract file missing schema_version or item definitions — cannot check ordering"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "FAILED: $FAIL test(s) failed."
    exit 1
fi
