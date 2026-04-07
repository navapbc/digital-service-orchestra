# ADR 0002: Sprint Mid-Implementation Gap Detection and Routing

**Status**: Accepted
**Date**: 2026-04-04
**Epic**: 9d3e-957d — Sprint mid-implementation gap detection and routing

---

## Context

The `/dso:sprint` orchestrator previously had no mechanism to detect when the codebase had drifted under an active sprint, when a sub-agent completed a task but was uncertain about its own correctness, when a story's done-definition failed validation despite all tasks being closed, or when a code review identified work outside the originally scoped files.

These gaps caused silent failures: epics would close with undetected scope drift, low-confidence task closures would go unreviewed, and out-of-scope implementation decisions made during code review had no downstream tracking. The result was technical debt accumulation between sprint completion and the next debug cycle.

The team needed a self-healing layer in the sprint orchestrator that could catch these conditions at the earliest feasible lifecycle checkpoint and route to remediation automatically — without blocking the sprint when the condition is benign, and without requiring human intervention for low-blast-radius cases.

---

## Decision

Add four detection checkpoints to the sprint orchestrator, each governed by a defined signal protocol:

1. **Drift detection at sprint entry (Phase 1 Step 6)**: `sprint-drift-check.sh` compares git commit history since each task's creation timestamp against the file impact table declared in the task. Stories with drifted files are re-routed through `implementation-plan` before Phase 4 batch execution begins.

2. **Confidence signal routing (Phase 5 Step 1a2)**: Task-execution sub-agents emit a `CONFIDENT` or `UNCERTAIN:<reason>` line in their final report. The orchestrator counts `UNCERTAIN` signals per story (not per task ID, to survive task replacement). At the double-failure threshold (2 signals), the orchestrator re-invokes `implementation-plan` for the story (Phase 3 double-failure detection). In non-interactive mode, brainstorm-level escalations write `INTERACTIVITY_DEFERRED` instead of blocking for user input.

3. **Story validation failure routing (Step 10a)**: When all tasks on a story are closed but the story's done-definition validation fails, the orchestrator re-invokes `implementation-plan` to create TDD remediation tasks rather than force-closing the story or silently failing.

4. **Out-of-scope review feedback routing (Steps 7a / 13a)**: `sprint-review-scope-check.sh` compares accepted review findings against the files listed in the story's task scope. Files outside scope that received accepted findings trigger a `implementation-plan` re-invocation to create tasks covering those files.

All re-planning events are recorded as structured ticket comments (`REPLAN_TRIGGER` / `REPLAN_RESOLVED` / `INTERACTIVITY_DEFERRED`) on the epic for audit trail and resume-anchor scanning. These observability signals are distinct from the inter-skill `REPLAN_ESCALATE` signal defined in `replan-escalate-signal.md`.

The confidence signal contract and observability signal contract are defined in separate files to allow independent versioning and to make the emitter/parser contract explicit.

---

## Consequences

**Positive:**
- Codebase drift is detected before implementation begins, not after a story fails review.
- Low-confidence task closures surface to the user at a natural checkpoint rather than silently producing defective output.
- Validation failures after task closure have a defined remediation path instead of requiring manual triage.
- Out-of-scope review findings generate tracked tasks rather than being deferred to institutional memory.
- All re-planning events are observable via the epic's ticket comment history without requiring log access.

**Negative / Trade-offs:**
- Four additional detection steps increase sprint execution time, particularly when drift or scope changes are frequent.
- The double-failure threshold (2 UNCERTAIN signals) is a fixed constant. Stories with genuinely uncertain implementation domains will interrupt the sprint more often than stories with clear scope.
- Non-interactive sprints cannot complete brainstorm-escalation re-planning; `INTERACTIVITY_DEFERRED` comments accumulate and require manual follow-up.
- `sprint-drift-check.sh` depends on task creation timestamps and the git commit graph. Rebases or squash merges that rewrite timestamps can produce false drift signals.

**Contracts introduced:**
- `plugins/dso/docs/contracts/confidence-signal.md` — CONFIDENT/UNCERTAIN emitter/parser interface
- `plugins/dso/docs/contracts/replan-observability.md` — REPLAN_TRIGGER/REPLAN_RESOLVED/INTERACTIVITY_DEFERRED ticket comment formats

**Scripts introduced:**
- `plugins/dso/scripts/sprint-drift-check.sh`
- `plugins/dso/scripts/sprint-review-scope-check.sh`
