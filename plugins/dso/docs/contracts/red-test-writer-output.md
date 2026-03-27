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

The emitter receives a story or task description and determines whether a meaningful behavioral RED test can be written. It outputs one of two structured formats on stdout, then exits. Format selection is determined by whether a behaviorally observable, implementable test can be produced.

---

## Parser

`dso:red-test-evaluator` (opus)

The parser invokes the emitter as a sub-agent and reads its output. It inspects the leading `TEST_RESULT:` line to determine which format was emitted, then processes the fields accordingly. On `TEST_RESULT:written`, it evaluates test quality and proceeds with TDD setup. On `TEST_RESULT:rejected`, it routes to the appropriate fallback path based on `REJECTION_REASON`.

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

#### REJECTION_REASON Enum Values

| Value | Meaning |
|---|---|
| `no_observable_behavior` | The task modifies only documentation, static assets, or configuration with no runtime effect. There is no behavior to assert in a unit or integration test. |
| `requires_integration_env` | A meaningful test requires an external system (database, network service, third-party API, CI runner) that is not available in the unit test environment and cannot be mocked without losing behavioral fidelity. |
| `ambiguous_spec` | The task description is insufficiently specific to derive a deterministic assertion. The expected output, side effect, or success condition cannot be inferred from the available information. |
| `structural_only_possible` | Only a structural test (e.g., file exists, line count, import check) can be written — no behavioral assertion is possible. Structural tests are excluded per TDD policy (see CLAUDE.md). |

---

## Example: Success Output

```
TEST_RESULT:written
TEST_FILE: tests/unit/scripts/test_ticket_transition.sh
RED_ASSERTION: ticket transition to closed is blocked when .test-index has RED markers
BEHAVIORAL_JUSTIFICATION: This test invokes the ticket transition script with a real .test-index fixture containing a [marker] entry and asserts exit code 1 with a blocking message. It captures user-visible enforcement behavior rather than internal implementation details.
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

## Exit Code Semantics

| Exit code | Meaning |
|---|---|
| `0` | Success — stdout contains a valid `TEST_RESULT:written` or `TEST_RESULT:rejected` block conforming to this schema |
| non-zero | Failure — stdout may be absent, partial, or malformed |

---

## Failure Contract

If the emitter:

- exits non-zero,
- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs a malformed block (missing `TEST_RESULT:` prefix, missing required fields, unrecognized `REJECTION_REASON` value),

then the parser **must** treat the result as `TEST_RESULT:rejected` with `REJECTION_REASON: ambiguous_spec` and escalate to the orchestrator for manual resolution. The parser must not propagate the failure or silently proceed with TDD setup.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal or renaming) require updating both the emitter agent definition and this document atomically in the same commit. Additive changes (new optional fields, new `REJECTION_REASON` enum values) are backward-compatible and do not require a version bump.
