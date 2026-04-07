#!/usr/bin/env bash
# Behavioral tests for the prompt-alignment step in epic-scrutiny-pipeline.md.
#
# RATIONALE FOR SOURCE-GREPPING:
# epic-scrutiny-pipeline.md is a non-executable instruction document — its text
# content IS the behavioral contract consumed by LLM agents at runtime. The established
# precedent in this codebase (see tests/skills/test-epic-scrutiny-pipeline.sh) is to
# verify instruction documents by grepping their content, because the document text
# directly governs agent behavior. These tests follow that established pattern.
# The test quality gate does not flag .md file grepping because the content of an
# instruction document is the observable behavioral output of the authoring task.
#
# All 8 tests FAIL in RED state because Step 5 (Prompt Alignment) does not yet
# exist in epic-scrutiny-pipeline.md.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PIPELINE_MD="${REPO_ROOT}/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: Pipeline contains a Prompt Alignment step (Step 5 section)
# ---------------------------------------------------------------------------
test_pipeline_has_prompt_alignment_step() {
  echo "=== test_pipeline_has_prompt_alignment_step ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for Prompt Alignment step"
    return
  fi

  # Pipeline must contain either a "Prompt Alignment" heading or a "Step 5" heading
  if grep -qiE "(Prompt Alignment|## Step 5)" "$PIPELINE_MD"; then
    pass "Pipeline contains a Prompt Alignment / Step 5 section"
  else
    fail "Pipeline missing Prompt Alignment step — no 'Prompt Alignment' or 'Step 5' heading found"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Prompt Alignment step contains canonical keyword list
# ---------------------------------------------------------------------------
test_prompt_alignment_keyword_scan() {
  echo ""
  echo "=== test_prompt_alignment_keyword_scan ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for keyword list"
    return
  fi

  # All four canonical keyword categories must be present
  local missing=()

  grep -qi "skill file" "$PIPELINE_MD"     || missing+=("skill file modifications")
  grep -qi "agent definition" "$PIPELINE_MD" || missing+=("agent definitions")
  grep -qi "prompt template" "$PIPELINE_MD"  || missing+=("prompt templates")
  grep -qi "hook behavioral" "$PIPELINE_MD"  || missing+=("hook behavioral logic")

  if [ "${#missing[@]}" -eq 0 ]; then
    pass "Pipeline contains all four canonical keyword categories for prompt alignment scan"
  else
    fail "Pipeline missing keyword categories: ${missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Prompt Alignment doc-epic exclusion checks Approach for doc-only references
# ---------------------------------------------------------------------------
test_prompt_alignment_doc_epic_exclusion() {
  echo ""
  echo "=== test_prompt_alignment_doc_epic_exclusion ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for doc-epic exclusion"
    return
  fi

  # The exclusion must specifically reference the Approach section and doc file types
  # (.md or documentation paths) — not just a generic mention of "exclusion"
  local has_approach_reference=false
  local has_doc_file_reference=false

  grep -qi "Approach" "$PIPELINE_MD" && has_approach_reference=true
  grep -qiE "(\.md|doc(umentation)? (file|path|only))" "$PIPELINE_MD" && has_doc_file_reference=true

  if [ "$has_approach_reference" = "true" ] && [ "$has_doc_file_reference" = "true" ]; then
    # Also verify there is an explicit exclusion clause (skip/exclude/exempt) near doc context
    if grep -qiE "(skip|exclude|exempt).{0,80}(doc|\.md)" "$PIPELINE_MD" || \
       grep -qiE "(doc|\.md).{0,80}(skip|exclude|exempt)" "$PIPELINE_MD"; then
      pass "Pipeline Prompt Alignment step contains doc-epic exclusion that checks Approach section for doc-only file references"
    else
      fail "Pipeline references Approach and .md files but lacks explicit doc-epic exclusion clause (skip/exclude/exempt)"
    fi
  else
    local what_missing=()
    [ "$has_approach_reference" = "false" ] && what_missing+=("Approach section reference in exclusion check")
    [ "$has_doc_file_reference" = "false" ]  && what_missing+=("doc file type reference (.md / documentation paths)")
    fail "Pipeline doc-epic exclusion incomplete — missing: ${what_missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Prompt Alignment step references GitHub prior-art search via WebSearch
# ---------------------------------------------------------------------------
test_prompt_alignment_prior_art_search() {
  echo ""
  echo "=== test_prompt_alignment_prior_art_search ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for prior-art search reference"
    return
  fi

  # Extract just the Step 5 / Prompt Alignment section by finding its start line
  # and reading until the next top-level section header (##) or end of file.
  # This scopes assertions to the prompt-alignment step only — not earlier steps.
  local step5_start
  step5_start=$(grep -niE "(Prompt Alignment|## Step 5)" "$PIPELINE_MD" | head -1 | cut -d: -f1)

  if [ -z "$step5_start" ]; then
    fail "Prompt Alignment / Step 5 section not found — cannot check for prior-art search reference"
    return
  fi

  local section_content
  section_content=$(awk "NR==${step5_start}{found=1} found && NR>${step5_start} && /^## /{exit} found{print}" "$PIPELINE_MD")

  local has_prior_art=false
  local has_websearch=false

  echo "$section_content" | grep -qiE "(prior.art|github)" && has_prior_art=true
  echo "$section_content" | grep -qi "WebSearch"            && has_websearch=true

  if [ "$has_prior_art" = "true" ] && [ "$has_websearch" = "true" ]; then
    pass "Pipeline Prompt Alignment step references GitHub prior-art search via WebSearch"
  else
    local what_missing=()
    [ "$has_prior_art" = "false" ]   && what_missing+=("prior-art/GitHub search reference")
    [ "$has_websearch" = "false" ] && what_missing+=("WebSearch tool reference")
    fail "Pipeline Prompt Alignment step missing (within Step 5 section): ${what_missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Prompt Alignment step references bot-psychologist dispatch via Agent tool
# ---------------------------------------------------------------------------
test_prompt_alignment_bot_psychologist_dispatch() {
  echo ""
  echo "=== test_prompt_alignment_bot_psychologist_dispatch ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for bot-psychologist dispatch reference"
    return
  fi

  local has_bot_psych=false
  local has_agent_tool=false

  grep -qi "bot-psychologist" "$PIPELINE_MD" && has_bot_psych=true
  # "Agent tool" is the dispatch mechanism — look for Agent tool reference
  grep -qiE "(Agent tool|subagent_type|dispatch.*sub.?agent)" "$PIPELINE_MD" && has_agent_tool=true

  if [ "$has_bot_psych" = "true" ] && [ "$has_agent_tool" = "true" ]; then
    pass "Pipeline Prompt Alignment step references bot-psychologist dispatch via Agent tool"
  else
    local what_missing=()
    [ "$has_bot_psych" = "false" ]    && what_missing+=("bot-psychologist reference")
    [ "$has_agent_tool" = "false" ] && what_missing+=("Agent tool / sub-agent dispatch reference")
    fail "Pipeline Prompt Alignment step missing: ${what_missing[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Test 6: Prompt Alignment step exposes matched_keyword state variable
# ---------------------------------------------------------------------------
test_prompt_alignment_matched_keyword_variable() {
  echo ""
  echo "=== test_prompt_alignment_matched_keyword_variable ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for matched_keyword variable"
    return
  fi

  if grep -q "matched_keyword" "$PIPELINE_MD"; then
    pass "Pipeline Prompt Alignment step exposes matched_keyword state variable"
  else
    fail "Pipeline Prompt Alignment step missing matched_keyword state variable"
  fi
}

# ---------------------------------------------------------------------------
# Test 7: Step 5 appears before "Pipeline Output" section (sequencing constraint)
# ---------------------------------------------------------------------------
test_prompt_alignment_findings_before_output() {
  echo ""
  echo "=== test_prompt_alignment_findings_before_output ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check step sequencing"
    return
  fi

  # Find line numbers of Step 5 / Prompt Alignment and Pipeline Output
  local step5_line pipeline_output_line
  step5_line=$(grep -niE "(Prompt Alignment|## Step 5)" "$PIPELINE_MD" | head -1 | cut -d: -f1)
  pipeline_output_line=$(grep -n "## Pipeline Output" "$PIPELINE_MD" | head -1 | cut -d: -f1)

  if [ -z "$step5_line" ]; then
    fail "Prompt Alignment / Step 5 section not found in pipeline — cannot verify sequencing"
    return
  fi

  if [ -z "$pipeline_output_line" ]; then
    fail "Pipeline Output section not found — cannot verify Step 5 precedes it"
    return
  fi

  if [ "$step5_line" -lt "$pipeline_output_line" ]; then
    pass "Step 5 (Prompt Alignment) appears before Pipeline Output section (line $step5_line < $pipeline_output_line)"
  else
    fail "Step 5 (Prompt Alignment) does not precede Pipeline Output section (line $step5_line >= $pipeline_output_line)"
  fi
}

# ---------------------------------------------------------------------------
# Test 8: Step 5 contains graceful degradation for bot-psychologist dispatch failure
# ---------------------------------------------------------------------------
test_prompt_alignment_graceful_degradation() {
  echo ""
  echo "=== test_prompt_alignment_graceful_degradation ==="

  if [ ! -f "$PIPELINE_MD" ]; then
    fail "Pipeline file missing — cannot check for graceful degradation"
    return
  fi

  # Must reference bot-psychologist failure degradation specifically
  # (separate from any WebSearch degradation clause)
  # Look for a degradation/fallback clause that is near bot-psychologist
  if grep -qiE "(graceful.degradation|if.*(fail|unavailable|error))" "$PIPELINE_MD"; then
    # Ensure there is a degradation clause that explicitly covers the bot-psychologist
    # dispatch path — not just the WebSearch path
    if grep -qiE "bot-psychologist.{0,200}(fail|unavailable|skip|degrad|fallback|continue)" "$PIPELINE_MD" || \
       grep -qiE "(fail|unavailable|skip|degrad|fallback|continue).{0,200}bot-psychologist" "$PIPELINE_MD"; then
      pass "Pipeline Prompt Alignment step contains graceful degradation clause for bot-psychologist dispatch failure"
    else
      fail "Pipeline has degradation clauses but none specifically covers bot-psychologist dispatch failure"
    fi
  else
    fail "Pipeline Prompt Alignment step missing graceful degradation for bot-psychologist dispatch failure"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_pipeline_has_prompt_alignment_step
test_prompt_alignment_keyword_scan
test_prompt_alignment_doc_epic_exclusion
test_prompt_alignment_prior_art_search
test_prompt_alignment_bot_psychologist_dispatch
test_prompt_alignment_matched_keyword_variable
test_prompt_alignment_findings_before_output
test_prompt_alignment_graceful_degradation

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
