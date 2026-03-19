---
id: w21-u4ym
status: closed
deps: [w21-ahok]
links: []
created: 2026-03-19T03:31:29Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, dso:fix-bug is validated by resolving a real INTERMEDIATE or ADVANCED bug

## Description

**What**: Use dso:fix-bug to resolve a real INTERMEDIATE or ADVANCED bug in the DSO codebase, validating the full investigation-before-fix workflow.
**Why**: The skill must be proven on a real bug, not just tested with mocks. This confirms the investigation sub-agents identify root cause before fixing and RED tests fail before the fix is applied.
**Scope**:
- IN: Select a real bug from the backlog scoring >=3 on the rubric, invoke dso:fix-bug, verify the full workflow executes correctly
- OUT: This is validation, not additional feature work

## Done Definitions

- When this story is complete, dso:fix-bug has been used to resolve at least one INTERMEDIATE or ADVANCED bug in the DSO codebase
  ← Satisfies: "The skill is successfully used to resolve at least one INTERMEDIATE or ADVANCED bug"
- When this story is complete, the resolution demonstrates investigation sub-agents identifying root cause before any fix is attempted and RED tests failing before the fix is applied
  ← Satisfies: "confirming investigation sub-agents identify root cause before any fix is attempted and RED tests fail before the fix is applied"

## Considerations

- [Testing] Select a bug from the backlog that scores at least 3 on the rubric to qualify as INTERMEDIATE

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

## Notes

**2026-03-19T16:17:19Z**

CHECKPOINT: SESSION_END — Implementation tasks created (S4, S7). Remaining stories need execution of impl tasks + further impl planning (S5, S10, S11). Resume with /dso:sprint dso-tmmj --resume

**2026-03-19T20:16:31Z**

CHECKPOINT: SESSION_END — All other stories complete. w21-u4ym requires orchestrator-level execution of dso:fix-bug on a real bug from the backlog. w21-6fir (docs update) blocked only by this story. Resume with /dso:sprint dso-tmmj --resume

**2026-03-19T21:17:03Z**

DOGFOODING COMPLETE: Used dso:fix-bug to resolve w21-prlu (INTERMEDIATE, score=4). Investigation sub-agent (opus) identified root cause with high confidence before any fix attempted. RED tests confirmed (10 failures). Fix applied. GREEN tests confirmed (0 failures). Full workflow: Step 0 (known issues) → Step 1 (score=4, INTERMEDIATE) → Step 2 (opus investigation) → Step 3 (hypothesis testing) → Step 4 (auto-approved) → Step 5 (RED confirmed) → Step 6 (fix implementation) → Step 7 (GREEN verified) → Step 8 (committed 768ff72).
