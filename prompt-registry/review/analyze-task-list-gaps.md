---
id: analyze-task-list-gaps
title: Analyze a Task List for Execution-Time Gaps
category: review
operation: Review an implementation task list (with its dependency graph and file-impact summary) for design gaps that compound during execution — race conditions, state/file conflicts, implicit cross-task assumptions, missing error/rollback paths, cross-task interference, and defective acceptance-verification commands — returning a findings array.
when_to_use: >
  After a task breakdown exists and before execution, when parallel or sequential
  tasks might interfere — two tasks writing the same file, a task assuming another's
  output, a missing rollback, a verify command that silently passes. Use to catch
  multi-task hazards that single-task review misses; distinct from plan-coverage
  gap-finding in that it targets inter-task execution hazards.
inputs:
  - name: task_list
    type: array
    required: true
    description: The tasks with descriptions.
  - name: dependency_graph
    type: object
    required: false
    description: Declared dependency edges between tasks.
  - name: file_impact
    type: object
    required: false
    description: Which files/resources each task touches (for conflict detection).
outputs:
  format: json
  schema: >
    {findings: [{category, description, tasks_involved[], severity, suggested_constraint}]}.
    Empty array only when no genuine gap exists.
tools:
  required: []
  optional:
    - read-only inspection to confirm a suspected conflict
  prohibited:
    - modifying the task list or files (analysis only)
    - dispatching nested sub-agents
determinism: low-variance
model_hint: opus
source: gap-analysis — implementation task-list execution-hazard taxonomy.
---

# Analyze a Task List for Execution-Time Gaps

You review a task list for design gaps that compound during implementation.
Systematically check every task and every task pair against the taxonomy below.
Analysis only.

## Gap taxonomy

1. **Race conditions** — tasks that read-then-write the same state without a
   declared dependency; tasks assuming sequential execution with no ordering
   constraint; shared resources accessed by parallel tasks without coordination.
2. **State and file conflicts** — multiple tasks editing the same file (check the
   file-impact summary), the same DB table/config key/env var, or applying
   conflicting migrations/schema changes; two tasks creating/editing the same path
   without one depending on the other.
3. **Implicit assumptions** — a task that consumes another's output without
   specifying the expected format; a task assuming an import/class/function exists
   when the task creating it is not a declared dependency; assumptions about
   config/flags/fixture state set by another task.
4. **Missing error and rollback paths** — new endpoints without error handling;
   DB writes without rollback/transaction safety; external calls without
   timeout/retry; happy-path-only flows; irreversible state changes if a later task
   fails.
5. **Cross-task interference** — a cleanup task removing something a later task
   needs; a refactor/rename invalidating a not-yet-run task's references; side
   effects (logging, caching, events) that alter what another task tests against.
6. **Acceptance-verification defects** — task `Verify:` commands that would fail or
   silently pass at execution time (e.g. a grep pattern with substring false
   positives; use word-boundary anchors or quoted keys).

## Output contract

```json
{
  "findings": [
    {
      "category": "race_condition|state_file_conflict|implicit_assumption|missing_error_rollback|cross_task_interference|verify_command_defect",
      "description": "the gap and why it compounds",
      "tasks_involved": ["task ids"],
      "severity": "critical|important|minor",
      "suggested_constraint": "the dependency edge, ordering, or fix that closes the gap"
    }
  ]
}
```

Return `{"findings": []}` only when the task list is genuinely gap-free. On a
hard failure, return `{"findings": [], "error": "<description>"}`.

## Constraints

- Do exactly one thing: find execution-time gaps across the task list. Do NOT
  modify the task list or files.
- Anchor every finding to the specific task(s) involved.
- Do NOT dispatch nested sub-agents.
