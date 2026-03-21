---
id: w21-cw8j
status: open
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

