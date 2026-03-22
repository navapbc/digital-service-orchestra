---
id: dso-rc4j
status: open
deps: [dso-lc3c]
links: []
created: 2026-03-22T16:33:07Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-oo34
---
# As a developer, all RED test workflows dispatch through the dedicated agent

See ticket notes for full story body.


## Notes

<!-- note-id: ok8k4i93 -->
<!-- timestamp: 2026-03-22T16:33:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Description

**What**: Update the three workflows that produce RED tests to dispatch through the tdd_red_test routing category instead of writing tests inline.
**Why**: Centralizes RED test writing in the dedicated agent, ensuring consistent intent-faithful tests across all TDD paths.
**Scope**:
- IN: Update /dso:fix-bug Step 5 to dispatch through tdd_red_test (passing investigation context and preserving re-escalation-to-Step-2 path), update /dso:tdd-workflow Step 1 to dispatch through tdd_red_test, update /dso:sprint execution path to dispatch RED test tasks through tdd_red_test (dispatch point is sprint sub-agent execution, not implementation-plan task drafting), define relationship between tdd_red_test and existing test_write routing category, review debug-everything test_write callers
- OUT: Agent definition (dso-lc3c), documentation (separate story)

## Done Definitions

- When this story is complete, /dso:fix-bug Step 5 dispatches RED test writing through tdd_red_test routing, passing investigation context (root cause, confidence, approved fix) and preserving the re-escalation-to-Step-2 path
  Satisfies SC4
- When this story is complete, /dso:tdd-workflow Step 1 dispatches RED test writing through tdd_red_test routing, passing ticket ID and test type
  Satisfies SC4
- When this story is complete, /dso:sprint sub-agent execution dispatches RED test tasks through tdd_red_test routing (dispatch point is sprint execution, not implementation-plan task drafting)
  Satisfies SC4
- When this story is complete, the relationship between tdd_red_test and the existing test_write routing category is defined and documented — debug-everything callers reviewed and updated or justified
  Adversarial finding: scope overlap
- Unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Dispatch pattern must be consistent across all three workflows to avoid drift
- [Reliability] ADVERSARIAL: fix-bug Step 5 currently writes RED tests inline with full investigation context from Steps 1-4 — sub-agent dispatch must explicitly pass this context and preserve the re-escalation loop
- [Reliability] ADVERSARIAL: implementation-plan generates task descriptions only — the actual RED test dispatch point is at sprint sub-agent execution time, not at planning time
