# Completion-Verifier Protocol

Reference doc for the typed-enum P1 gate, deterministic narrative renderer, and closure handoff scripts.

## Verifier output shape

`dso:completion-verifier` emits a JSON object. The machine-readable gate field is:

```
P1: "PASS" | "FAIL" | "DEGRADED"
```

`overall_verdict` is a summary field for human display only — orchestrators MUST read `P1`, not `overall_verdict`. Halt story/epic closure if `P1 ≠ PASS`.

## Scripts

| Script | Role |
|--------|------|
| `check-verifier-verdict.sh <file>` | Machine gate: exits non-zero when `P1 ≠ PASS`; use after verifier dispatch |
| `render-closure-narrative.sh <file>` | Generates the `narrative` field deterministically from verifier output — no LLM prose |
| `check-manifest-completeness.sh` | Validates the closure audit trail (all required artifact fields present) |
| `validate-verifier-output.sh` | Schema-validates raw verifier JSON before downstream consumption |

## Closure Checks validation (Step 2.5)

The verifier reads the `## Closure Checks` section from the ticket description separately from `## Success Criteria`, in Step 2.5 of its evaluation sequence.

- **Absent or empty section**: Step 2.5 is skipped silently. This is the backward-compatible path for tickets created before the v1.2.0 schema migration.
- **Items present, no hooks configured**: each item is evaluated with the default pass (no external validation). The step returns `verdict: PASS`.
- **Items present, `project_closure_hooks` configured** (see `CONFIGURATION-REFERENCE.md`): each configured hook is invoked once per item, receiving `ITEM_TEXT`, `ITEM_SOURCE_TICKET_ID`, and `CLOSURE_TIMESTAMP` as environment variables. If any hook returns a non-pass result, the step returns `verdict: FAIL` or `verdict: WARN` accordingly.
- **Step is one-shot**: unlike the iterative SC coverage gate, Step 2.5 is evaluated once and does not retry. Its result is recorded in the `closure_checks_results` output field with shape `{ "verdict": "PASS|FAIL|WARN|SKIPPED", "items": [...] }`.

The `closure_checks_results` field is included in the verifier's output JSON even when SKIPPED — this allows downstream tooling to distinguish "section was absent" from "section was present and passed".

Design reference: `docs/designs/closure-checks/README.md`.

## Closure handoff protocol

1. Orchestrator dispatches `dso:completion-verifier` at story close and epic close.
2. Verifier writes output to a temp file.
3. Orchestrator runs `validate-verifier-output.sh` to confirm schema, then `check-verifier-verdict.sh` to assert `P1 = PASS`.
4. Orchestrator calls `render-closure-narrative.sh` to produce the human-readable closure narrative.
5. `check-manifest-completeness.sh` runs as a pre-commit gate to confirm audit trail integrity.

Fallback (technical failure only — timeout or unparseable JSON): log the error, escalate to user, do NOT close the ticket.

## Rules summary

- Never read `overall_verdict` as the pass/fail gate — use `P1`.
- Never write the narrative field by hand or via LLM — always call `render-closure-narrative.sh`.
- Inline verification (without dispatching the named verifier agent) is prohibited. See CLAUDE.md rule 20.
