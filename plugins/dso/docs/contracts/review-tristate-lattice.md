# Contract: Review-Gate Tristate Decidability Lattice (3ebb DD1)

- Status: active
- Scope: the Goal-1 review gates (review-coverage-invariant.sh, llm-review-dispatch-or-skip.sh) → the merge-to-main orchestrator
- Executable source of truth: `${CLAUDE_PLUGIN_ROOT}/scripts/lib/review-tristate-lib.sh`

This is a **review-specific** contract. It is NOT `enforcement-gate-contract.md` — that contract governs the binary local-vs-`ci-pr` hook-skip decision, a different concern. This contract governs how the Goal-1 **review gates** report a verdict when the answer is not a clean pass.

## Purpose

The Goal-1 review gates answer one question: *is every SHA reaching `main` proven reviewed?* Historically a gate had two outcomes — pass (`0`) or fail (`1`) — and **collapsed two very different failures into `1`**:

- a **genuine review violation** (a SHA with no covering reviewed PR), and
- an **inability to compute the verdict** (a transient API 5xx mid-walk, a parse error, a rate-limit).

Collapsing them forces every mechanical edge case into a hard block that needs manual git surgery, and — worse, in the other direction — tempts a wrapper to map "couldn't compute" to pass (the silent-pass class Option A exists to eliminate). The tristate separates them so the flow can **self-heal mechanical states without ever weakening the review guarantee**.

It generalizes the a85d `precondition-gate.sh` exit-78 mode-gate: `78` ("cannot even start") is the narrowest INDETERMINATE; this lattice adds the "started but could not confirm" case.

## The three values + exit-code contract

| Verdict | Exit | Meaning | Orchestrator action |
|---------|------|---------|---------------------|
| **PASS** | `0` | Every SHA proven reviewed / verdict clean. | Proceed. |
| **FAIL** | `1` | A genuine review violation. **The safe bottom.** | Hard block. **Never** retried or downgraded. |
| **INDETERMINATE** | `75` | The verdict could not be computed (transient/mechanical). | Retry **only** on an observably-transient cause (below); otherwise route to in-channel escalation (DD3). **Never** an automatic PASS. |
| **PRECONDITION_NOT_MET** | `78` | Cannot even start (no `gh`/token/repo). A special INDETERMINATE. | Mode-gated by `precondition-gate.sh` (enforce → block; warn → advisory pass during rollout). |

## Lattice rules (LOAD-BEARING — every consumer must honor all four)

1. **FAIL is the safe bottom.** A genuine violation resolves to FAIL and is never retried, downgraded, or reclassified as transient. When a gate sees both a violation and a compute-error, the violation **dominates** → FAIL.
2. **Indistinguishable → FAIL.** When PASS vs INDETERMINATE cannot be distinguished by evidence at decision time, resolve to FAIL. (`tristate_classify_verdict` coerces an unparseable error-count to ≥1 so it never silently becomes PASS.)
3. **Never PASS on inferred-benign.** An empty diff is never assumed net-zero; an unconfirmable SHA is never assumed reviewed; a 5xx is never assumed "probably fine."
4. **INDETERMINATE retries ONLY on observably-transient cause.** "Observably transient" = the error text itself carries a 5xx status, an explicit rate-limit/`429`, a timeout, a reset/refused connection, or a gateway/service-unavailable marker (`tristate_is_transient_error`). A non-transient INDETERMINATE (404, 401/403, parse error, permission denied) is NOT retried — it resolves to FAIL via the caller's retry budget. The lattice itself never converts INDETERMINATE to PASS under any cause.

## Emitting gates

These existing fail-closed sites emit the tristate (DD1 retrofits them — no new gates were invented):

- `${CLAUDE_PLUGIN_ROOT}/scripts/ci/review-coverage-invariant.sh` — per-SHA coverage walk. `unreviewed>0` → FAIL(1); `errors-only` (could-not-confirm) → INDETERMINATE(75); clean → PASS(0).
- `${CLAUDE_PLUGIN_ROOT}/scripts/llm-review-dispatch-or-skip.sh` — the llm-review dispatch decision. An uncomputable dispatch decision (diff/API uncomputable) → INDETERMINATE(75) rather than a hard-block masquerading as a violation.

`precondition-gate.sh` remains the mode-gate for `78`; INDETERMINATE(`75`) is likewise blocking under enforce (any non-zero is a red required check) — the resilience benefit is in the **orchestrator's interpretation** (retry-on-transient + DD3 escalation), not in letting `75` pass.

## Universal in-channel escalation (DD3)

When a gate resolves to INDETERMINATE **after its bounded transient-retry budget is spent**, it routes the operator to the existing `/dso:fp-recovery` escape valve via `tristate_indeterminate_escalation <gate> <reason> [pr_ref]` — so there is always an in-channel recovery instead of manual git surgery. The helper emits to stderr:

1. a single greppable JSON marker — `INDETERMINATE_ESCALATION: {"gate":...,"reason":...,"next_action":"/dso:fp-recovery ...","recovery":"in-channel"}` — for machine routing **and FP-rate telemetry**, and
2. a human-readable, actionable banner.

**This is a LAST-RESORT surface, by design (anti-friction).** Escalation fires only after transient retries are exhausted; an observably-transient cause self-heals via retry with no human involvement, and a genuine **FAIL never escalates here** (a real violation is fixed, not fp-recovered). A high INDETERMINATE/escalation rate is a **defect signal** pointing at gate brittleness to fix at the source — not normal operation. Current emitting sites: `review-coverage-invariant.sh` (INDETERMINATE-enforce exit), `llm-review-dispatch-or-skip.sh` (marker-absent), and `merge-to-main-pr.sh` (INC-008 resume halt, after one re-fetch).

## Security guardrail (non-negotiable)

The tristate adds resilience for **mechanical/indeterminate** states ONLY. It MUST NEVER auto-resolve "is this code reviewed": a genuine coverage/provenance violation stays FAIL(1). No INDETERMINATE path — retry, escalation, or durable-resume reconstruction — may flip a real review violation to PASS. INDETERMINATE is always non-zero and never silently green.
