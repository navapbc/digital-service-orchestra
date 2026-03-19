---
id: dso-56g6
status: closed
deps: [dso-ezme]
links: []
created: 2026-03-19T18:36:55Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# GREEN: Create escalated-investigation-agent-4.md — Empirical Agent prompt (authorized logging/debugging, empirical validation, veto of agents 1-3, artifact revert)

## Description

Create the Empirical/Logging Agent prompt template for ESCALATED investigation Agent 4. This is the most novel prompt in the ESCALATED tier — Agent 4 has unique capabilities that no other investigation agent has: it is authorized to add temporary logging and debugging instrumentation to empirically test hypotheses.

**File to create**: `plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md`

**Implementation steps**:
1. Use `advanced-investigation-agent-a.md` as a structural starting point but heavily modify it
2. Create the prompt with these sections:
   - **Role framing**: "You are an ESCALATED-tier Empirical Agent. Unlike the other ESCALATED agents, you are authorized to make temporary modifications to the codebase — specifically, adding logging statements and enabling debug flags — to empirically validate or veto the hypotheses proposed by Agents 1-3. You must revert or stash ALL such changes after collecting evidence. Your findings take precedence over theoretical analysis when they provide concrete empirical evidence."
   - **Context block**: `{ticket_id}`, `{failing_tests}`, `{stack_trace}`, `{commit_history}`, `{prior_fix_attempts}`, `{escalation_history}` (previous ADVANCED findings + Agents 1-3 hypotheses from current ESCALATED tier)
   - **Investigation steps**:
     1. Read all three hypotheses from Agents 1-3 in `{escalation_history}` — understand what each agent claims is the root cause
     2. Identify the highest-value empirical test: what logging or debugging would definitively confirm or contradict the consensus hypothesis?
     3. Add minimal targeted logging (e.g., `print()` or `logging.debug()`) to the relevant code path
     4. Run the failing tests to collect empirical evidence
     5. Revert all logging additions immediately after collecting evidence (use `git diff` to confirm clean revert)
     6. Analyze the empirical evidence against the three agent hypotheses
     7. Veto decision: if empirical evidence contradicts the consensus of Agents 1-3, explicitly issue a veto with evidence
     8. Self-reflection: is your empirical evidence sufficient to override theoretical consensus?
   - **Veto protocol**: describe exactly when to veto: "Issue a veto when your empirical evidence (execution logs, variable values, call paths) directly contradicts the root cause proposed by the consensus of Agents 1-3. A veto requires concrete evidence — not a different theory."
   - **Artifact revert requirement**: state explicitly "ALL logging/debugging additions MUST be reverted before returning results. Run `git diff` to confirm a clean working tree. If a revert fails, note this prominently in the RESULT."
   - **RESULT schema**: ROOT_CAUSE, confidence, veto_issued (true/false), veto_evidence (what empirical evidence triggered the veto, or null), proposed_fixes (at least 3 not already attempted), tests_run (including the empirical tests with logging), artifact_revert_confirmed (true/false), prior_attempts
   - **Rules section**: temporary modifications to source files are authorized (logging only); all modifications must be reverted; do NOT implement fixes; do NOT dispatch sub-agents
3. Run `python -m pytest tests/skills/test_escalated_investigation_agent_4_prompt.py -q` — all tests must PASS (GREEN)

**TDD Requirement**: Tests from dso-ezme must FAIL before this task. Run `python -m pytest tests/skills/test_escalated_investigation_agent_4_prompt.py -q` after creating; all must pass.

**Constraints**:
- `{escalation_history}` placeholder required
- `veto` language required (veto authority and protocol)
- `revert` or `stash` language required (artifact cleanup)
- `logging` and `debugging` authorization language required
- Must contain `at least 3` fixes language
- `validates` or `validate` language required

## ACCEPTANCE CRITERIA

- [ ] All tests in `test_escalated_investigation_agent_4_prompt.py` PASS
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_escalated_investigation_agent_4_prompt.py -q 2>&1 | grep -q 'passed'
- [ ] Prompt file exists at expected path
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md
- [ ] Prompt contains `{escalation_history}` placeholder
  Verify: grep -q '{escalation_history}' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md
- [ ] Prompt contains veto authority language
  Verify: grep -q 'veto' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md
- [ ] Prompt contains artifact revert requirement
  Verify: grep -qE 'revert|stash' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md
- [ ] Prompt contains ROOT_CAUSE RESULT field
  Verify: grep -q 'ROOT_CAUSE' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/escalated-investigation-agent-4.md
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

## Notes

**2026-03-19T18:52:00Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T18:52:05Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T18:52:09Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-19T18:53:03Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T18:53:15Z**

CHECKPOINT 5/6: Validation passed ✓ — 11/11 tests pass

**2026-03-19T18:53:28Z**

CHECKPOINT 6/6: Done ✓ — all AC verified

**2026-03-19T18:53:48Z**

CHECKPOINT 6/6: Done ✓ — 11 tests GREEN
