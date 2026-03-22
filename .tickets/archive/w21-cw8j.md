---
id: w21-cw8j
status: closed
deps: [w21-1as4]
links: []
created: 2026-03-21T21:05:06Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-2j6u
---
# As a practitioner, I receive complexity classifications from the dedicated agent across brainstorm, fix-bug, and debug-everything

## Description

**What**: Update brainstorm, fix-bug, and debug-everything skills to dispatch complexity classification via the dedicated `dso:complexity-evaluator` agent instead of loading the shared rubric prompt into a general-purpose task.
**Why**: Completing the extraction across all callers ensures consistent classification behavior and format compliance. fix-bug requires special attention as it currently reads the rubric inline (not via sub-agent dispatch).
**Scope**:
- IN: Update brainstorm Step 4a dispatch (currently loads `shared/prompts/complexity-evaluator.md` content into haiku task prompt). Update fix-bug Step 4.5 (currently reads shared rubric inline — convert to sub-agent dispatch or inline Read of agent definition). Update debug-everything references to reflect that fix-bug now uses the named agent.
- OUT: Sprint callers (w21-1as4). Resolve-conflicts (w21-kezk). Shared rubric file lifecycle (w21-nica).

## Done Definitions

- When this story is complete, brainstorm dispatches complexity classification via `subagent_type: dso:complexity-evaluator` instead of loading shared rubric into a general-purpose task prompt
  ← Satisfies: "Practitioners invoking /dso:brainstorm receive complexity classifications from dso:complexity-evaluator"
- When this story is complete, fix-bug dispatches complexity classification via `subagent_type: dso:complexity-evaluator` or reads the agent definition file inline (if nesting constraints prevent sub-agent dispatch)
  ← Satisfies: "Practitioners invoking /dso:fix-bug receive complexity classifications from dso:complexity-evaluator"
- When this story is complete, debug-everything references are updated to reflect that fix-bug now uses the named agent for post-investigation complexity evaluation
  ← Satisfies: "dso:debug-everything dispatch complexity classification via subagent_type: dso:complexity-evaluator"
- When this story is complete, context-specific routing (brainstorm's routing table, fix-bug's TRIVIAL/MODERATE proceed vs COMPLEX escalation, debug-everything's MODERATE→TRIVIAL de-escalation) remains in each calling skill, not in the agent definition
  ← Satisfies: "Each caller's context-specific routing logic remains in the calling skill"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Maintainability] Context-specific routing tables (shared rubric lines 112-124) must NOT be copied into agent definition — verify routing stays in callers after update
- [Nesting] fix-bug runs as a sub-agent of debug-everything. Converting inline rubric evaluation to sub-agent dispatch creates two levels of nesting (debug-everything → fix-bug → complexity-evaluator). Verify Claude Code supports this nesting depth, or keep fix-bug's evaluation as inline Read of the agent definition file rather than sub-agent dispatch. Critical Rule 23 warns about two-level nesting causing Tool result failures.

## ACCEPTANCE CRITERIA

- [ ] brainstorm/SKILL.md references `dso:complexity-evaluator` subagent_type for dispatch
  Verify: grep -q "dso:complexity-evaluator" $(git rev-parse --show-toplevel)/plugins/dso/skills/brainstorm/SKILL.md
- [ ] fix-bug/SKILL.md references `dso:complexity-evaluator` for complexity evaluation
  Verify: grep -q "complexity-evaluator" $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] debug-everything/SKILL.md references updated to reflect fix-bug uses named agent
  Verify: grep -q "complexity-evaluator\|named agent" $(git rev-parse --show-toplevel)/plugins/dso/skills/debug-everything/SKILL.md
- [ ] Context-specific routing logic remains in each caller skill
  Verify: grep -q "MODERATE" $(git rev-parse --show-toplevel)/plugins/dso/skills/brainstorm/SKILL.md
- [ ] Unit tests exist for dispatch verification
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_brainstorm_complexity_dispatch.py || test -f $(git rev-parse --show-toplevel)/tests/skills/test_remaining_callers_dispatch.py || test -f $(git rev-parse --show-toplevel)/tests/skills/test_brainstorm_complexity_dispatch.sh


## Notes

**2026-03-21T22:43:21Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T22:44:01Z**

CHECKPOINT 2/6: Code patterns understood ✓ — brainstorm Step 4a loads shared rubric into haiku task (needs subagent_type update); fix-bug Step 4.5 reads skills/shared/prompts/complexity-evaluator.md inline (change to read agents/complexity-evaluator.md due to nesting constraint); debug-everything line 532 describes fix-bug complexity evaluation (update to mention named agent)

**2026-03-21T22:44:55Z**

CHECKPOINT 3/6: Tests written ✓ — 4 RED failures confirmed: brainstorm Step4a (2 tests), fix-bug Step4.5 shared path reference, debug-everything missing complexity-evaluator reference. 3 existing tests pass (routing tables present, fix-bug already has 'complexity-evaluator' string)

**2026-03-21T22:45:39Z**

CHECKPOINT 4/6: Implementation complete ✓ — brainstorm Step4a now uses subagent_type dso:complexity-evaluator; fix-bug Step4.5 now reads plugins/dso/agents/complexity-evaluator.md with note explaining nesting constraint; debug-everything Tier 2+ note updated to reference named complexity-evaluator agent

**2026-03-21T22:45:54Z**

CHECKPOINT 5/6: Tests GREEN ✓ — all 7 tests pass (was 4 RED before implementation)

**2026-03-21T22:45:59Z**

CHECKPOINT 6/6: Done ✓ — all 5 AC verified: brainstorm dispatches via dso:complexity-evaluator subagent_type, fix-bug references complexity-evaluator agent definition (inline), debug-everything references complexity-evaluator named agent, routing logic stays in callers, unit tests exist and pass
