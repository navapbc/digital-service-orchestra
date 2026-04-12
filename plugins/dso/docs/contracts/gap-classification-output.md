# Contract: GAP_CLASSIFICATION Signal

- Signal Name: GAP_CLASSIFICATION
- Status: accepted
- Scope: sprint Phase 7 remediation routing (epic ca76-bb4e)
- Date: 2026-04-04

## Purpose

This document defines the shared output interface for the `GAP_CLASSIFICATION` signal emitted by the gap-classification sub-agent prompt when the sprint completion-verifier identifies failing success criteria (SC). The `/dso:sprint` orchestrator Phase 7 (Remediation) consumes this signal to route each failing SC to the correct remediation path — either brainstorm-level intent re-examination (user-confirmed) or autonomous implementation-plan routing.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and parser stay in sync.

---

## Signal Name

`GAP_CLASSIFICATION`

---

## Emitter

`skills/sprint/prompts/gap-classification.md` — LLM prompt dispatched as a sub-agent during Phase 7 (Remediation) # shim-exempt: internal implementation path reference

The emitter receives the failing SC text, the completion-verifier failure explanation, and relevant code snippets or file paths from the validation context. For each failing SC, the emitter outputs one signal line and then stops. The emitter MUST output exactly one `GAP_CLASSIFICATION:` line per failing SC — no additional commentary, no partial output.

---

## Parser

`skills/sprint/SKILL.md` — Sprint orchestrator Phase 7 (Remediation) # shim-exempt: internal implementation path reference

The parser reads the gap-classification sub-agent output, scans for all `GAP_CLASSIFICATION:` prefixed lines, and routes each failing SC according to the `ROUTING:` field value. When multiple failing SCs exist, each is routed independently based on its classification line.

---

## Input Specification

The gap-classification sub-agent receives the following context for each failing SC:

1. **Failing SC criterion text** — the exact success criterion from the completion-verifier output that was not satisfied.
2. **Completion-verifier failure explanation** — the verifier's human-readable explanation of why the SC failed.
3. **Relevant code snippets or file paths** — file paths, function signatures, or short code excerpts from the validation context that are directly relevant to the failing SC.

The emitter must evaluate all three inputs together before classifying. If any input is absent or empty, the emitter must classify the SC as `intent_gap` (the safer default).

---

## Classification Values

| Classification | Meaning | Routing |
|---|---|---|
| `intent_gap` | The failing SC does not match what the implementation does — the intent is ambiguous or wrong. The SC itself (or its relationship to the existing implementation) requires brainstorm-level re-examination. | `brainstorm` |
| `implementation_gap` | The SC is clear and achievable given the codebase, but not yet fully implemented. The implementation approach is missing or incomplete, not the intent. | `implementation-plan` |

### Distinguishing intent_gap from implementation_gap

| Condition | Classification |
|---|---|
| SC describes a behavior the codebase cannot satisfy without re-designing the intent | `intent_gap` |
| SC is internally contradictory or contradicts another SC in the same story | `intent_gap` |
| SC is ambiguous enough that multiple incompatible interpretations are equally plausible | `intent_gap` |
| SC is clear and the implementation is simply missing or partially complete | `implementation_gap` |
| SC is clear but the implementation approach is incorrect and needs to be replaced | `implementation_gap` |

When in doubt, classify as `intent_gap`. Misclassifying an intent gap as an implementation gap wastes autonomous cycles and risks diverging from user intent. Misclassifying an implementation gap as an intent gap only adds a user confirmation step, which is the safer failure mode.

---

## Signal Format

The emitter outputs one signal line per failing SC:

```
GAP_CLASSIFICATION: <intent_gap|implementation_gap> ROUTING: <brainstorm|implementation-plan> EXPLANATION: <human-readable reason>
```

### Field definitions

| Field | Type | Description |
|---|---|---|
| `GAP_CLASSIFICATION:` | literal prefix | Canonical signal prefix. Required on every line. |
| `<intent_gap\|implementation_gap>` | enum | Classification value. One of the two values defined above. |
| `ROUTING:` | literal label | Required field separator. Must appear after the classification value. |
| `<brainstorm\|implementation-plan>` | enum | Remediation routing target. Must match the classification: `intent_gap` → `brainstorm`; `implementation_gap` → `implementation-plan`. |
| `EXPLANATION:` | literal label | Required field separator. Must appear after the routing value. |
| `<human-readable reason>` | string | Free-text explanation of why the SC was classified as it was. Must reference the specific SC text or failure explanation. Must not be empty. |

### Canonical parsing prefix

The parser MUST match against:

```
GAP_CLASSIFICATION: 
```

(Note the trailing space.) Any line starting with this prefix is a candidate signal line. The parser must then extract the classification, routing, and explanation by splitting on the `ROUTING:` and `EXPLANATION:` labels.

### ROUTING ↔ classification invariant

The `ROUTING:` value is always derivable from the classification value:

- `intent_gap` → `ROUTING: brainstorm`
- `implementation_gap` → `ROUTING: implementation-plan`

If the classification and routing values are inconsistent, the parser must treat the line as malformed and apply the failure contract for that SC.

---

## Routing Behavior and Autonomy Rules

### intent_gap routing — user confirmation REQUIRED

When a SC is classified as `intent_gap`, the sprint orchestrator MUST pause and present the classification and explanation to the user before invoking `/dso:brainstorm`. Autonomous invocation of brainstorm without user confirmation is **prohibited**.

