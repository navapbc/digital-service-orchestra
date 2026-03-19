---
id: dso-dghs
status: open
deps: []
links: []
created: 2026-03-18T17:58:29Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-l2ct
jira_key: DIG-72
---
# As a DSO practitioner, the sprint skill contains no explanatory prose or motivation framing

## Description
**What:** Remove all "Why this step exists" blocks, rationale paragraphs, motivation framing, and human-facing explanatory prose from all phases of `skills/sprint/SKILL.md`. This is purely subtractive — no rewrites, no behavior changes, only deletion of lines that narrate rather than instruct.

**Why:** Explanatory prose inflates context load without contributing to agent execution. Each "Why this step exists" block explains the design to a human reader but adds no instruction for the agent.

**Scope:**
- IN: "Why this step exists" blocks, rationale paragraphs starting with "Why:" or explaining step motivations, motivation framing that narrates existing logic without adding new behavioral instruction
- OUT: Behavioral instructions, step commands, config values, technical notes required by sub-agents, inline notes that condition agent behavior (e.g., "Note: If X, then Y")

## Done Definitions
- When this story is complete, `skills/sprint/SKILL.md` word count is at least 20% lower than the post-dso-x1jt baseline (measured at start of dso-dghs implementation and documented in commit message)
  ← Satisfies: "word count decreases by at least 20%"
- When this story is complete, `bash tests/run-all.sh` passes with 0 failures
  ← Satisfies: "bash tests/run-all.sh passes with 0 failures"
- When this story is complete, the post-dso-x1jt baseline word count is captured via `wc -w skills/sprint/SKILL.md` before any edits begin, and included in the commit message as "Baseline: N words → Final: M words (X% reduction)"
  ← Satisfies measurability of the 20% reduction target

## Considerations
- [Maintainability] Distinguish behavioral instructions from explanatory prose carefully — "Why this step exists" blocks are clearly removable, but inline notes that say "Note: do X because Y happens" may condition agent behavior and must be kept if they inform execution decisions.
