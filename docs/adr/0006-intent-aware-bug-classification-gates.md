# ADR 0003: Intent-Aware Bug Classification Gates for /dso:fix-bug

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-03-29

Technical Story: a5f2-1811 (Intent-Aware Bug Classification Gates)

## Context and Problem Statement

The `/dso:fix-bug` workflow previously began investigation immediately after ticket classification and scoring. This meant bugs that contradicted documented system intent, described missing capabilities (feature requests), reversed recent deliberate commits, introduced new dependencies, or weakened test coverage could all be autonomously fixed without any assessment of whether fixing was appropriate. Practitioners had to manually review each bug before invoking the workflow to catch these cases — a burden that scaled poorly as the number of open bugs grew.

After Epic 2df5-72cb restructured `/dso:debug-everything` to invoke `fix-bug` at the orchestrator level (enabling sub-agent dispatch from within `fix-bug`), a classification gate became technically feasible. The question was how to automate the routing assessment reliably without adding false-positive friction.

## Decision

Add a three-layer classification gate integrated into the `/dso:fix-bug` workflow. The gate runs before investigation begins (Layer 1: pre-investigation) and after the fix is proposed (Layer 2: post-investigation). Layer 3 re-uses the existing complexity evaluator already present in the workflow.

### Gate Architecture

**Layer 1 — Pre-investigation**

Gate 1a (Intent Search): A timeboxed sub-agent (`dso:intent-search`) searches closed/archived tickets, git history, ADRs, design documents, and code comments to classify the bug as `intent-aligned`, `intent-contradicting`, or `ambiguous`. The search budget is configurable via `debug.intent_search_budget` (default: 20 tool calls).

- `intent-aligned` — bug is a genuine defect; proceed to investigation without dialog.
- `intent-contradicting` — behavior is intentionally designed; auto-close the ticket with evidence citation and stop.
- `ambiguous` — insufficient evidence; fall through to Gate 1b.

Gate 1b (Feature Request Check): Runs only when Gate 1a returns `ambiguous`. The script `gate-1b-feature-request-check.py` applies linguistic pattern matching against the ticket title and description. If feature-request language is detected (e.g., "doesn't support/handle X", "missing X capability"), the gate fires and prompts the user for classification confirmation before investigation continues.

**Layer 2 — Post-investigation (after fix is proposed and verified)**

Gate 2a (Reversal Check): `gate-2a-reversal-check.sh` compares the proposed fix diff against recent commit history. If more than 50% of a recent commit's changed lines are inverted by the fix, the gate fires. Revert-of-revert patterns are recognized and do not fire the gate. When Gate 1a returned `intent-aligned`, the `--intent-aligned` flag suppresses Gate 2a (the reversal is expected).

Gate 2b (Blast Radius — modifier only): `gate-2b-blast-radius.sh` estimates the fix's blast radius via file-location conventions and fan-in count (ast-grep when available, grep fallback). The result is a plain-language annotation appended to escalation dialog — it never adds a primary signal count. Gate 2b cannot block the fix workflow on its own.

Gate 2c (Test Regression Analysis): `gate-2c-test-regression-check.py` reads the working-tree diff of test files via stdin and detects assertion removal, specificity reduction (e.g., `assertEqual` to `assertIsNotNone`), assertion count reduction, or skip/xfail additions. A specific-to-specific value swap (e.g., `assertEqual(x, 42)` to `assertEqual(x, 57)`) does not fire the gate. When Gate 1a returned `intent-aligned`, the `--intent-aligned` flag suppresses Gate 2c (the test change corrects an assertion against documented intent).

Gate 2d (Dependency Check): `gate-2d-dependency-check.sh` detects whether the proposed fix introduces runtime or dev dependencies not already in the project manifest or used elsewhere in the codebase. Reusing an existing codebase pattern does not trigger this gate.

**Layer 3 — Complexity evaluator (existing)**

The existing complexity evaluator (Step 4.5) is unchanged. A `COMPLEX` classification always escalates to `/dso:brainstorm` regardless of primary signal count.

### Escalation Router

After all gates run, `gate-escalation-router.py` counts primary signals and routes the workflow:

| Route | Condition | Action |
|-------|-----------|--------|
| `auto-fix` | 0 primary signals (and not COMPLEX) | Proceed to commit without dialog |
| `dialog` | Exactly 1 primary signal | Prompt 1-2 inline questions; include blast-radius annotation if available |
| `escalate` | 2+ primary signals, or COMPLEX | Escalate to `/dso:brainstorm` for epic treatment |

All gates degrade gracefully on error: a failed gate emits `triggered: false` with `confidence: "low"` and never blocks the workflow.

### Shared Contract

