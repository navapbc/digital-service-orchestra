# Contract: CONFIDENT/UNCERTAIN Confidence Signal

- Signal Name: CONFIDENT / UNCERTAIN
- Status: accepted
- Scope: task-execution sub-agents → sprint Phase 5 post-batch processing (epic 74f8-7d2a)
- Date: 2026-04-04

## Purpose

This document defines the shared output interface for the `CONFIDENT` / `UNCERTAIN` confidence signals emitted by implementation sub-agents at the end of each task execution. The `/dso:sprint` orchestrator Phase 5 (Post-Batch Processing) consumes these signals to identify tasks that completed with `STATUS:pass` but where the agent had low confidence in the result — enabling targeted escalation before closing tasks.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and parser stay in sync.

---

## Signal Name

`CONFIDENT` / `UNCERTAIN`

---

## Emitter

`skills/sprint/prompts/task-execution.md` — Implementation sub-agents dispatched during Phase 4 batch execution # shim-exempt: internal implementation path reference

The emitter evaluates its own confidence in the completed work immediately before producing its final report. It emits exactly one confidence signal line per task execution, positioned alongside (not instead of) the `STATUS:` and `FILES_MODIFIED:` output lines. The emitter MUST emit one of the two signals — a missing confidence line is treated as `UNCERTAIN` by the parser (fail-safe default).

---

## Parser

`skills/sprint/SKILL.md` — Sprint orchestrator Phase 5 post-batch processing # shim-exempt: internal implementation path reference

The parser reads each task sub-agent result, scans for the confidence signal line, and records the signal per task. UNCERTAIN signals on `STATUS:pass` tasks are tracked as a count per story (not per task ID) so that task replacement cannot reset the counter.

---

## Signal Format

The emitter outputs the confidence signal as a single standalone line in the final report block:

```
CONFIDENT
```

or

```
UNCERTAIN:<reason>
```

### Field definitions

| Field | Type | Description |
|---|---|---|
| `CONFIDENT` | literal keyword | Single keyword, no payload. Indicates the agent has high confidence that the task is correctly and completely implemented, all acceptance criteria are genuinely satisfied, and no significant edge cases were left unaddressed. |
| `UNCERTAIN:<reason>` | keyword + free-text | Keyword followed immediately by a colon and free-text reason (no space before reason). Indicates the agent lacks confidence in the result — the task may be partially complete, acceptance criteria may be satisfied only on the happy path, or the agent encountered ambiguity it could not resolve. The `<reason>` text must not be empty. |

### Canonical parsing prefix

The parser MUST match against:

- `CONFIDENT` — exact keyword match on the full line (no prefix character). A line that is exactly `CONFIDENT` is a valid CONFIDENT signal.
- `UNCERTAIN:` — prefix match. Any line beginning with `UNCERTAIN:` is a valid UNCERTAIN signal. The reason text follows immediately after the colon.

Parsers must not treat `UNCERTAIN` without a colon as a valid UNCERTAIN signal — a bare `UNCERTAIN` with no colon is malformed.

### Output position

The confidence signal appears as a line in the sub-agent's final report block, alongside the `STATUS:`, `FILES_MODIFIED:`, `FILES_CREATED:`, `TESTS:`, `AC_RESULTS:`, `TASKS_CREATED:`, and `DISCOVERIES_WRITTEN:` lines. The ordering within the block is not significant to the parser.

### Example payloads

**CONFIDENT signal:**
```
STATUS: pass
FILES_MODIFIED: ${CLAUDE_PLUGIN_ROOT}/docs/contracts/confidence-signal.md
FILES_CREATED: none
TESTS: 0 passed, 0 failed
AC_RESULTS: contract file exists: pass, defines both signals: pass, specifies emitter and parser: pass
TASKS_CREATED: none
DISCOVERIES_WRITTEN: no
CONFIDENT
```

**UNCERTAIN signal:**
```
STATUS: pass
FILES_MODIFIED: ${CLAUDE_PLUGIN_ROOT}/scripts/record-review.sh # shim-exempt: example payload in contract doc
FILES_CREATED: none
TESTS: 3 passed, 0 failed
AC_RESULTS: enforces tier: pass, rejects downgrade: pass
TASKS_CREATED: none
DISCOVERIES_WRITTEN: no
UNCERTAIN:The tier enforcement logic passes all unit tests but I was unable to exercise the full E2E path with a real reviewer invocation. The happy-path behavior is covered, but the failure-mode branches may have gaps.
```

---

## Relationship to STATUS

The confidence signal is **orthogonal to `STATUS:`**. The two signals measure different things:

