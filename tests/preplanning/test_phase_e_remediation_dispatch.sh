#!/usr/bin/env bash
# RED test for task 3e49-9093-a8ce-4546 (story b345-913f-29d7-4ee9).
#
# Validates that the Phase E adversarial-review dispatcher prompt
# (skills/preplanning/prompts/phase-e-adversarial-review.md under the plugin root)
# carries a conditional remediation re-dispatch block that:
#   (dd-1) dispatches dso:story-decomposer with a LITERAL `model: "opus"` field
#   (dd-2) passes a by-reference payload (target_story_ids + absolute artifact paths,
#          NOT embedded finding bodies)
#   (dd-3) instructs the producer to operate in DELTA OUTPUT mode + quote evidence
#          (scoped to dispatch-block INSTRUCTIONS — not the producer's runtime output)
#   (dd-4) preserves a null-case guard that explicitly SKIPS re-dispatch when
#          blue_team_accepted.findings is empty
#
# Plus AC amendments:
#   #1 — re-dispatch goes BETWEEN Step 3 and Step 4 (or Step 4 artifact write
#        precedes the dispatch — checked by line-number ordering)
#   #2 — fixture schema mirrors Step-4 exchange artifact
#   #4 — forward-references docs/contracts/remediation-context-payload.md under
#        the plugin root (do NOT inline the spec)
#   #5 — places <!-- TOUCHPOINT-EMBEDDING-ANCHOR: phase-e-remediation-loop --> for
#        sibling story 590a
#   #6 — Option A pin: re-dispatch REPLACES Step 3 (transcription anti-pattern is
#        eliminated)
#   #7 — preserves BOTH null branches (existing red_team-zero PRE-filter skip AND
#        new blue_team_accepted POST-filter skip)
#
# Rule 5 (behavioral-testing-standard.md): prompts are non-executable; this test
# asserts structural contracts on the prompt text + JSON fixture shapes.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve the plugin root from the worktree's own git toplevel rather than
# $CLAUDE_PLUGIN_ROOT. The harness exports CLAUDE_PLUGIN_ROOT pointing at the
# main repo, but in a worktree-isolated context we MUST test the prompt file
# under THIS worktree's plugin source, not the main-repo copy. Allow explicit
# override via the test-only env var DSO_PHASE_E_PROMPT_OVERRIDE.
_PLUGIN_ROOT="$(git -C "$_SCRIPT_DIR" rev-parse --show-toplevel)/plugins/dso"
PHASE_E="${DSO_PHASE_E_PROMPT_OVERRIDE:-$_PLUGIN_ROOT/skills/preplanning/prompts/phase-e-adversarial-review.md}"
FIXTURE_DIR="$_SCRIPT_DIR/fixtures/phase-e"
SYNTH="$FIXTURE_DIR/synthetic-findings.json"
EMPTY="$FIXTURE_DIR/empty-findings.json"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Fixture presence + schema (AC amendment #2) ==="
if [[ -f "$SYNTH" ]]; then
  pass "synthetic-findings.json fixture exists"
else
  fail "synthetic-findings.json fixture missing at $SYNTH"
fi
if [[ -f "$EMPTY" ]]; then
  pass "empty-findings.json fixture exists"
else
  fail "empty-findings.json fixture missing at $EMPTY"
fi

# synthetic fixture must mirror Step-4 exchange-artifact shape: top-level keys
# sc_coverage_summary, red_team_findings, blue_team_accepted, blue_team_rejected
# with blue_team_accepted.findings as the gate-under-test (non-empty).
for key in sc_coverage_summary red_team_findings blue_team_accepted blue_team_rejected; do
  if jq -e --arg k "$key" 'has($k)' "$SYNTH" >/dev/null 2>&1; then
    pass "synthetic fixture has top-level key '$key' (Step-4 shape)"
  else
    fail "synthetic fixture missing top-level key '$key' (Step-4 shape)"
  fi
done

if jq -e '.blue_team_accepted.findings | length > 0' "$SYNTH" >/dev/null 2>&1; then
  pass "synthetic.blue_team_accepted.findings is non-empty (re-dispatch gate)"
else
  fail "synthetic.blue_team_accepted.findings is empty — re-dispatch gate cannot fire"
fi

if jq -e '.blue_team_accepted.findings == []' "$EMPTY" >/dev/null 2>&1; then
  pass "empty.blue_team_accepted.findings == [] (null-case guard input)"
else
  fail "empty.blue_team_accepted.findings != [] (null-case guard input)"
fi

# Every accepted finding must carry a target_story_id (the by-reference identifier
# the dispatch payload extracts via jq).
if jq -e 'all(.blue_team_accepted.findings[]; has("target_story_id") and .target_story_id != null)' "$SYNTH" >/dev/null 2>&1; then
  pass "every accepted finding declares target_story_id (by-reference input)"
else
  fail "at least one accepted finding lacks target_story_id"
fi

echo ""
echo "=== Phase E prompt exists ==="
if [[ -f "$PHASE_E" ]]; then
  pass "phase-e-adversarial-review.md exists"
else
  fail "phase-e-adversarial-review.md missing at $PHASE_E"
  echo "Cannot proceed without prompt file."
  echo "Passed: $PASS"
  echo "Failed: $FAIL"
  exit 1
fi

echo ""
echo "=== dd-1: literal model: \"opus\" appears on a story-decomposer dispatch line ==="
# Scope check to a "Remediation Re-Dispatch" / "remediation_context" block so
# pre-existing red-team opus mentions don't yield false positives.
remediation_section=$(awk '
  /TOUCHPOINT-EMBEDDING-ANCHOR: phase-e-remediation-loop/ { in_section = 1 }
  in_section && /^## / && !/Remediation/ { exit }
  in_section { print }
' "$PHASE_E")

if [[ -n "$remediation_section" ]]; then
  pass "remediation-loop section identifiable (anchored on TOUCHPOINT-EMBEDDING-ANCHOR)"
else
  fail "no remediation-loop section found — anchor on '<!-- TOUCHPOINT-EMBEDDING-ANCHOR: phase-e-remediation-loop -->' missing"
fi

if echo "$remediation_section" | grep -qE 'subagent_type:[[:space:]]*"?dso:story-decomposer"?'; then
  pass "remediation section dispatches dso:story-decomposer"
else
  fail "remediation section does not dispatch dso:story-decomposer (subagent_type)"
fi

if echo "$remediation_section" | grep -qE 'model:[[:space:]]*"opus"'; then
  pass "dd-1: remediation section carries literal model: \"opus\" token"
else
  fail "dd-1: remediation section is missing the literal model: \"opus\" token"
fi

echo ""
echo "=== dd-2: by-reference payload (target_story_ids + absolute paths, no embedded bodies) ==="
if echo "$remediation_section" | grep -q 'target_story_ids'; then
  pass "dd-2: remediation section references target_story_ids"
else
  fail "dd-2: remediation section does NOT reference target_story_ids"
fi

# By-reference shape: must reference an artifact path variable / absolute path
# (e.g. ARTIFACT_PATH or the literal 'absolute' qualifier).
if echo "$remediation_section" | grep -qiE 'ARTIFACT_PATH|absolute[[:space:]]+(file[[:space:]]+)?path'; then
  pass "dd-2: remediation section references absolute artifact path"
else
  fail "dd-2: remediation section does not reference absolute artifact path (ARTIFACT_PATH or 'absolute path')"
fi

# Negative assertion: the dispatch payload must NOT embed finding bodies. We
# detect "embed" / "embedded finding" prose-style references and inverted-
# instruction phrasings. The intended language is by-reference only.
if echo "$remediation_section" | grep -qiE 'embed(ded)?[[:space:]]+finding[[:space:]]+bod(y|ies)|embed[[:space:]]+finding'; then
  # Allow language that explicitly states the negative ("not embed finding
  # bodies" / "do NOT embed finding bodies").
  if echo "$remediation_section" | grep -qiE 'NOT[[:space:]]+embed|do[[:space:]]+not[[:space:]]+embed|never[[:space:]]+embed'; then
    pass "dd-2: remediation section explicitly forbids embedded finding bodies"
  else
    fail "dd-2: remediation section appears to embed finding bodies (no explicit NOT/never qualifier nearby)"
  fi
else
  pass "dd-2: remediation section does not mention embedded finding bodies (by-reference only)"
fi

echo ""
echo "=== dd-3: DELTA OUTPUT mode declaration + evidence-quote instruction (dispatch-block scope only) ==="
# Amendment #3: scope to dispatch-block INSTRUCTIONS, not producer output. The
# remediation_section grep is already scoped to the new dispatch block.
if echo "$remediation_section" | grep -qE 'DELTA[[:space:]]+OUTPUT'; then
  pass "dd-3: dispatch block instructs DELTA OUTPUT mode"
else
  fail "dd-3: dispatch block does not declare DELTA OUTPUT mode"
fi

if echo "$remediation_section" | grep -qiE 'evidence[[:space:]]+(quote|quotation)|quote[[:space:]]+evidence'; then
  pass "dd-3: dispatch block instructs evidence-quote requirement"
else
  fail "dd-3: dispatch block does not instruct evidence-quote requirement"
fi

echo ""
echo "=== dd-4: null-case guard on blue_team_accepted.findings empty ==="
if grep -qE 'blue_team_accepted\.findings' "$PHASE_E"; then
  pass "dd-4: prompt references blue_team_accepted.findings gate variable"
else
  fail "dd-4: prompt does not reference blue_team_accepted.findings"
fi

if grep -qiE 'blue_team_accepted\.findings.*(empty|zero|null|\\[\\])|empty.*blue_team_accepted|blue.team.accepted.*empty' "$PHASE_E"; then
  pass "dd-4: prompt declares the blue_team_accepted-empty branch"
else
  fail "dd-4: prompt does not declare the blue_team_accepted-empty branch"
fi

if grep -qiE 'skip|do[[:space:]]+not[[:space:]]+(re-)?dispatch|null[- ]case' "$PHASE_E"; then
  pass "dd-4: prompt declares a skip / do-not-re-dispatch instruction"
else
  fail "dd-4: prompt has no skip / do-not-re-dispatch instruction"
fi

echo ""
echo "=== AC amendment #1: ordering — re-dispatch is between Step 3 and Step 4 OR after Step 4 artifact write ==="
step3_line=$(grep -nE '^## Step 3:' "$PHASE_E" | head -1 | cut -d: -f1 || true)
step4_line=$(grep -nE '^## Step 4:' "$PHASE_E" | head -1 | cut -d: -f1 || true)
artifact_write_line=$(grep -nE 'ARTIFACT_PATH=' "$PHASE_E" | head -1 | cut -d: -f1 || true)
anchor_line=$(grep -nE 'TOUCHPOINT-EMBEDDING-ANCHOR: phase-e-remediation-loop' "$PHASE_E" | head -1 | cut -d: -f1 || true)

if [[ -n "$anchor_line" && -n "$step4_line" && -n "$artifact_write_line" ]]; then
  if (( anchor_line > artifact_write_line )); then
    pass "ordering OK: ARTIFACT_PATH write (line $artifact_write_line) precedes remediation anchor (line $anchor_line)"
  elif [[ -n "$step3_line" ]] && (( anchor_line > step3_line && anchor_line < step4_line )); then
    pass "ordering OK: remediation anchor (line $anchor_line) sits between Step 3 (line $step3_line) and Step 4 (line $step4_line)"
  else
    fail "ordering BAD: anchor=$anchor_line, step3=$step3_line, step4=$step4_line, artifact_write=$artifact_write_line — re-dispatch must be either after the ARTIFACT_PATH write OR between Step 3 and Step 4"
  fi
else
  fail "could not locate one of: anchor=$anchor_line, step4=$step4_line, artifact_write=$artifact_write_line"
fi

echo ""
echo "=== AC amendment #4: forward-reference remediation-context-payload.md (do NOT inline the spec) ==="
if grep -q 'remediation-context-payload' "$PHASE_E"; then
  pass "amendment #4: prompt references remediation-context-payload.md"
else
  fail "amendment #4: prompt does not reference remediation-context-payload.md"
fi

echo ""
echo "=== AC amendment #5: TOUCHPOINT-EMBEDDING-ANCHOR for sibling story 590a ==="
if grep -q 'TOUCHPOINT-EMBEDDING-ANCHOR: phase-e-remediation-loop' "$PHASE_E"; then
  pass "amendment #5: TOUCHPOINT-EMBEDDING-ANCHOR present"
else
  fail "amendment #5: TOUCHPOINT-EMBEDDING-ANCHOR missing"
fi

echo ""
echo "=== AC amendment #6: Option A pin — re-dispatch REPLACES Step 3 ==="
if grep -qE 'replaces Step 3|in lieu of Step 3|Step 3.*deprecated|Step 3.*superseded' "$PHASE_E"; then
  pass "amendment #6: prompt pins Option A (re-dispatch replaces Step 3)"
else
  fail "amendment #6: prompt does not pin Option A (Step 3 replacement language missing)"
fi

echo ""
echo "=== AC amendment #7: BOTH null-case branches preserved ==="
# Branch (a): existing PRE-filter red-team-zero skip MUST remain.
if grep -q 'Red team found no cross-story gaps' "$PHASE_E"; then
  pass "amendment #7 (a): existing PRE-filter red-team-zero skip preserved"
else
  fail "amendment #7 (a): existing PRE-filter red-team-zero skip removed — must remain intact"
fi

# Branch (b): new POST-filter blue_team_accepted-empty skip.
if grep -qiE 'blue_team_accepted\.findings.*(empty|zero|null)|empty.*blue_team_accepted' "$PHASE_E"; then
  pass "amendment #7 (b): new POST-filter blue_team_accepted-empty branch present"
else
  fail "amendment #7 (b): new POST-filter blue_team_accepted-empty branch missing"
fi

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
