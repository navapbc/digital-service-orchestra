---
last_synced_commit: 3f1ac9d1
---

# Domain Logic Reference

This document describes the functional rules and classification logic of the DSO plugin's core workflows. It reflects the current state of the system.

## Fix-Bug Classification Gate Pipeline

The `/dso:fix-bug` workflow applies a multi-layer classification gate before and after the investigation phase to determine whether autonomous fixing is appropriate.

### Gate Overview

| Gate | Phase | Type | Script | Condition that fires |
|------|-------|------|--------|----------------------|
| 1a — Intent Search | Pre-investigation | primary | `dso:intent-search` agent | Bug contradicts documented system intent |
| 1b — Feature Request Check | Pre-investigation | primary | `feature-request-check.py` | Ticket language matches feature-request patterns |
| 2a — Reversal Check | Post-investigation | primary | `reversal-check.sh` | Fix inverts >50% of a recent committed change |
| 2b — Blast Radius | Post-investigation | modifier | `blast-radius.sh` | File has high fan-in or matches a high-impact convention |
| 2c — Test Regression | Post-investigation | primary | `assertion-regression-check.py` | Fix removes, weakens, or loosens existing test assertions |
| 2d — Dependency Check | Post-investigation | primary | `dependency-check.sh` | Fix introduces a new dependency not in the project manifest |

All gates output a JSON signal conforming to `plugins/dso/docs/contracts/gate-signal-schema.md`.

### Intent Gate: Intent Search

Dispatches the `dso:intent-search` sub-agent before investigation begins. The agent searches closed/archived tickets, git history, ADRs, design documents, and code comments. Budget is controlled by the `debug.intent_search_budget` config key (default: 20 tool calls).

Three terminal outcomes:

- `intent-aligned` — proceed to investigation without dialog; set `INTENT_GATE_RESULT="intent-aligned"`
- `intent-contradicting` — auto-close ticket with evidence citation and stop; set `INTENT_GATE_RESULT="intent-contradicting"`
- `ambiguous` — fall through to Feature-Request Gate; set `INTENT_GATE_RESULT="ambiguous"`

Intent Gate is bypassed for bugs on the Mechanical Fix Path. `INTENT_GATE_RESULT` defaults to empty (`""`) when unset.

### Feature-Request Gate: Feature Request Check

Runs only when `INTENT_GATE_RESULT="ambiguous"`. Skipped for `intent-aligned` and `intent-contradicting`.

Passes ticket title and description as JSON via stdin to `feature-request-check.py`. Detects language patterns such as "doesn't support X", "missing X capability", "add support for". When triggered, prompts the user to confirm whether to close as a feature request or continue to investigation.

### Reversal Gate: Reversal Check

Runs after verification (Step 7) before commit (Step 8). `reversal-check.sh` compares working-tree diff against recent commit history. Fires when >50% of a recent commit's changed lines are inverted by the proposed fix.

Suppression: pass `--intent-aligned` flag when `INTENT_GATE_RESULT="intent-aligned"` — the reversal is expected and intentional.

Recognizes revert-of-revert patterns: when the reversed commit is itself a revert (message matches `^Revert`), the gate does not fire.

### Blast-Radius Gate: Blast Radius (modifier)

Runs after verification. `blast-radius.sh` uses ast-grep when available (falls back to grep) to count fan-in and check file-location conventions. The result is a `"modifier"` signal — it appends a plain-language annotation to escalation dialog but never drives a routing decision on its own. Blast-Radius Gate cannot block the workflow.

### Assertion-Regression Gate: Test Regression Analysis

Runs after verification. Reads the working-tree diff of test files via stdin. `assertion-regression-check.py` fires on:

- Assertion removal
- Specificity reduction (e.g., `assertEqual` to `assertIsNotNone`)
- Assertion count reduction
- Literal-to-variable replacement in assertions
- skip/xfail additions

Does NOT fire on specific-to-specific value swaps (e.g., `assertEqual(x, 42)` to `assertEqual(x, 57)`).

Suppression: pass `--intent-aligned` flag when `INTENT_GATE_RESULT="intent-aligned"` — the test change corrects an assertion against documented intent.

### Dependency Gate: Dependency Check

Runs after verification. `dependency-check.sh` fires when the proposed fix introduces an import or require not already in the project manifest and not used elsewhere in the codebase. Reusing an existing codebase pattern does not trigger this gate.

### Escalation Router

After all gates run, `gate-escalation-router.py` counts primary signals and routes:

| Route | Condition | Action |
|-------|-----------|--------|
| `auto-fix` | 0 primary signals fired, not COMPLEX | Proceed to commit |
| `dialog` | Exactly 1 primary signal | Present 1-2 inline questions; include Blast-Radius Gate blast-radius annotation if available |
| `escalate` | 2+ primary signals, or COMPLEX complexity evaluator result | Escalate to `/dso:brainstorm` |

The `--complex` flag forces `route: "escalate"` regardless of signal count.

In non-interactive mode (set by `/dso:debug-everything`): `dialog` path defers as `INTERACTIVITY_DEFERRED` ticket comment and continues as `auto-fix`; `escalate` path defers as a comment and stops without proceeding to Step 8.

### Graceful Degradation

All gates degrade to `triggered: false` with `confidence: "low"` on error (nonzero exit, empty stdout, or unparseable JSON). A gate error is logged as a ticket comment and never blocks the fix workflow. The router defaults to `route: "auto-fix"` on malformed input.

