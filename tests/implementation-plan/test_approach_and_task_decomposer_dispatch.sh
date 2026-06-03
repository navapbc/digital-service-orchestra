#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/dso}"
# Structural validation for /dso:implementation-plan Step 1 (approach proposer)
# and Step 3 (task decomposer) dispatch wiring, plus the augmented Completeness
# reviewer's new dd_collective_ac_coverage dimension.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="${_PLUGIN_ROOT}/skills/implementation-plan"
SKILL_MD="$SKILL_DIR/SKILL.md"
COMPLETENESS="$SKILL_DIR/docs/reviewers/plan/completeness.md"
APPROACH_PROPOSER_AGENT="${_PLUGIN_ROOT}/agents/approach-proposer.md"
TASK_DECOMPOSER_AGENT="${_PLUGIN_ROOT}/agents/task-decomposer.md"
PLUGIN_JSON="${_PLUGIN_ROOT}/.claude-plugin/plugin.json"
AGENTS_MD="${_PLUGIN_ROOT}/docs/AGENTS.md"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract a section from SKILL.md bounded by the next "## " heading.
extract_section() {
  local heading_re="$1"
  awk -v re="$heading_re" '
    $0 ~ re { in_section = 1; print; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$SKILL_MD"
}

# ---------- Agent files exist and declare opus ----------
echo "=== Agent files exist and declare model: opus ==="
for agent_pair in "approach-proposer:$APPROACH_PROPOSER_AGENT" "task-decomposer:$TASK_DECOMPOSER_AGENT"; do
  name="${agent_pair%%:*}"
  path="${agent_pair##*:}"
  if [[ -f "$path" ]]; then
    pass "$name agent file exists"
  else
    fail "$name agent file missing: $path"
    continue
  fi
  if grep -E '^model:\s*opus\b' "$path" >/dev/null; then
    pass "$name agent frontmatter declares model: opus"
  else
    fail "$name agent frontmatter does not declare model: opus"
  fi
  if grep -q 'model_requirement_unmet' "$path"; then
    pass "$name agent declares model_requirement_unmet self-guard"
  else
    fail "$name agent missing model_requirement_unmet self-guard"
  fi
done

# ---------- approach-proposer schema ----------
echo
echo "=== approach-proposer output schema ==="
for field in proposals distinctness_summary complexity_gate_summary generation_notes; do
  if grep -q "\"$field\"" "$APPROACH_PROPOSER_AGENT"; then
    pass "approach-proposer output declares '$field' top-level key"
  else
    fail "approach-proposer output missing '$field' top-level key"
  fi
done
# Distinctness gate must list all four structural axes
for axis in data_layer control_flow dependency_graph interface_boundary; do
  if grep -q "$axis" "$APPROACH_PROPOSER_AGENT"; then
    pass "approach-proposer references structural axis '$axis'"
  else
    fail "approach-proposer missing structural axis '$axis'"
  fi
done
# Complexity gates 1/2/3
for gate in gate_1_yagni gate_2_rule_of_three gate_3_new_dependency; do
  if grep -q "$gate" "$APPROACH_PROPOSER_AGENT"; then
    pass "approach-proposer records complexity gate outcome '$gate'"
  else
    fail "approach-proposer missing complexity gate outcome '$gate'"
  fi
done

# Both agents must explicitly distinguish success-response keys from error-envelope
# keys. Without this disambiguation, an `error` field in the envelope contradicts
# the "exactly these top-level keys" rule and risks the agent omitting `error`
# entirely (breaking SKILL.md's validation routing).
for agent_pair in "approach-proposer:$APPROACH_PROPOSER_AGENT" "task-decomposer:$TASK_DECOMPOSER_AGENT"; do
  name="${agent_pair%%:*}"
  path="${agent_pair##*:}"
  if grep -qi 'Success Response' "$path" && grep -qi 'Error Envelope' "$path"; then
    pass "$name distinguishes Success Response from Error Envelope sections"
  else
    fail "$name does not distinguish Success Response from Error Envelope (contradictory 'exactly these top-level keys' contract risks dropped error fields)"
  fi
done

# ---------- task-decomposer schema ----------
echo
echo "=== task-decomposer output schema ==="
for field in dd_partition_map task_drafts decomposition_notes; do
  if grep -q "\"$field\"" "$TASK_DECOMPOSER_AGENT"; then
    pass "task-decomposer output declares '$field' top-level key"
  else
    fail "task-decomposer output missing '$field' top-level key"
  fi
done
# Per-task required fields (sample the critical ones)
for tfield in temp_id title testing_mode story_dd_coverage tdd_test_spec file_impact acceptance_criteria depends_on retry_budget; do
  if grep -q "$tfield" "$TASK_DECOMPOSER_AGENT"; then
    pass "task-decomposer task_drafts entry includes '$tfield'"
  else
    fail "task-decomposer task_drafts entry missing '$tfield'"
  fi
done
# Universal AC rule and DD partition
if grep -q "Universal Criteria" "$TASK_DECOMPOSER_AGENT"; then
  pass "task-decomposer enforces Universal Criteria rule"
else
  fail "task-decomposer missing Universal Criteria rule"
fi
if grep -q "Retry Budget" "$TASK_DECOMPOSER_AGENT"; then
  pass "task-decomposer enforces Retry Budget block"
else
  fail "task-decomposer missing Retry Budget block"
fi
if grep -q "exactly one" "$TASK_DECOMPOSER_AGENT"; then
  pass "task-decomposer enforces DD partition disjointness"
else
  fail "task-decomposer missing DD partition disjointness rule"
fi
# The agent's example descriptions MUST embed a `## Story DD Coverage` section
# verbatim — the completeness reviewer's dd_collective_ac_coverage audit builds
# its DD-to-task map by scanning for this exact heading. An example without the
# section silently teaches the agent to omit it, breaking the audit downstream.
if grep -q '## Story DD Coverage' "$TASK_DECOMPOSER_AGENT"; then
  pass "task-decomposer example descriptions embed '## Story DD Coverage' section header"
else
  fail "task-decomposer example descriptions do not embed '## Story DD Coverage' — completeness reviewer's audit will find no owning tasks"
fi
# The header must be elevated to a hard schema requirement in the Rules section
# so models reading the bottom of the file (rather than copy-pasting the example)
# still pick up the obligation. Extract from "## Rules" to EOF (the Rules section
# is the final section in the agent file).
if awk '/^## Rules/{found=1} found' "$TASK_DECOMPOSER_AGENT" | grep -q 'Story DD Coverage'; then
  pass "task-decomposer Rules section enforces '## Story DD Coverage' header"
else
  fail "task-decomposer Rules section does not enforce '## Story DD Coverage' header (only examples include it)"
fi
# Universal Criteria in the example must use the guarded shell form that
# matches the SKILL.md Step 5 Task Creation template.
if grep -q 'TEST_CMD=\$(.claude/scripts/dso read-config commands.test_unit)' "$TASK_DECOMPOSER_AGENT"; then
  pass "task-decomposer example uses guarded Universal Criteria form (TEST_CMD=\$(...))"
else
  fail "task-decomposer example diverges from SKILL.md Step 5 Universal Criteria template (missing TEST_CMD=\$(...) guarded form)"
fi

# ---------- SKILL.md Step 1 dispatch wiring ----------
echo
echo "=== SKILL.md Step 1 Proposal Generation dispatch wiring ==="
step1=$(extract_section "^### Proposal Generation")
if echo "$step1" | grep -E 'subagent_type:\s*"?dso:approach-proposer"?[^\n]*model:\s*"opus"' >/dev/null; then
  pass "Step 1 dispatches dso:approach-proposer with explicit model: \"opus\" on the same line"
else
  fail "Step 1 does not dispatch dso:approach-proposer with explicit model: \"opus\" (frontmatter default is insufficient)"
fi
# Halt-on-failure language (correctness gate)
if echo "$step1" | grep -qi 'HALT'; then
  pass "Step 1 halts on validation failure"
else
  fail "Step 1 does not halt on validation failure"
fi
# Validation ordering anchors — three structural markers (1 → 1.5 → 2).
# VALIDATION-STEP-1.5 carves out the domain-error escalation path
# (insufficient_solution_space / decomposition_blocked) so legitimate
# constrained-input responses are not misclassified as malformed output.
mru_line=$(echo "$step1" | grep -nE 'VALIDATION-STEP-1:[[:space:]]*model_requirement_unmet' | head -1 | cut -d: -f1)
domain_line=$(echo "$step1" | grep -nE 'VALIDATION-STEP-1\.5:[[:space:]]*domain-error-escalation' | head -1 | cut -d: -f1)
schema_line=$(echo "$step1" | grep -nE 'VALIDATION-STEP-2:[[:space:]]*schema-validation' | head -1 | cut -d: -f1)
if [[ -n "$mru_line" && -n "$domain_line" && -n "$schema_line" ]] && (( mru_line < domain_line && domain_line < schema_line )); then
  pass "Step 1 validation order: STEP-1 < STEP-1.5 < STEP-2 (lines $mru_line < $domain_line < $schema_line)"
else
  fail "Step 1 validation ordering wrong or markers missing (mru=$mru_line domain=$domain_line schema=$schema_line)"
fi
# Step 1 must reference insufficient_solution_space by name so the wiring is documented.
if echo "$step1" | grep -q 'insufficient_solution_space'; then
  pass "Step 1 names 'insufficient_solution_space' error envelope"
else
  fail "Step 1 does not reference 'insufficient_solution_space' (the domain-error escalation path is undocumented)"
fi
# No inline-drafting fallback
if echo "$step1" | grep -qi 'Do NOT fall back to inline'; then
  pass "Step 1 explicitly forbids inline-drafting fallback"
else
  fail "Step 1 missing 'Do NOT fall back to inline' guard"
fi

# ---------- SKILL.md Step 3 dispatch wiring ----------
echo
echo "=== SKILL.md Step 3 Atomic Task Drafting dispatch wiring ==="
step3=$(extract_section "^## Step 3: Atomic Task Drafting")
if echo "$step3" | grep -E 'subagent_type:\s*"?dso:task-decomposer"?[^\n]*model:\s*"opus"' >/dev/null; then
  pass "Step 3 dispatches dso:task-decomposer with explicit model: \"opus\" on the same line"
else
  fail "Step 3 does not dispatch dso:task-decomposer with explicit model: \"opus\""
fi
if echo "$step3" | grep -qi 'HALT'; then
  pass "Step 3 halts on validation failure"
else
  fail "Step 3 does not halt on validation failure"
fi
mru_line3=$(echo "$step3" | grep -nE 'VALIDATION-STEP-1:[[:space:]]*model_requirement_unmet' | head -1 | cut -d: -f1)
domain_line3=$(echo "$step3" | grep -nE 'VALIDATION-STEP-1\.5:[[:space:]]*domain-error-escalation' | head -1 | cut -d: -f1)
schema_line3=$(echo "$step3" | grep -nE 'VALIDATION-STEP-2:[[:space:]]*schema-validation' | head -1 | cut -d: -f1)
if [[ -n "$mru_line3" && -n "$domain_line3" && -n "$schema_line3" ]] && (( mru_line3 < domain_line3 && domain_line3 < schema_line3 )); then
  pass "Step 3 validation order: STEP-1 < STEP-1.5 < STEP-2 (lines $mru_line3 < $domain_line3 < $schema_line3)"
else
  fail "Step 3 validation ordering wrong or markers missing (mru=$mru_line3 domain=$domain_line3 schema=$schema_line3)"
fi
if echo "$step3" | grep -q 'decomposition_blocked'; then
  pass "Step 3 names 'decomposition_blocked' error envelope"
else
  fail "Step 3 does not reference 'decomposition_blocked' (the domain-error escalation path is undocumented)"
fi
if echo "$step3" | grep -qi 'Do NOT fall back to inline'; then
  pass "Step 3 explicitly forbids inline-drafting fallback"
else
  fail "Step 3 missing 'Do NOT fall back to inline' guard"
fi
# Step 3 schema validation must check that every task description begins with
# the '## Story DD Coverage' header — the audit-trail invariant that the
# completeness reviewer downstream depends on.
if echo "$step3" | grep -q '## Story DD Coverage'; then
  pass "Step 3 schema validation references the '## Story DD Coverage' header rule"
else
  fail "Step 3 schema validation does not require the '## Story DD Coverage' header on task descriptions"
fi
# Both Steps must disambiguate dispatch-target fallback from inline-drafting fallback
# so a reader does not conflate transport-routing with the forbidden orchestrator-does-the-work path.
for label in "Step 1:$step1" "Step 3:$step3"; do
  name="${label%%:*}"
  body="${label#*:}"
  if echo "$body" | grep -q 'Dispatch-target fallback' && echo "$body" | grep -q 'Inline-drafting fallback'; then
    pass "$name disambiguates Dispatch-target fallback from Inline-drafting fallback"
  else
    fail "$name does not disambiguate the two fallback concepts (reader may conflate transport-routing with forbidden inline drafting)"
  fi
done
# Sync-discipline note must appear in both steps (Step 3 already had it; Step 1 was missing it).
for label in "Step 1:$step1" "Step 3:$step3"; do
  name="${label%%:*}"
  body="${label#*:}"
  if echo "$body" | grep -qi 'sync discipline\|keep the two in sync\|dual-maintained'; then
    pass "$name carries a sync-discipline note"
  else
    fail "$name lacks a sync-discipline note (silent drift risk between SKILL.md and the agent file)"
  fi
done

# ---------- Completeness reviewer augmentation ----------
echo
echo "=== Completeness reviewer dd_collective_ac_coverage dimension ==="
if grep -q "dd_collective_ac_coverage" "$COMPLETENESS"; then
  pass "Completeness reviewer declares dd_collective_ac_coverage dimension"
else
  fail "Completeness reviewer missing dd_collective_ac_coverage dimension"
fi
if grep -q "Story DD Coverage" "$COMPLETENESS"; then
  pass "Completeness reviewer references '## Story DD Coverage' section anchor"
else
  fail "Completeness reviewer missing '## Story DD Coverage' reference"
fi
# Reviewer must include the audit protocol steps
for step in "DD → owning-task map" "Coverage standard" "Multi-task DDs"; do
  if grep -q "$step" "$COMPLETENESS"; then
    pass "Completeness reviewer documents audit-protocol step: '$step'"
  else
    fail "Completeness reviewer missing audit-protocol step: '$step'"
  fi
done
# JSON dimensions block lists the new dimension
if grep -A4 '"dimensions"' "$COMPLETENESS" | grep -q "dd_collective_ac_coverage"; then
  pass "Completeness reviewer JSON dimensions block lists dd_collective_ac_coverage"
else
  fail "Completeness reviewer JSON dimensions block does not list dd_collective_ac_coverage"
fi

# ---------- Plugin / registry plumbing ----------
echo
echo "=== plugin.json registration ==="
for agent in approach-proposer task-decomposer; do
  if grep -q "\"./agents/$agent.md\"" "$PLUGIN_JSON"; then
    pass "plugin.json registers $agent"
  else
    fail "plugin.json does not register $agent"
  fi
done

echo
echo "=== AGENTS.md registration ==="
for agent in approach-proposer task-decomposer; do
  if grep -q "\`dso:$agent\`" "$AGENTS_MD"; then
    pass "AGENTS.md registers dso:$agent"
  else
    fail "AGENTS.md does not register dso:$agent"
  fi
done

echo
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi
echo "ALL VALIDATIONS PASSED"
exit 0
