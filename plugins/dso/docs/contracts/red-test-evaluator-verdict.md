# Contract: Red Test Evaluator Verdict Interface

- Signal Name: RED_TEST_EVALUATOR_VERDICT
- Status: accepted
- Scope: red-test-evaluator agent (epic 20f2-aeeb)
- Date: 2026-03-26

## Purpose

This document defines the structured verdict interface emitted by `dso:red-test-evaluator` (opus, emitter) and consumed by sprint and fix-bug orchestrators (parsers). The evaluator receives a `TEST_RESULT:rejected` payload from the red-test-writer (per the `RED_TEST_WRITER_OUTPUT` contract) plus an orchestrator-supplied context envelope, and emits one of three verdicts: REVISE (the task list needs adjustment), REJECT (the task is unsuitable for automated TDD evaluation), or CONFIRM (the infeasibility is legitimate and the task may proceed without a RED test).

This contract must be agreed upon before either side is implemented to prevent implicit assumptions and ensure emitter and parser stay in sync.

---

## Signal Name

`RED_TEST_EVALUATOR_VERDICT`

---

## Emitter

`dso:red-test-evaluator` (opus)

The emitter receives the full orchestrator input (described below) and reasons about the rejection. It determines whether the rejection is well-founded (CONFIRM), whether the task description is resolvable (REVISE), or whether the task falls outside the scope of automated TDD evaluation (REJECT). It outputs exactly one verdict block to stdout, then exits.

---

## Parser

Sprint and fix-bug orchestrators (`/dso:sprint`, `/dso:fix-bug`)

The parser invokes the evaluator as a sub-agent **only when the writer emits `TEST_RESULT:rejected`**. Writer outputs of `TEST_RESULT:written` and `TEST_RESULT:no_new_tests_needed` bypass the evaluator — the parser does not dispatch this agent for those cases. When the evaluator is invoked, the parser reads the leading `VERDICT:` line to determine which of the three formats was emitted, then processes the fields accordingly. On `VERDICT:REVISE`, it updates the task list and re-runs the writer. On `VERDICT:REJECT`, it escalates to the user with the rejection reason and recommended model. On `VERDICT:CONFIRM`, it records the infeasibility category and allows the task to proceed without a RED test.

---

## Input Schema

The evaluator receives a single prompt containing two sections: the writer's rejection payload and an orchestrator context envelope. Both sections are required.

### Section 1 — Writer Rejection Payload

The full `TEST_RESULT:rejected` block emitted by `dso:red-test-writer`, conforming to the `RED_TEST_WRITER_OUTPUT` contract. The evaluator must parse this block to extract `REJECTION_REASON`, `DESCRIPTION`, and `SUGGESTED_ALTERNATIVE` before forming a verdict.

```
TEST_RESULT:rejected
REJECTION_REASON: <enum value>
DESCRIPTION: <explanation>
SUGGESTED_ALTERNATIVE: <alternative or "none">
ESTIMATED_RUNTIME_RED: <positive integer seconds — optional, backward-compatible>
ESTIMATED_RUNTIME_GREEN: <positive integer seconds — optional, backward-compatible>
```

The `ESTIMATED_RUNTIME_RED` and `ESTIMATED_RUNTIME_GREEN` fields are optional (backward-compatible). When present and either exceeds 10 seconds for a unit test, the evaluator must perform a runtime budget check before applying standard verdict routing (see Runtime-Aware Behavior below).

### Section 2 — Orchestrator Context Envelope

Structured key-value fields supplied by the orchestrator to give the evaluator visibility into the surrounding task context.

| Field | Type | Required | Description |
|---|---|---|---|
| `task_id` | string | required | Ticket ID of the task being evaluated. Example: `a3f1-bc22` |
| `story_id` | string | required | Ticket ID of the parent story. Example: `eedc-c886` |
| `epic_id` | string | required | Ticket ID of the grandparent epic. Example: `20f2-aeeb` |
| `task_description` | string | required | Full description of what the task is expected to implement. Taken verbatim from the task ticket body. |
| `in_progress_tasks` | array of string | required | Ticket IDs of sibling tasks currently in `in_progress` status. May be empty (`[]`). |
| `closed_tasks` | array of string | required | Ticket IDs of sibling tasks already in `closed` status. May be empty (`[]`). |