The orchestrator must:

1. Display the failing SC text and the gap-classification explanation.
2. Ask the user to confirm that brainstorm re-examination is desired.
3. Proceed to `/dso:brainstorm` only after explicit user approval.
4. If the user declines, mark the SC as deferred and continue.

### implementation_gap routing — autonomous permitted

When a SC is classified as `implementation_gap`, the sprint orchestrator MAY route autonomously without requiring user confirmation. This is the only classification that permits fully autonomous remediation.

**Clarification — `ROUTING: implementation-plan` is a routing signal label, not a skill invocation.** When the orchestrator receives `ROUTING: implementation-plan`, it proceeds to the **Phase 7 Step 1 remediation flow** (`.claude/scripts/dso ticket create bug`), which creates targeted implementation tasks under the epic. The orchestrator does NOT invoke `/dso:implementation-plan` as a separate skill for `implementation_gap` routing. The label `implementation-plan` identifies the remediation category (implementation work is needed) and permits autonomous action, but the mechanism for delivering that remediation is bug-task creation in Phase 7 Step 1.

---

## REPLAN_ESCALATE Integration

> **Invocation context note**: This section applies when `/dso:implementation-plan` is invoked **directly** (e.g., from the `/dso:sprint` preplanning gate, a cascade replan, or a standalone `implementation-plan` call) — **not** from Phase 7 `implementation_gap` routing. As described in the Routing Behavior section above, Phase 7 `implementation_gap` routing does NOT invoke `/dso:implementation-plan` as a separate skill; it proceeds to Phase 7 Step 1 bug-task creation. The REPLAN_ESCALATE integration below therefore applies only in contexts where `/dso:implementation-plan` is genuinely invoked as a skill.

If `/dso:implementation-plan` returns a `REPLAN_ESCALATE` signal during a direct invocation of the skill (e.g., preplanning gate or cascade replan), the sprint orchestrator MUST:

1. Re-classify that SC as `intent_gap` (overriding the original gap-classification result).
2. Route the SC to brainstorm, following the user confirmation requirement for `intent_gap` routing.
3. Log that the re-classification was triggered by a `REPLAN_ESCALATE` signal from implementation-plan, not the original gap-classification output.

The `REPLAN_ESCALATE` signal from implementation-plan takes precedence over the gap-classification output for that SC. See `docs/contracts/replan-escalate-signal.md` for the REPLAN_ESCALATE contract. # shim-exempt: internal implementation path reference

---

## Failure Contract

If the gap-classification sub-agent output is:

- absent (sub-agent timed out, returned non-zero exit, or produced no output),
- malformed (missing `ROUTING:` or `EXPLANATION:` fields, empty explanation text),
- or contains an unrecognized classification value (not `intent_gap` or `implementation_gap`),

then the parser **must** treat all affected failing SCs as `intent_gap` and route them to brainstorm with user confirmation required. This is the safer default — it requires user confirmation before any autonomous action and avoids misrouting ambiguous signals to autonomous implementation.

The parser must log a warning when the signal is malformed so that silent degradation is detectable in debug output.

---

## Example

### Single failing SC — implementation gap

```
GAP_CLASSIFICATION: implementation_gap ROUTING: implementation-plan EXPLANATION: The SC requires the /api/users endpoint to return paginated results, but the current implementation returns all records. The endpoint exists and the intent is clear; only the pagination logic is missing.
```

### Single failing SC — intent gap

```
GAP_CLASSIFICATION: intent_gap ROUTING: brainstorm EXPLANATION: The SC states "users should see their history in real-time" but the implementation is built on a batch-sync architecture. Real-time delivery would require redesigning the sync layer — this is an intent-level conflict, not an incomplete implementation.
```

### Multiple failing SCs

```
GAP_CLASSIFICATION: implementation_gap ROUTING: implementation-plan EXPLANATION: The CSV export SC is unimplemented; the endpoint stub exists but the serializer is missing.
GAP_CLASSIFICATION: intent_gap ROUTING: brainstorm EXPLANATION: The SC requires offline access, but the current architecture requires active network connectivity at all layers. This is an architectural conflict requiring brainstorm re-examination.
```

---

## Consumers

The following components emit or consume this signal:

| Component | Role | Notes |
|---|---|---|
| `skills/sprint/prompts/gap-classification.md` | Emitter | LLM prompt dispatched as sub-agent in Phase 7 # shim-exempt: internal implementation path reference |
| `skills/sprint/SKILL.md` Phase 7 | Parser | Sprint orchestrator — routes each failing SC based on classification # shim-exempt: internal implementation path reference |
| `docs/contracts/replan-escalate-signal.md` | Related contract | Defines REPLAN_ESCALATE signal that can override implementation_gap classification # shim-exempt: internal implementation path reference |

All implementors must read this contract before writing the emitter prompt or parser logic. Changes to the signal format require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (format changes, field removal, prefix changes, enum value changes) require updating both all emitters and parsers and this document atomically in the same commit. Additive changes that do not affect the canonical parsing prefix are backward-compatible.

### Change Log

- **2026-04-04**: Initial version — defines GAP_CLASSIFICATION signal for gap-classification sub-agent → sprint Phase 7 remediation routing. Establishes intent_gap/implementation_gap classification, user confirmation requirement for intent_gap, REPLAN_ESCALATE integration, and input specification.