| Combination | Meaning | Orchestrator action |
|---|---|---|
| `STATUS: pass` + `CONFIDENT` | Task complete and agent is confident in correctness. | Normal closure — proceed with commit and task close. |
| `STATUS: pass` + `UNCERTAIN:<reason>` | Task nominally complete but agent is uncertain about correctness, completeness, or edge-case coverage. | Count toward story's UNCERTAIN threshold. At threshold: pause and surface to user before closure. |
| `STATUS: fail` + `CONFIDENT` | Task failed and the failure is well-understood. | Normal failure handling — revert to open. Confidence signal does not affect the failure path. |
| `STATUS: fail` + `UNCERTAIN:<reason>` | Task failed and the failure cause is itself unclear. | Normal failure handling — revert to open. The UNCERTAIN reason may help diagnose the failure but does not change routing. |

Key rule: **`STATUS:fail` does NOT automatically imply `UNCERTAIN`** — an agent may fail a task while fully understanding why. Conversely, **`STATUS:pass` + `UNCERTAIN` is valid and meaningful** — an agent may complete a task while doubting its own implementation.

Only `STATUS:pass` + `UNCERTAIN` signals count toward the double-failure threshold (see Tracking Semantics below). `STATUS:fail` tasks already trigger revert-to-open in Phase 5 Step 9 through the normal failure path.

---

## Tracking Semantics

UNCERTAIN signal counts are tracked **per story, not per task ID**. This prevents the counter from resetting when a failed task is replaced with a new task ID during Phase 5 Step 9 revert-to-open + re-dispatch.

The orchestrator maintains a running count of `STATUS:pass` + `UNCERTAIN` signals per story across all batch iterations for that story. When the count reaches **2** (the double-failure threshold), the orchestrator MUST pause and surface the uncertainty to the user before proceeding to close or commit the affected tasks.

**Why per-story, not per-task**: If a task is reverted to open and reissued under a new task ID (normal revert-to-open behavior), the new task ID would start with a count of 0 if tracking were per-task. Tracking per story ensures that recurring uncertainty on the same story accumulates, which is the intended behavior.

---

## Conditions for Emitting UNCERTAIN

An emitter SHOULD emit `UNCERTAIN` when any of the following is true:

1. The implementation satisfies acceptance criteria tests but the agent suspects untested edge cases exist that could cause failures in production.
2. The agent had to make assumptions about intent because the task description was ambiguous, and the chosen interpretation may not match the requester's intent.
3. The implementation uses an approach the agent was not confident about (e.g., a workaround, an unfamiliar API, a pattern not established in the codebase).
4. Acceptance criteria `Verify:` commands passed but the agent suspects the verifications are insufficient to confirm correctness.
5. The task involved modifying a high-complexity, high-centrality file and the agent cannot rule out unintended side effects.

An emitter SHOULD emit `CONFIDENT` when the agent has completed the task, all acceptance criteria passed, and none of the above conditions apply.

When in doubt, emit `UNCERTAIN` with a reason. A false UNCERTAIN (agent was actually correct) adds a user confirmation step, which is the safer failure mode. A false CONFIDENT (agent was actually wrong) silently closes a defective task.

---

## Failure Contract

If the confidence signal is:

- absent (the sub-agent did not emit either `CONFIDENT` or `UNCERTAIN:`),
- malformed (`UNCERTAIN` with no colon, `UNCERTAIN:` with empty reason text),
- or unrecognized (any other value on the confidence line),

then the parser MUST treat it as `UNCERTAIN` with the reason `"no confidence signal emitted"`. This is the fail-safe default — absent or malformed confidence signals are treated pessimistically.

The parser must log a warning when the signal is absent or malformed so that silent degradation is detectable in debug output.

---

## Consumers

The following components emit or consume this signal:

| Component | Role | Notes |
|---|---|---|
| `skills/sprint/prompts/task-execution.md` | Emitter | All implementation sub-agents dispatched via this prompt must emit a confidence signal line # shim-exempt: internal implementation path reference |
| `skills/sprint/SKILL.md` Phase 5 | Parser | Sprint orchestrator — reads and tracks UNCERTAIN count per story; triggers user pause at threshold # shim-exempt: internal implementation path reference |

All implementors must read this contract before modifying the task-execution prompt or Phase 5 parser logic. Changes to the signal format require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (format changes, field removal, keyword changes) require updating both all emitters and parsers and this document atomically in the same commit. Additive changes that do not affect the canonical parsing keywords are backward-compatible.

### Change Log

- **2026-04-04**: Initial version — defines CONFIDENT/UNCERTAIN confidence signal interface for task-execution sub-agents → sprint Phase 5 post-batch processing. Establishes orthogonal relationship with STATUS:, per-story UNCERTAIN tracking semantics, and fail-safe defaults for absent/malformed signals.