#### Context Envelope Format (prompt representation)

```
TASK_ID: <task_id>
STORY_ID: <story_id>
EPIC_ID: <epic_id>
TASK_DESCRIPTION: <task_description>
IN_PROGRESS_TASKS: <comma-separated task_ids or "none">
CLOSED_TASKS: <comma-separated task_ids or "none">
```

---

## Runtime-Aware Behavior

### ESTIMATED_RUNTIME Fields

The writer may include two optional runtime estimate fields in its rejection payload:

| Field | Type | Required | Description |
|---|---|---|---|
| `ESTIMATED_RUNTIME_RED` | positive integer (seconds) | optional | Estimated runtime of the test in the RED phase (implementation absent) |
| `ESTIMATED_RUNTIME_GREEN` | positive integer (seconds) | optional | Estimated runtime of the test in the GREEN phase (implementation correct) |

These fields are backward-compatible. They may be absent in payloads produced by older writer versions or for non-unit-test contexts.

### Runtime Budget Rule

**Unit test budget ceiling: 10 seconds.** When either `ESTIMATED_RUNTIME_RED` or `ESTIMATED_RUNTIME_GREEN` is present and exceeds 10:

1. The evaluator checks `SUGGESTED_ALTERNATIVE` for a valid restructuring path (e.g., mock `subprocess.run`, patch `time.sleep`, use small fixture data).
2. If a restructuring path exists, the evaluator **must** emit `VERDICT:REVISE` with `REVISION_GUIDANCE` that references the specific runtime value, names the restructuring approach, and explains how it brings the estimate within budget.
3. `VERDICT:CONFIRM` must **not** be issued when a restructuring path is available — a runtime constraint is not an inherent infeasibility.
4. The runtime budget check takes **priority** over standard verdict routing: if a runtime violation with a valid restructuring path is detected, `VERDICT:REVISE` is emitted without proceeding to the CONFIRM/REJECT decision logic.

### Absent-Field Handling (Backward Compatibility)

When both `ESTIMATED_RUNTIME_RED` and `ESTIMATED_RUNTIME_GREEN` are absent from the input:

- The evaluator treats runtime as unknown.
- The evaluator does **not** issue a runtime-based `VERDICT:REVISE`.
- The evaluator proceeds directly to standard verdict decision logic (CONFIRM/REVISE/REJECT based on `REJECTION_REASON`).
- The evaluator does **not** mention runtime budget, estimated runtime, or time in seconds as a reason for the verdict.

---

## Output Formats

### Format 1 — VERDICT:REVISE

Emitted when the evaluator determines the task list needs adjustment due to the rejection. The task description may be ambiguous, or the task scope may overlap with already-in-progress or already-closed tasks in a way that makes a RED test feasible after revision.

```
VERDICT:REVISE
IMPACT_ASSESSMENT:
- TASK_ID: <task_id> | IMPACT_TYPE: <rerun|modify|invalidate>
- TASK_ID: <task_id> | IMPACT_TYPE: <rerun|modify|invalidate>
AFFECTED_TASKS: <comma-separated task_ids>
REVISION_GUIDANCE: <explanation of what to change and why>
```

#### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `VERDICT` | string literal | required | Always `REVISE` for this format. |
| `IMPACT_ASSESSMENT` | array of impact entries | required | One entry per affected sibling task (from `in_progress_tasks` or `closed_tasks`). Must include at least one entry referencing a task from the context envelope. Each entry specifies how that task is affected by the proposed revision. |
| `AFFECTED_TASKS` | string (comma-separated task IDs) | required | Flattened list of all task IDs appearing in `IMPACT_ASSESSMENT`. Parsers use this field for quick lookup without re-parsing the array. |
| `REVISION_GUIDANCE` | string | required | Specific, actionable explanation of what the orchestrator should change: which task descriptions to revise, how to split or merge tasks, or what additional context to supply to the writer on retry. Must reference the original `REJECTION_REASON` from the writer payload. |

