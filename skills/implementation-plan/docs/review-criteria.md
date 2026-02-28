# Implementation Plan Review Criteria

## Overview

The implementation plan is reviewed by a committee of four specialists using
`/review-protocol` (Stage 1, multi-agent). Each reviewer has a self-contained
prompt file in `docs/reviewers/plan/` that defines their persona, dimensions, and
scoring rubric.

The pass threshold for plan review is **5** (safety-critical — the plan must be
safe for unsupervised agent execution). All dimension scores across all reviewers
must equal 5 (or null for N/A) before the plan proceeds to task creation.

All reviewer output conforms to `REVIEW-SCHEMA.md`. See that document for the
JSON schema, field reference, and pass/fail derivation rules.

## Reviewer Prompts

| Reviewer | Prompt File | Perspective Label | Focus |
|----------|-------------|-------------------|-------|
| Task Design Specialist | [reviewers/plan/task-design.md](reviewers/plan/task-design.md) | Task Design | Atomicity, TDD discipline |
| Deployment Safety Engineer | [reviewers/plan/safety.md](reviewers/plan/safety.md) | Safety | Incremental deploy, backward compatibility |
| Dependency Graph Analyst | [reviewers/plan/dependencies.md](reviewers/plan/dependencies.md) | Dependencies | DAG validity, no coupling |
| Completeness Auditor | [reviewers/plan/completeness.md](reviewers/plan/completeness.md) | Completeness | Criteria coverage, E2E coverage |

## Launching Reviews

Use the Task tool to launch all four reviewers **in parallel**. For each:

1. Read the reviewer's prompt file from `docs/reviewers/plan/`
2. Construct the Task prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale, instructions)
   - The story context (ID, title, description, acceptance criteria)
   - The full implementation plan (numbered task list with titles, descriptions,
     TDD requirements, and declared dependency edges)
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Launch the Task with `subagent_type: "general-purpose"`

All four reviewer prompts must include these sub-agent prompt requirements:
- A score of 5 means you would trust an unsupervised agent to execute this plan
- Do NOT inflate scores — a 4 with suggestions is more useful than a false 5
- Flag any task requiring coordinated deployment across services
- Flag any task whose failure leaves the codebase broken
- Verify dependency graph: draw it mentally and check for missing edges
- Suggestions must be concrete ("split task 3 into 3a and 3b"), not abstract
  ("improve atomicity")

## Score Aggregation Rules

Per `/review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all four reviewers.
2. Any individual dimension score below 5 means the plan **fails** for that dimension.
3. ALL dimension scores must be 5 or null (N/A) for the plan to **pass**.
4. Maximum 3 automated revision cycles. After 3 failures, present the plan at
   its current score with remaining issues to the user for judgment.

## Conflict Detection

Per `/review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same task or artifact but pulling in opposite directions.

Common conflict patterns in plan review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| Task Design: "Split task into smaller units" | Completeness: "Criteria won't be covered with split" | `expand_vs_reduce` |
| Safety: "Add bridge task before removal" | Task Design: "Too many tasks, merge cleanup" | `more_vs_less` |
| Dependencies: "Serialize tasks A and B" | Task Design: "Both tasks can be atomic and parallel" | `strict_vs_flexible` |
| Completeness: "Add E2E test task" | Task Design: "Task has more than one concern" | `add_vs_remove` |

**Resolution** (per `/review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/review-protocol`'s revision protocol:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before revising.
3. Modify the specific task(s) each finding targets (split, merge, reorder, or add).
4. Document each revision in the review log.
5. Re-submit the full revised plan for the next review cycle.
