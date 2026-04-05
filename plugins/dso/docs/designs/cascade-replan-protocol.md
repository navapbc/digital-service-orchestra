# Cascade Replan Protocol

## Overview

The cascade replan protocol defines how the sprint orchestrator handles planning disagreements between implementation-plan and the current epic/story definitions. When implementation-plan determines that the stories it received cannot be executed as written — typically because requirements are ambiguous, contradictory, or structurally unimplementable — it signals the orchestrator with `REPLAN_ESCALATE`. The orchestrator then decides whether to route back through brainstorm and preplanning or to present the last available plan to the user.

## What the Cascade Does

A cascade replan is a coordinated revision loop across three skills:

1. **brainstorm** — revisits and revises the epic definition. The practitioner interacts with brainstorm to clarify scope, resolve ambiguities, or pivot the approach. The epic ticket is updated with the revised understanding.
2. **preplanning** — re-runs on the revised epic to regenerate user stories. Story tickets are updated or replaced to reflect the new epic direction.
3. **implementation-plan** — re-runs on each revised story to realign tasks to the new story definitions. If implementation-plan is satisfied with the plan it can execute, the cascade ends and sprint proceeds normally.

Each pass through all three skills constitutes one cascade iteration.

## Entry Conditions

The cascade protocol is entered when ALL of the following are true:

- The sprint orchestrator has received `REPLAN_ESCALATE` from implementation-plan for one or more stories in the current epic.
- The user has been presented with the escalation context and has confirmed they want brainstorm routing (i.e., the user has approved the replan rather than choosing to proceed with the current plan or abandon the epic).

The orchestrator MUST NOT enter the cascade autonomously without user confirmation. `REPLAN_ESCALATE` is a signal to surface the issue, not an automatic trigger.

## Exit Conditions

The cascade exits under either of these conditions:

### (a) Plan accepted by implementation-plan

implementation-plan completes for all stories in the epic without returning `REPLAN_ESCALATE`. This means implementation-plan has a plan it can execute. Sprint proceeds to Phase 5 (RED test writing) normally.

### (b) Max cascade iterations exhausted

The cascade iteration count reaches `sprint.max_replan_cycles` (configured in `.claude/dso-config.conf`, default: 2). When the cap is hit:

- The orchestrator presents the user with the last available plan produced by implementation-plan (even if marked REPLAN_ESCALATE).
- The orchestrator asks the user for direction: proceed with the current plan as-is, abort the epic, or make manual adjustments.
- The orchestrator does NOT autonomously loop further.

## Context Invalidation

Preplanning context is stored as `PREPLANNING_CONTEXT:` ticket comments on the epic (not in `/tmp/`). Each preplanning re-run writes a new comment; consumers (`/dso:implementation-plan`) read the **last** such comment in the array. No explicit invalidation step is needed — the new comment supersedes previous ones automatically.

## Cycle Count Tracking

The sprint orchestrator tracks the current cascade iteration count in a local variable initialized to 0 before the cascade loop begins. The count increments by 1 each time the full brainstorm → preplanning → implementation-plan sequence completes (regardless of whether implementation-plan produces REPLAN_ESCALATE again).

Pseudocode:

```
replan_cycle_count = 0
max_replan_cycles = read_config("sprint.max_replan_cycles", default=2)

while replan_escalated:
    if replan_cycle_count >= max_replan_cycles:
        present last plan to user
        ask for direction
        break

    confirm_user_wants_replan()
    run brainstorm (revise epic)
    run preplanning (revise stories — writes new PREPLANNING_CONTEXT comment)
    run implementation-plan (realign tasks)
    replan_cycle_count += 1

    if implementation-plan returns no REPLAN_ESCALATE:
        break  # exit condition (a): plan accepted
```

## When Max Cycles Are Hit

When `replan_cycle_count >= sprint.max_replan_cycles`:

1. The orchestrator surfaces the last plan produced by implementation-plan to the user, including the `REPLAN_ESCALATE` signal and the reason implementation-plan provided.
2. The orchestrator presents these options:
   - **Proceed**: Accept the current plan as-is and continue sprint execution. Implementation-plan will attempt to execute it.
   - **Abort**: Stop the sprint for this epic. The epic remains open; the practitioner can investigate further before retrying.
   - **Manual adjustment**: The practitioner will manually edit the relevant story or epic tickets, then the sprint can be resumed.
3. The orchestrator waits for user input. It does NOT autonomously loop, retry, or make a choice.

The `sprint.max_replan_cycles` cap is a safety boundary. Its purpose is to prevent unbounded planning loops that consume significant context and sub-agent budget without converging. When the cap is hit, the situation requires human judgment.
