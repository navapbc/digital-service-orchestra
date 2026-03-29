# Three-Tier Escalation Protocol for RED Test Tasks

Shared template consumed by `/dso:sprint` (Phase 4 RED task dispatch, task 79de-de6e) and `/dso:fix-bug` (Story 79a6-2094).
Referenced from sprint SKILL.md via `prompts/red-task-escalation.md`.

Reference contracts:
- `plugins/dso/docs/contracts/red-test-writer-output.md` — writer output schema (`TEST_RESULT:written` / `TEST_RESULT:rejected`)
- `plugins/dso/docs/contracts/red-test-evaluator-verdict.md` — evaluator verdict schema (`VERDICT:REVISE` / `VERDICT:REJECT` / `VERDICT:CONFIRM`)

---

## Tier 1: Sonnet RED Test Writer

Dispatch a task to `dso:red-test-writer` (sonnet) with the task context (task description, story context, file impact table).

Parse the leading `TEST_RESULT:` line from the output:

| Result | Action |
|--------|--------|
| `TEST_RESULT:written` | Success. Proceed to TDD setup using `TEST_FILE` and `RED_ASSERTION` fields. Do NOT escalate. |
| `TEST_RESULT:rejected` | Escalate to Tier 2. `TEST_RESULT:rejected` is **not** an infrastructure failure — it triggers this escalation protocol, not dispatch failure recovery (Phase 5 Step 0). |
| Timeout / malformed / non-zero exit | Treat as `TEST_RESULT:rejected` with `REJECTION_REASON: ambiguous_spec` per the writer failure contract. Escalate to Tier 2. |

---

## Tier 2: Opus Evaluator Triage

Dispatch `dso:red-test-evaluator` (opus) with:

1. The full `TEST_RESULT:rejected` payload from Tier 1 (verbatim — do not truncate or rephrase)
2. The orchestrator context envelope:

```
TASK_ID: <task_id>
STORY_ID: <story_id>
EPIC_ID: <epic_id>
TASK_DESCRIPTION: <task_description>
IN_PROGRESS_TASKS: <comma-separated task_ids or "none">
CLOSED_TASKS: <comma-separated task_ids or "none">
```

Parse the leading `VERDICT:` line from the evaluator output:

| Verdict | Action |
|---------|--------|
| `VERDICT:REVISE` | Requeue all tasks listed in `AFFECTED_TASKS` to the next batch. Apply `REVISION_GUIDANCE` when re-dispatching. Max one REVISE per task — if the same task reaches REVISE a second time, escalate to the user immediately. |
| `VERDICT:REJECT` | Escalate to Tier 3 (opus retry). |
| `VERDICT:CONFIRM` | Close the task without implementation. The infeasibility is legitimate (category in `INFEASIBILITY_CATEGORY`). Record the `JUSTIFICATION` in a ticket comment before closing. |
| Timeout / malformed / non-zero exit | Treat as `VERDICT:REJECT` per the evaluator failure contract. Escalate to Tier 3. |

---

## Tier 3: Opus RED Test Writer Retry

Re-dispatch the original task to `dso:red-test-writer` with a model override to **opus**.

Pass the same task context as Tier 1, augmented with the evaluator's `VERDICT:REJECT` payload (including its `REJECTION_REASON` field) from Tier 2 so the opus writer has full context on why the sonnet attempt was deemed insufficient.

Parse the leading `TEST_RESULT:` line:

| Result | Action |
|--------|--------|
| `TEST_RESULT:written` | Success. Proceed to TDD setup normally. |
| `TEST_RESULT:rejected` | Terminal failure. Escalate to the user with: the Tier 1 rejection payload, the Tier 2 `VERDICT:REJECT` reason, and the Tier 3 rejection payload. Do not retry further. |
| Timeout / malformed / non-zero exit | Terminal failure. Escalate to the user. |

---

## Escalation Summary

```
Tier 1: dso:red-test-writer (sonnet)
  → TEST_RESULT:written  ──────────────────────────────► TDD setup (done)
  → TEST_RESULT:rejected ──────────────────────────────► Tier 2

Tier 2: dso:red-test-evaluator (opus)
  → VERDICT:CONFIRM  ──────────────────────────────────► Close task (TDD infeasible)
  → VERDICT:REVISE   ──────────────────────────────────► Requeue affected tasks (max 1 REVISE per task)
  → VERDICT:REJECT   ──────────────────────────────────► Tier 3

Tier 3: dso:red-test-writer (opus model override)
  → TEST_RESULT:written  ──────────────────────────────► TDD setup (done)
  → TEST_RESULT:rejected ──────────────────────────────► User escalation (terminal)
```

---

## Important Notes

- `TEST_RESULT:rejected` is **NOT** an infrastructure failure. It is an expected output from `dso:red-test-writer` that triggers this escalation protocol. Do not route it to Phase 5 Step 0 (dispatch failure recovery).
- The REVISE limit (max 1 per task) prevents infinite requeue loops. On the second REVISE for the same task, stop and escalate to the user with both REVISE payloads.
- For `VERDICT:CONFIRM`, always record the `INFEASIBILITY_CATEGORY` and `JUSTIFICATION` in a ticket comment before closing the task so the decision is auditable.
- This template is consumed by both `/dso:sprint` and `/dso:fix-bug`. Both orchestrators follow the same three tiers with the same verdict handling rules.