All gate scripts emit a JSON object conforming to `plugins/dso/docs/contracts/gate-signal-schema.md` (5 required fields: `gate_id`, `triggered`, `signal_type`, `evidence`, `confidence`). The escalation router is the sole consumer of these signals.

## Consequences

### Positive

- Bugs that contradict documented intent are auto-closed without requiring manual practitioner review.
- Feature requests masquerading as bugs are caught before investigation begins, preventing wasted investigation effort.
- Test-weakening fixes and dependency-introducing fixes surface for user confirmation before commit rather than silently entering the codebase.
- Fixes requiring epic-level treatment (multi-signal or COMPLEX) are consistently routed to `/dso:brainstorm` instead of being committed as narrow patches.
- All gates fail open (non-blocking on error), so infrastructure failures never prevent legitimate bug investigations.

### Negative

- Gate 1a introduces sub-agent dispatch latency before investigation begins. The `debug.intent_search_budget` config key caps this at 20 tool calls by default.
- Gate 2a and Gate 2c add post-investigation steps that extend the fix-bug cycle time on flagged bugs.
- The blast-radius analysis (Gate 2b) requires ast-grep (`sg` binary) for highest accuracy; environments without ast-grep fall back to grep-based counting with reduced precision. Note: `gate-2b-blast-radius.sh` currently checks `command -v ast-grep` (the package name) rather than `command -v sg` (the CLI binary); both resolve to the same tool when installed via the standard package. New integrations should use `sg` per the convention in CLAUDE.md.

### Neutral

- The gate-signal-schema contract requires all future gate implementors to conform to the 5-field JSON schema. Breaking changes require atomic updates to all emitters.
- The `--intent-aligned` suppression flag creates a dependency from Gate 2a/2c on Gate 1a's outcome. The `GATE_1A_RESULT` variable must be set correctly for suppression to work; mechanical fix path bugs that bypass Step 1.5 receive a guard default (`GATE_1A_RESULT=${GATE_1A_RESULT:-}`).

---

### Revision 2026-04-27 — script paths and names updated

The gate scripts referenced throughout this ADR have been relocated under `plugins/dso/scripts/fix-bug/` and renamed to drop step-number prefixes (which were brittle against future renumbering). The decisions, rationale, and JSON wire-format `gate_id` values are unchanged. Only file paths/names changed:

- `plugins/dso/scripts/gate-1b-feature-request-check.py` → `plugins/dso/scripts/fix-bug/feature-request-check.py`
- `plugins/dso/scripts/gate-2a-reversal-check.sh` → `plugins/dso/scripts/fix-bug/reversal-check.sh`
- `plugins/dso/scripts/gate-2b-blast-radius.sh` → `plugins/dso/scripts/fix-bug/blast-radius.sh`
- `plugins/dso/scripts/gate-2c-test-regression-check.py` → `plugins/dso/scripts/fix-bug/assertion-regression-check.py`
- `plugins/dso/scripts/gate-2d-dependency-check.sh` → `plugins/dso/scripts/fix-bug/dependency-check.sh`
- `plugins/dso/scripts/gate-escalation-router.py` → `plugins/dso/scripts/fix-bug/gate-escalation-router.py`

Wire-format `gate_id` JSON values (`"1b"`, `"2a"`, `"2b"`, `"2c"`, `"2d"`) remain unchanged — these are opaque identifiers consumed by the escalation router and remain stable across the rename.

### Revision 2026-04-27 — gate rename (display + wire format)

Display names and JSON wire-format `gate_id` values renamed from arbitrary numeric labels (`Gate 1a`, `Gate 1b`, `Gate 2a–d`) to descriptive names. The decisions, rationale, ordering, and behavior in this ADR are unchanged.

Display name and `gate_id` mapping:

- Gate 1a → **Intent Gate** (`gate_id: "intent"`)
- Gate 1b → **Feature-Request Gate** (`gate_id: "feature_request"`)
- Gate 2a → **Reversal Gate** (`gate_id: "reversal"`)
- Gate 2b → **Blast-Radius Gate** (`gate_id: "blast_radius"`)
- Gate 2c → **Assertion-Regression Gate** (`gate_id: "assertion_regression"`)
- Gate 2d → **Dependency Gate** (`gate_id: "dependency"`)
- "Gate 2 family" → "Post-Fix Gate Family"

Bash env-var prefixes followed the same pattern: `GATE_1A_RESULT` → `INTENT_GATE_RESULT`, `GATE_1B_OUTPUT` → `FEATURE_REQUEST_GATE_OUTPUT`, `GATE_2A_*` → `REVERSAL_GATE_*`, etc.

Driver: after Phase 7 renumbering of fix-bug SKILL.md (Step 1.5 → Phase B Step 1, etc.), the gate IDs were the only remaining label tied to old step numbering. Renaming completes the brittleness fix and makes the wire format self-describing.
