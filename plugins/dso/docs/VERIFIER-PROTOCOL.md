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
- **Step is one-shot**: unlike the iterative SC coverage gate, Step 2.5 is evaluated once and does not retry. Its result is recorded in the `closure_checks_results` output field, which is an **array** of per-item results — each entry has `{ "item": "<verbatim closure check text>", "verdict": "PASS|FAIL|WARN|SKIPPED", "evidence_found": "<what was verified>" }`. See `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md` for the canonical schema.

The `closure_checks_results` array is empty (`[]`) when the ticket body has no `## Closure Checks` section OR when `project_closure_hooks` is absent/empty (backward-compat: absent section = no items = pass). `WARN` verdicts appear in `closure_checks_results` but do NOT block closure and are NOT propagated to `criteria_results` — only `FAIL` (severity `block`) does.

Design reference: `docs/designs/closure-checks/README.md`.

## Closure handoff protocol

1. Orchestrator dispatches `dso:completion-verifier` at story close and epic close.
2. Verifier writes output to a temp file.
3. Orchestrator runs `validate-verifier-output.sh` to confirm schema, then `check-verifier-verdict.sh` to assert `P1 = PASS`.
4. Orchestrator calls `render-closure-narrative.sh` to produce the human-readable closure narrative.
5. `check-manifest-completeness.sh` runs as a pre-commit gate to confirm audit trail integrity.

Fallback (technical failure only — timeout or unparseable JSON): log the error, escalate to user, do NOT close the ticket.

## Deferred-evidence obligations (Step 4.5, story only)

When a story DD's evidence text defers validation to a future post-merge act,
the verifier MUST create a rollout obligation ticket per
`docs/contracts/obligation-ticket-schema.md` and only emit `P1=PASS` when
ticket creation succeeds.

**Trigger regex** (case-insensitive):

```
\b(deferred|defer)\s+to\s+(operator|rollout|post.?merge|operator.?execution)\b
```

The verifier output gains an `obligations_created` array of created ticket
ids. If `ticket create` fails for any required obligation, `P1=FAIL` is
emitted with `criteria_results.evidence_found` set to
`obligation_creation_failed: <reason>`.

Background: bug `1761-21ca-cb74-44a6` — epic 4047 closed `P1=PASS` with four
DDs marked "deferred to operator execution per runbook", but the operator
role does not run pre-merge, so deferral was effectively skip. This protocol
makes deferral structurally trackable instead of silently lost.

A separate auditor — `${CLAUDE_PLUGIN_ROOT}/scripts/dso_reconciler/check-obligations.sh`
— iterates open obligations and files a P1 bug parented to the obligation's
parent story when the deadline passes.

## Rules summary

- Never read `overall_verdict` as the pass/fail gate — use `P1`.
- Never write the narrative field by hand or via LLM — always call `render-closure-narrative.sh`.
- Inline verification (without dispatching the named verifier agent) is prohibited. See CLAUDE.md `rule:dispatch-verifier`.