#### IMPACT_ASSESSMENT Entry Schema

Each line in `IMPACT_ASSESSMENT` represents one affected task.

| Field | Type | Required | Description |
|---|---|---|---|
| `task_id` | string | required | Ticket ID of the affected sibling task. Must appear in `in_progress_tasks` or `closed_tasks` from the context envelope. |
| `impact_type` | string (enum) | required | How this task is impacted by the revision. One of the values defined below. |

#### `impact_type` Enum Values

| Value | Meaning |
|---|---|
| `rerun` | The task's RED test writer must be re-invoked with the revised description. The task itself is unchanged but needs a fresh writer pass. |
| `modify` | The task description must be updated before the writer is re-invoked. The orchestrator must edit the task ticket and re-run the writer. |
| `invalidate` | The task is superseded or contradicted by the proposed revision. The orchestrator must close or remove the task before proceeding. |

---

### Format 2 — VERDICT:REJECT

Emitted when the evaluator determines the task falls outside the scope of automated TDD evaluation. This verdict is reserved for tasks where no reasonable revision would produce a testable behavioral assertion, and the rejection reason from the writer is well-founded.

```
VERDICT:REJECT
REJECTION_REASON: <explanation>
RECOMMENDED_MODEL: opus
```

#### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `VERDICT` | string literal | required | Always `REJECT` for this format. |
| `REJECTION_REASON` | string | required | Human-readable explanation of why the task cannot be evaluated for automated TDD. Must reference the writer's `REJECTION_REASON` and add evaluator-level justification. Should be specific enough for the orchestrator to surface a useful escalation message to the user. |
| `RECOMMENDED_MODEL` | string literal | required | Always `opus`. The evaluator always recommends opus-level review for tasks that reach a REJECT verdict, given their complexity or ambiguity. |

---

### Format 3 — VERDICT:CONFIRM

Emitted when the evaluator confirms that the writer's rejection is legitimate and the task may proceed without a RED test. The infeasibility must fall into one of the defined categories.

```
VERDICT:CONFIRM
INFEASIBILITY_CATEGORY: <enum value>
JUSTIFICATION: <explanation>
```

#### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `VERDICT` | string literal | required | Always `CONFIRM` for this format. |
| `INFEASIBILITY_CATEGORY` | string (enum) | required | Machine-readable category of infeasibility. Must be one of the enum values defined below. |
| `JUSTIFICATION` | string | required | One to three sentences explaining why this task legitimately cannot have a RED test under TDD policy. Must reference the specific characteristic of the task that makes behavioral testing infeasible or inapplicable. |

#### `INFEASIBILITY_CATEGORY` Enum Values

| Value | Meaning |
|---|---|
| `infrastructure` | The task requires an external system (database, network service, CI runner, third-party API) that is unavailable in the unit test environment and cannot be faithfully mocked. Integration tests may exist elsewhere but are outside the scope of this TDD cycle. |
| `injection` | The task injects behavior into an existing system at a point where the test harness cannot intercept or observe the injected behavior without modifying the system under test. |
| `documentation` | The task produces only documentation, static assets, contract files, or configuration with no runtime behavior. There is no observable system state change or output to assert. |
| `reference_removal` | The task removes a reference, import, or declaration without changing any observable behavior. The absence of a reference is not assertable as a behavioral outcome in a unit test. |

### Canonical parsing prefix

The parser MUST match against:

- `VERDICT:` — prefix match. Any line beginning with `VERDICT:` is the verdict discriminator line. The value following the colon identifies the format: `VERDICT:REVISE`, `VERDICT:REJECT`, or `VERDICT:CONFIRM`. The parser reads the leading `VERDICT:` line first and then processes the remaining fields according to the matched format.

---

## Examples

### Example: VERDICT:REVISE

Writer output (input):
```
TEST_RESULT:rejected
REJECTION_REASON: ambiguous_spec
DESCRIPTION: The task says "update ticket transition logic" but does not specify which transition, from which state, or what the new guard condition should be.
SUGGESTED_ALTERNATIVE: Clarify the expected state machine change in the task description.
```

