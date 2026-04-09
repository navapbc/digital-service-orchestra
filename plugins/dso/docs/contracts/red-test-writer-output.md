# Contract: Red Test Writer Output Interface

- Signal Name: RED_TEST_WRITER_OUTPUT
- Status: accepted
- Scope: red-test-writer agent (epic 20f2-aeeb)
- Date: 2026-03-26

## Purpose

This document defines the structured output interface between `dso:red-test-writer` (sonnet, emitter) and `dso:red-test-evaluator` (opus, parser). The red-test-writer receives a story or task description and either writes a failing RED test (success path) or rejects the request with a machine-readable reason (failure path).

This contract must be agreed upon before either side is implemented to prevent implicit assumptions and ensure emitter and parser stay in sync.

---

## Signal Name

`RED_TEST_WRITER_OUTPUT`

---

## Emitter

`dso:red-test-writer` (sonnet)

The emitter receives a story or task description and determines whether a meaningful behavioral RED test can be written. It outputs one of three structured formats on stdout, then exits. Format selection is determined by whether a behaviorally observable, implementable test can be produced, whether existing tests already cover the behavior, or whether no test can be written.

- **Format 1 (`TEST_RESULT:written`)** — a new RED test was successfully written.
- **Format 2 (`TEST_RESULT:rejected`)** — no meaningful RED test can be written; the request is infeasible.
- **Format 3 (`TEST_RESULT:no_new_tests_needed`)** — the behavior is already covered by existing tests, or the change is classified as non-behavioral (e.g., documentation). No new test is written; the orchestrator accepts this as a success signal without invoking the evaluator.

---

## Parser

`dso:red-test-evaluator` (opus)

The parser invokes the emitter as a sub-agent and reads its output. It inspects the leading `TEST_RESULT:` line to determine which format was emitted, then processes the fields accordingly. On `TEST_RESULT:written`, it evaluates test quality and proceeds with TDD setup. On `TEST_RESULT:rejected`, it routes to the appropriate fallback path based on `REJECTION_REASON`. On `TEST_RESULT:no_new_tests_needed`, the evaluator is **bypassed entirely** — the orchestrator accepts this as a success signal and proceeds without requesting a verdict.

---

## Output Formats

### Format 1 — Success: TEST_RESULT:written

Emitted when the agent successfully writes a failing RED test that captures observable behavioral intent.

```
TEST_RESULT:written
TEST_FILE: <path>
RED_ASSERTION: <description>
BEHAVIORAL_JUSTIFICATION: <explanation>
```

#### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `TEST_RESULT` | string literal | required | Always `written` for this format. Identifies the success path. |
| `TEST_FILE` | string (file path) | required | Repo-relative path to the test file that was created or modified. Must point to an existing file after the agent completes. Example: `tests/unit/scripts/test_my_feature.sh` |
| `RED_ASSERTION` | string | required | Short description (≤ 120 characters) of what the test asserts. Should describe the expected behavior being tested, not the implementation. Example: `ticket transition to closed is blocked when .test-index contains RED markers` |
| `BEHAVIORAL_JUSTIFICATION` | string | required | One to three sentences explaining why this test captures behavioral intent rather than structural/implementation detail. Must reference the observable outcome being tested (user-visible behavior, data contract, or system state change). |
| `ESTIMATED_RUNTIME_RED` | integer (seconds) | optional | Estimated runtime in the RED phase (before implementation). Must be a positive integer. When provided together with `ESTIMATED_RUNTIME_GREEN`, the runtime budget protocol applies: if either value exceeds 10 seconds for a unit test, the agent must restructure or reject. |
| `ESTIMATED_RUNTIME_GREEN` | integer (seconds) | optional | Estimated runtime in the GREEN phase (after correct implementation). Must be a positive integer. Provided together with `ESTIMATED_RUNTIME_RED` when the agent estimates test duration. |

---

### Format 2 — Failure: TEST_RESULT:rejected

Emitted when the agent determines a meaningful behavioral RED test cannot be written for this task.

```
TEST_RESULT:rejected
REJECTION_REASON: <enum value>
DESCRIPTION: <explanation>
SUGGESTED_ALTERNATIVE: <alternative approach or "none">
```

#### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `TEST_RESULT` | string literal | required | Always `rejected` for this format. Identifies the failure path. |
| `REJECTION_REASON` | string (enum) | required | Machine-readable rejection category. Must be one of the enum values defined below. |
| `DESCRIPTION` | string | required | Human-readable explanation of why the test cannot be written. Should be specific enough for the parser to surface a useful message to the orchestrator. |
| `SUGGESTED_ALTERNATIVE` | string | optional | A concrete alternative validation approach (e.g., manual verification step, integration test approach, contract check), or the literal string `none` if no alternative applies. |
| `RESTRUCTURING_APPROACH` | string | optional | Documents what restructuring approach was considered and why it was ruled out. Present only when rejection is due to a runtime budget concern (e.g., `requires_integration_env` caused by subprocess/sleep that could not be safely mocked). |

#### REJECTION_REASON Enum Values

