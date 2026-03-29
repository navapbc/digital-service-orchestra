---
last_synced_commit: 2e0f5874eee29a64decfc5ecd139fe947ec993da
---

# Domain Logic Reference

This document describes the functional rules and classification logic of the DSO plugin's core workflows. It reflects the current state of the system.

## Fix-Bug Classification Gate Pipeline

The `/dso:fix-bug` workflow applies a multi-layer classification gate before and after the investigation phase to determine whether autonomous fixing is appropriate.

### Gate Overview

| Gate | Phase | Type | Script | Condition that fires |
|------|-------|------|--------|----------------------|
| 1a — Intent Search | Pre-investigation | primary | `dso:intent-search` agent | Bug contradicts documented system intent |
| 1b — Feature Request Check | Pre-investigation | primary | `gate-1b-feature-request-check.py` | Ticket language matches feature-request patterns |
| 2a — Reversal Check | Post-investigation | primary | `gate-2a-reversal-check.sh` | Fix inverts >50% of a recent committed change |
| 2b — Blast Radius | Post-investigation | modifier | `gate-2b-blast-radius.sh` | File has high fan-in or matches a high-impact convention |
| 2c — Test Regression | Post-investigation | primary | `gate-2c-test-regression-check.py` | Fix removes, weakens, or loosens existing test assertions |
| 2d — Dependency Check | Post-investigation | primary | `gate-2d-dependency-check.sh` | Fix introduces a new dependency not in the project manifest |

All gates output a JSON signal conforming to `plugins/dso/docs/contracts/gate-signal-schema.md`.

### Gate 1a: Intent Search

Dispatches the `dso:intent-search` sub-agent before investigation begins. The agent searches closed/archived tickets, git history, ADRs, design documents, and code comments. Budget is controlled by the `debug.intent_search_budget` config key (default: 20 tool calls).

Three terminal outcomes:

- `intent-aligned` — proceed to investigation without dialog; set `GATE_1A_RESULT="intent-aligned"`
- `intent-contradicting` — auto-close ticket with evidence citation and stop; set `GATE_1A_RESULT="intent-contradicting"`
- `ambiguous` — fall through to Gate 1b; set `GATE_1A_RESULT="ambiguous"`

Gate 1a is bypassed for bugs on the Mechanical Fix Path. `GATE_1A_RESULT` defaults to empty (`""`) when unset.

### Gate 1b: Feature Request Check

Runs only when `GATE_1A_RESULT="ambiguous"`. Skipped for `intent-aligned` and `intent-contradicting`.

Passes ticket title and description as JSON via stdin to `gate-1b-feature-request-check.py`. Detects language patterns such as "doesn't support X", "missing X capability", "add support for". When triggered, prompts the user to confirm whether to close as a feature request or continue to investigation.

### Gate 2a: Reversal Check

Runs after verification (Step 7) before commit (Step 8). `gate-2a-reversal-check.sh` compares working-tree diff against recent commit history. Fires when >50% of a recent commit's changed lines are inverted by the proposed fix.

Suppression: pass `--intent-aligned` flag when `GATE_1A_RESULT="intent-aligned"` — the reversal is expected and intentional.

Recognizes revert-of-revert patterns: when the reversed commit is itself a revert (message matches `^Revert`), the gate does not fire.

### Gate 2b: Blast Radius (modifier)

Runs after verification. `gate-2b-blast-radius.sh` uses ast-grep when available (falls back to grep) to count fan-in and check file-location conventions. The result is a `"modifier"` signal — it appends a plain-language annotation to escalation dialog but never drives a routing decision on its own. Gate 2b cannot block the workflow.

### Gate 2c: Test Regression Analysis

Runs after verification. Reads the working-tree diff of test files via stdin. `gate-2c-test-regression-check.py` fires on:

- Assertion removal
- Specificity reduction (e.g., `assertEqual` to `assertIsNotNone`)
- Assertion count reduction
- Literal-to-variable replacement in assertions
- skip/xfail additions

Does NOT fire on specific-to-specific value swaps (e.g., `assertEqual(x, 42)` to `assertEqual(x, 57)`).

Suppression: pass `--intent-aligned` flag when `GATE_1A_RESULT="intent-aligned"` — the test change corrects an assertion against documented intent.

### Gate 2d: Dependency Check

Runs after verification. `gate-2d-dependency-check.sh` fires when the proposed fix introduces an import or require not already in the project manifest and not used elsewhere in the codebase. Reusing an existing codebase pattern does not trigger this gate.

### Escalation Router

After all gates run, `gate-escalation-router.py` counts primary signals and routes:

| Route | Condition | Action |
|-------|-----------|--------|
| `auto-fix` | 0 primary signals fired, not COMPLEX | Proceed to commit |
| `dialog` | Exactly 1 primary signal | Present 1-2 inline questions; include Gate 2b blast-radius annotation if available |
| `escalate` | 2+ primary signals, or COMPLEX complexity evaluator result | Escalate to `/dso:brainstorm` |

The `--complex` flag forces `route: "escalate"` regardless of signal count.

In non-interactive mode (set by `/dso:debug-everything`): `dialog` path defers as `INTERACTIVITY_DEFERRED` ticket comment and continues as `auto-fix`; `escalate` path defers as a comment and stops without proceeding to Step 8.

### Graceful Degradation

All gates degrade to `triggered: false` with `confidence: "low"` on error (nonzero exit, empty stdout, or unparseable JSON). A gate error is logged as a ticket comment and never blocks the fix workflow. The router defaults to `route: "auto-fix"` on malformed input.

### Gate Signal Contract

All gate scripts emit a 5-field JSON object. Contract: `plugins/dso/docs/contracts/gate-signal-schema.md`.

| Field | Type | Values |
|-------|------|--------|
| `gate_id` | string | `"1a"`, `"1b"`, `"2a"`, `"2b"`, `"2c"`, `"2d"` |
| `triggered` | boolean | `true` fires the gate; `false` does not |
| `signal_type` | string | `"primary"` drives routing; `"modifier"` annotates only |
| `evidence` | string | Non-empty human-readable explanation |
| `confidence` | string | `"high"`, `"medium"`, `"low"` |

### Config Key

`debug.intent_search_budget` — maximum tool calls for Gate 1a's intent-search agent (default: `20`). Configurable in `.claude/dso-config.conf`.