Orchestrator context envelope (input):
```
TASK_ID: a3f1-bc22
STORY_ID: eedc-c886
EPIC_ID: 20f2-aeeb
TASK_DESCRIPTION: Update ticket transition logic to enforce RED marker guard
IN_PROGRESS_TASKS: b7e2-11dc, c9a0-44fa
CLOSED_TASKS: d1f3-78ab
```

Evaluator output:
```
VERDICT:REVISE
IMPACT_ASSESSMENT:
- TASK_ID: b7e2-11dc | IMPACT_TYPE: rerun
- TASK_ID: d1f3-78ab | IMPACT_TYPE: modify
AFFECTED_TASKS: b7e2-11dc, d1f3-78ab
REVISION_GUIDANCE: The task description must explicitly name the transition being guarded (e.g., "open→closed") and state the condition (e.g., ".test-index contains a [marker] entry"). The ambiguous_spec rejection arose because "update ticket transition logic" provides no deterministic success condition. Revise the task body to include the exact state transition and guard predicate, then re-invoke the writer. Task d1f3-78ab (closed) may have established adjacent transition behavior that conflicts — review its description before revising.
```

---

### Example: VERDICT:REJECT

Writer output (input):
```
TEST_RESULT:rejected
REJECTION_REASON: requires_integration_env
DESCRIPTION: Meaningful testing of the Jira sync bridge requires a live Jira instance or a full API mock, neither of which is available in the unit test environment.
SUGGESTED_ALTERNATIVE: none
```

Evaluator output:
```
VERDICT:REJECT
REJECTION_REASON: The Jira sync bridge interacts with an external API whose contract cannot be faithfully reproduced in a unit test environment. The writer's requires_integration_env rejection is well-founded: the sync behavior depends on Jira response codes, pagination, and field mapping that require a live or staged Jira environment. No revision to the task description would make a unit-level RED test feasible. Escalate to the user for manual integration test planning.
RECOMMENDED_MODEL: opus
```

---

### Example: VERDICT:CONFIRM

Writer output (input):
```
TEST_RESULT:rejected
REJECTION_REASON: no_observable_behavior
DESCRIPTION: This task creates a Markdown contract document. There is no function, script output, or system state change to assert.
SUGGESTED_ALTERNATIVE: Verify acceptance criteria manually: file exists, grep for required section headers.
```

Evaluator output:
```
VERDICT:CONFIRM
INFEASIBILITY_CATEGORY: documentation
JUSTIFICATION: The task produces a Markdown contract file with no runtime behavior. TDD policy explicitly excludes structural tests (file existence, line count) as insufficient for behavioral RED assertions. The writer's no_observable_behavior rejection is correct and falls squarely within the documentation infeasibility category.
```

---

## Failure Contract

If the evaluator:

- exits non-zero,
- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs a malformed block (missing `VERDICT:` prefix, missing required fields, unrecognized `INFEASIBILITY_CATEGORY` or `impact_type` value),

then the parser **must** treat the result as `VERDICT:REJECT` with `REJECTION_REASON: evaluator failed to produce a valid verdict` and escalate to the user for manual resolution. The parser must not silently proceed with TDD setup or bypass the evaluation step.

---

## Relationship to RED_TEST_WRITER_OUTPUT Contract

This contract is downstream of the `RED_TEST_WRITER_OUTPUT` contract (see `plugins/dso/docs/contracts/red-test-writer-output.md`). The evaluator is **only invoked when the writer emits `TEST_RESULT:rejected`**. Two other outcomes bypass the evaluator entirely:

- **`TEST_RESULT:written`** — the orchestrator proceeds directly to TDD setup without requesting a verdict.
- **`TEST_RESULT:no_new_tests_needed`** — the orchestrator accepts this as a success signal without invoking evaluation. This output indicates either that existing tests already cover the behavior (`existing_coverage_sufficient`) or that the task is non-behavioral (`green_classified`). No verdict is needed in either case.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal or renaming) require updating both the evaluator agent definition and this document atomically in the same commit. Additive changes (new optional fields, new enum values) are backward-compatible and do not require a version bump.
