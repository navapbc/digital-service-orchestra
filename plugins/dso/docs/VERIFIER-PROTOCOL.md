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
