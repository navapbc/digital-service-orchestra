# Milestone Fidelity Review Criteria

## Overview

Each drafted milestone is reviewed by three specialist reviewers using `/review-protocol`
(Stage 1, pass_threshold 4). Each reviewer has a self-contained prompt file in
`docs/reviewers/` that defines their persona, dimensions, and scoring rubric.
The subject for every review is `"Milestone: {milestone title}"`.

All reviewer output conforms to `REVIEW-SCHEMA.md`. See that document for the
JSON schema, field reference, and pass/fail derivation rules.

## Reviewer Prompts

| Reviewer | Prompt File | Perspective Label | Focus |
|----------|-------------|-------------------|-------|
| Senior Technical Program Manager | [reviewers/agent-clarity.md](reviewers/agent-clarity.md) | Agent Clarity | Self-contained spec, measurable success criteria |
| Senior Product Strategist | [reviewers/scope.md](reviewers/scope.md) | Scope | Right-sized deliverable, no overlap with other milestones, explicit dependency mapping |
| Senior Product Manager | [reviewers/value.md](reviewers/value.md) | Value | User or business impact, user validation signal |

## Launching Reviews

Use the Task tool to launch all three reviewers **in parallel**. For each:

1. Read the reviewer's prompt file from `docs/reviewers/`
2. Construct the Task prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale)
   - The milestone spec (title, Context narrative, Success Criteria)
   - For the Scope reviewer: the titles and summaries of all other milestones being drafted in this session (roadmap context)
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Launch the Task with `subagent_type: "general-purpose"`

## Score Aggregation Rules

Per `/review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all three reviewers.
2. Any individual dimension score below 4 means the milestone **fails** for that dimension.
3. ALL dimension scores must be 4, 5, or null (N/A) for the milestone to **pass**.
4. Incorporate findings into the milestone spec before presenting to the user.
5. If a milestone fails, revise the spec and re-run the fidelity check before proceeding.

## Conflict Detection

Per `/review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same part of the milestone spec but pulling in opposite
directions.

Common conflict patterns in milestone review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| Scope: "Milestone is too broad, split it" | Agent Clarity: "Success criteria are already thin, don't reduce further" | `expand_vs_reduce` |
| Value: "Add dependency on prior milestone" | Scope: "This overlap means it should merge with that milestone" | `strict_vs_flexible` |
| Agent Clarity: "Add more context to the spec" | Scope: "Scope is already too wide" | `more_vs_less` |

**Resolution** (per `/review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/review-protocol`'s revision protocol:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before revising.
3. Modify the milestone's Context narrative and/or Success Criteria based on findings.
4. Re-run the fidelity check until all dimensions score 4 or above, or escalate to the user.
