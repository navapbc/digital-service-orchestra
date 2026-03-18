# Implementation Plan Review Criteria

## Overview

The implementation plan is reviewed by a committee of five specialists using
`/dso:review-protocol` (Stage 1, multi-agent). Each reviewer has a self-contained
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
| Task Design Specialist | [reviewers/plan/task-design.md](reviewers/plan/task-design.md) | Task Design | Atomicity, acceptance criteria |
| TDD Strategy Reviewer | [reviewers/plan/tdd.md](reviewers/plan/tdd.md) | TDD | TDD discipline, test isolation, red-green sequence, test boundary coverage |
| Deployment Safety Engineer | [reviewers/plan/safety.md](reviewers/plan/safety.md) | Safety | Incremental deploy, backward compatibility |
| Dependency Graph Analyst | [reviewers/plan/dependencies.md](reviewers/plan/dependencies.md) | Dependencies | DAG validity, no coupling |
| Completeness Auditor | [reviewers/plan/completeness.md](reviewers/plan/completeness.md) | Completeness | Criteria coverage, E2E coverage |

## Launching Reviews

Use the Task tool to launch all five reviewers **in parallel**. For each:

1. Read the reviewer's prompt file from `docs/reviewers/plan/`
2. Construct the Task prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale, instructions)
   - The story context (ID, title, description, acceptance criteria)
   - The full implementation plan (numbered task list with titles, descriptions,
     TDD requirements, and declared dependency edges)
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Launch the Task with `subagent_type: "general-purpose"`

All five reviewer prompts must include these sub-agent prompt requirements:
- A score of 5 means you would trust an unsupervised agent to execute this plan
- Do NOT inflate scores — a 4 with suggestions is more useful than a false 5
- Flag any task requiring coordinated deployment across services
- Flag any task whose failure leaves the codebase broken
- Verify dependency graph: draw it mentally and check for missing edges
- Suggestions must be concrete ("split task 3 into 3a and 3b"), not abstract
  ("improve atomicity")

## Score Aggregation Rules

Per `/dso:review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all five reviewers.
2. Any individual dimension score below 5 means the plan **fails** for that dimension.
3. ALL dimension scores must be 5 or null (N/A) for the plan to **pass**.
4. Maximum 3 automated revision cycles. After 3 failures, present the plan at
   its current score with remaining issues to the user for judgment.

## Conflict Detection

Per `/dso:review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same task or artifact but pulling in opposite directions.

Common conflict patterns in plan review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| Task Design: "Split task into smaller units" | Completeness: "Criteria won't be covered with split" | `expand_vs_reduce` |
| Safety: "Add bridge task before removal" | Task Design: "Too many tasks, merge cleanup" | `more_vs_less` |
| Dependencies: "Serialize tasks A and B" | Task Design: "Both tasks can be atomic and parallel" | `strict_vs_flexible` |
| Completeness: "Add E2E test task" | Task Design: "Task has more than one concern" | `add_vs_remove` |
| TDD: "Test targets implementation details" | Completeness: "Need test for this edge case" | `boundary_vs_coverage` |
| TDD: "Test must fail before implementation" | Task Design: "Bundle migration + model as one concern" | `red_green_vs_atomicity` |

**Resolution** (per `/dso:review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/dso:review-protocol`'s revision protocol:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before revising.
3. Modify the specific task(s) each finding targets (split, merge, reorder, or add).
4. Document each revision in the review log.
5. Re-submit the full revised plan for the next review cycle.

## Validation

After aggregating all reviewer outputs into the combined JSON (`subject`, `reviews[]`, `conflicts[]`), validate the output before using scores or findings. This ensures every required perspective, dimension, and reviewer-specific field is present and correctly typed.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
REVIEW_OUT="$(get_artifacts_dir)/implementation-plan-review-output.json"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
".claude/scripts/dso validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller implementation-plan
```

**Caller schema hash**: `ae8bfc7bd9a0d7e3` — identifies the exact set of perspectives, dimensions, and reviewer-specific fields expected from this caller.

If `SCHEMA_VALID: no` is printed:
1. Read the listed errors — they identify exactly which perspective, dimension, or finding field is missing or wrong.
2. Fix the output (re-request from the reviewer sub-agent if needed, correcting the format prompt).
3. Re-run validation until `SCHEMA_VALID: yes` before proceeding to score aggregation or revision cycles.