### Gate Signal Contract

All gate scripts emit a 5-field JSON object. Contract: `plugins/dso/docs/contracts/gate-signal-schema.md`.

| Field | Type | Values |
|-------|------|--------|
| `gate_id` | string | `"intent"`, `"feature_request"`, `"reversal"`, `"blast_radius"`, `"assertion_regression"`, `"dependency"` |
| `triggered` | boolean | `true` fires the gate; `false` does not |
| `signal_type` | string | `"primary"` drives routing; `"modifier"` annotates only |
| `evidence` | string | Non-empty human-readable explanation |
| `confidence` | string | `"high"`, `"medium"`, `"low"` |

### Config Key

`debug.intent_search_budget` — maximum tool calls for Intent Gate's intent-search agent (default: `20`). Configurable in `.claude/dso-config.conf`.

## Brainstorm Planning Pipeline

The `/dso:brainstorm` workflow applies three planning-quality mechanisms before handing an epic to `/dso:preplanning`. All three operate within or after the epic scrutiny pipeline (`plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`).

ADR: `docs/adr/0003-brainstorm-planning-pipeline-hardening.md`

### Follow-on Epic Scrutiny Gate

When brainstorm produces a scope-split (one or more follow-on epics), Phase 3 Step 0 invokes the full scrutiny pipeline on each follow-on epic before returning.

Rules:
- Depth cap: maximum 1. Follow-on epics generated by scrutiny are not themselves scrutinized recursively.
- `request_origin` is set to `scope-split` for the follow-on invocation.
- Part A (pre-strip) runs on each follow-on epic before the pipeline.

The depth cap is a hard invariant — it is not configurable.

### Feasibility-Resolution Gate

The scrutiny pipeline emits a `FEASIBILITY_GAP` annotation (structured signal) when the `dso:feasibility-reviewer` agent finds critical gaps. This replaces the previous spike recommendation (free text).

Resolution flow:
1. Scrutiny pipeline emits `FEASIBILITY_GAP` with gap description.
2. Brainstorm `FEASIBILITY_GAP` handler begins a bounded re-entry loop.
3. Each cycle: brainstorm refines the epic scope and re-runs the feasibility reviewer.
4. If the gap clears within the cycle limit: proceed to preplanning normally.
5. If the cycle limit is reached without resolution: escalate to the user.

When preplanning encounters an unresolved `FEASIBILITY_GAP` (passed forward from brainstorm), it emits `REPLAN_ESCALATE: brainstorm` to route back to brainstorm for resolution.

Config key: `brainstorm.max_feasibility_cycles` (default: `2`).

### Prompt-Alignment Step (Scrutiny Pipeline Step 5)

Step 5 of the scrutiny pipeline detects epics that modify LLM-facing artifacts and dispatches `dso:bot-psychologist` for prompt-alignment review.

Detection: canonical keyword list match against the epic's scope. Matched artifact categories:
- Skill files (`plugins/dso/skills/**`)
- Agent definitions (`plugins/dso/agents/**`)
- Prompt templates (`plugins/dso/docs/prompts/**`, `plugins/dso/skills/shared/prompts/**`)
- Hook behavioral logic (`plugins/dso/hooks/**`)

Doc-only epics are excluded regardless of keyword match.

When a match is found: `matched_keyword` state variable is set; `dso:bot-psychologist` is dispatched via the Agent tool.
When no match: Step 5 exits immediately (no dispatch).

Degradation: when the Agent tool is unavailable (sub-agent context), Step 5 logs a warning and does not block the pipeline.

### Planning-Intelligence Log Fields

Three fields are appended to the planning-intelligence log for observability:

| Field | Type | Description |
|-------|------|-------------|
| `follow_on_scrutiny_depth` | integer | Depth at which follow-on scrutiny was invoked (0 = top-level, 1 = follow-on) |
| `feasibility_cycle_count` | integer | Number of feasibility re-entry cycles consumed |
| `feasibility_gap` | string | Last gap text from the feasibility-resolution loop (empty if no gap) |
| `llm_instruction_signal` | boolean | Whether Step 5 prompt-alignment detection fired |
| `matched_keyword` | string | Keyword that triggered Step 5 dispatch (empty if no match) |

## Gate Reference

### Scope-Drift Gate (Step 7.1)

After fix verification (Phase E Step 4), the `/dso:fix-bug` workflow dispatches the `dso:scope-drift-reviewer` sub-agent at Phase F Step 1 to classify whether the fix drifted beyond the original bug scope.

Classification outcomes:

| Classification | Action |
|----------------|--------|
| `in_scope` | Proceed to commit (Step 8) |
| `ambiguous` | Present inline dialog to the user for confirmation |
| `out_of_scope` | Escalate — block commit, recommend splitting into a separate ticket |

Config key: `scope_drift.enabled` (default: `true`). When `false`, Step 7.1 is skipped entirely.

## Signal Types

### INTENT_CONFLICT

Emitted by the `dso:intent-search` sub-agent (Intent Gate) when callers depend on the current behavior that the bug report wants to change.

| Field | Type | Description |
|-------|------|-------------|
| `behavioral_claim` | string | The behavior the bug report claims is broken |
| `conflicting_callers` | array | List of callers (files, tests, or tickets) that depend on the current behavior |
| `dependency_classification` | string | `hard` (callers will break), `soft` (callers may be affected), or `none` (no conflicts found) |
