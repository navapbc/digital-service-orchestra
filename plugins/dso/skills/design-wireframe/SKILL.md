---
name: design-wireframe
description: >
  DEPRECATED — design wireframe functionality has moved to the dso:ui-designer
  agent, dispatched by /dso:preplanning Step 6. Run /dso:preplanning on the
  parent epic to orchestrate UI story design via the Agent tool.
argument-hint: [story-id]
---

# design-wireframe Redirect

This skill has been superseded by the `dso:ui-designer` agent. Design wireframes
are now created by the preplanning orchestrator.

## New Workflow

1. **`/dso:preplanning <epic-id>`** — identifies UI stories and dispatches
   `dso:ui-designer` for each one via the Agent tool (Step 6). Read
   `plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md`
   for the dispatch protocol.
2. **`dso:ui-designer` agent** — creates design artifacts (spatial layout,
   SVG wireframe, design token overlay, manifest) and returns a
   `UI_DESIGNER_PAYLOAD` block.

This change eliminates the Skill-tool nesting that caused
`[Tool result missing due to internal error]` failures when the preplanning
orchestrator (level 1) invoked this skill (level 2) which then dispatched
sub-agents (level 3).

## If You Invoked This Skill Directly

Run `/dso:preplanning <epic-id>` instead. The preplanning orchestrator will
identify any UI stories and dispatch `dso:ui-designer` for each one.