| Value | Meaning |
|---|---|
| `no_observable_behavior` | The task modifies only documentation, static assets, or configuration with no runtime effect. There is no behavior to assert in a unit or integration test. |
| `requires_integration_env` | A meaningful test requires an external system (database, network service, third-party API, CI runner) that is not available in the unit test environment and cannot be mocked without losing behavioral fidelity. |
| `ambiguous_spec` | The task description is insufficiently specific to derive a deterministic assertion. The expected output, side effect, or success condition cannot be inferred from the available information. |
| `structural_only_possible` | Only a structural test (e.g., file exists, line count, import check) can be written — no behavioral assertion is possible. Structural tests are excluded per TDD policy (see CLAUDE.md). |

---

### Format 3 — Skip: TEST_RESULT:no_new_tests_needed

Emitted when the agent determines that no new test needs to be written — either because existing tests already cover the behavioral intent of this task, or because the task is classified as non-behavioral (green-classified).

```
TEST_RESULT:no_new_tests_needed
REASON: <enum value>
EXISTING_TESTS: <optional, comma-separated test file paths>
```

#### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `TEST_RESULT` | string literal | required | Always `no_new_tests_needed` for this format. Identifies the skip path. |
| `REASON` | string (enum) | required | Machine-readable reason for skipping test creation. Must be one of the enum values defined below. |
| `EXISTING_TESTS` | string (comma-separated file paths) | optional | Repo-relative paths to existing test files that already cover this behavior. Provided when `REASON` is `existing_coverage_sufficient`. Omitted when `REASON` is `green_classified`. |

#### REASON Enum Values

| Value | Meaning |
|---|---|
| `green_classified` | The task is non-behavioral: it produces only documentation, static assets, contract files, or configuration with no runtime behavior. No behavioral RED test is applicable. The orchestrator accepts this without invoking the evaluator. |
| `existing_coverage_sufficient` | Existing tests already cover the behavioral intent of this task. The listed `EXISTING_TESTS` assert the relevant observable outcomes. Writing a new test would be redundant. |

#### Evaluator Bypass

`TEST_RESULT:no_new_tests_needed` **bypasses the evaluator entirely**. The orchestrator accepts it as a success signal — equivalent to a confirmed infeasibility — and proceeds without dispatching `dso:red-test-evaluator`. This is distinct from `TEST_RESULT:rejected`, which always requires evaluator review.

### Canonical parsing prefix

The parser MUST match against:

- `TEST_RESULT:` — prefix match. Any line beginning with `TEST_RESULT:` is the output discriminator line. The value following the colon identifies the format: `TEST_RESULT:written`, `TEST_RESULT:rejected`, or `TEST_RESULT:no_new_tests_needed`. The parser reads the leading `TEST_RESULT:` line first and then processes the remaining fields according to the matched format.

---

## Example: Success Output

```
TEST_RESULT:written
TEST_FILE: tests/unit/scripts/test_ticket_transition.sh
RED_ASSERTION: ticket transition to closed is blocked when .test-index has RED markers
BEHAVIORAL_JUSTIFICATION: This test invokes the ticket transition script with a real .test-index fixture containing a [marker] entry and asserts exit code 1 with a blocking message. It captures user-visible enforcement behavior rather than internal implementation details.
ESTIMATED_RUNTIME_RED: 1
ESTIMATED_RUNTIME_GREEN: 1
```

---

## Example: Failure Output

```
TEST_RESULT:rejected
REJECTION_REASON: no_observable_behavior
DESCRIPTION: This task creates a Markdown contract document with no runtime behavior. There is no function, script output, or system state change to assert in a test.
SUGGESTED_ALTERNATIVE: Verify acceptance criteria manually: file exists, grep for required section headers.
```

---

## Example: no_new_tests_needed — green_classified

```
TEST_RESULT:no_new_tests_needed
REASON: green_classified
```

## Example: no_new_tests_needed — existing_coverage_sufficient

```
TEST_RESULT:no_new_tests_needed
REASON: existing_coverage_sufficient
EXISTING_TESTS: tests/unit/scripts/test_ticket_transition.sh, tests/unit/scripts/test_ticket_close_guard.sh
```

---

## Exit Code Semantics

| Exit code | Meaning |
|---|---|
| `0` | Success — stdout contains a valid `TEST_RESULT:written`, `TEST_RESULT:rejected`, or `TEST_RESULT:no_new_tests_needed` block conforming to this schema |
| non-zero | Failure — stdout may be absent, partial, or malformed |

---

## Failure Contract

If the emitter:

- exits non-zero,
- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs a malformed block (missing `TEST_RESULT:` prefix, missing required fields, unrecognized `REJECTION_REASON` or `REASON` value),

then the parser **must** treat the result as `TEST_RESULT:rejected` with `REJECTION_REASON: ambiguous_spec` and escalate to the orchestrator for manual resolution. The parser must not propagate the failure or silently proceed with TDD setup.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal or renaming) require updating both the emitter agent definition and this document atomically in the same commit. Additive changes (new optional fields, new `REJECTION_REASON` enum values) are backward-compatible and do not require a version bump.
