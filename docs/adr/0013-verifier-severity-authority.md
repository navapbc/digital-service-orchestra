# Verifier Severity Authority — Named Exception to CLAUDE.md Rule 11

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-05-13

Technical Story: 4100-95a4-07ce-41ab (sue-tribe-skid) — Pre-surfacing reviewer-findings verifier agent (F4 + F5 bundle)

## Context and Problem Statement

CLAUDE.md rule 11 ("Never override reviewer severity") is a load-bearing integrity rule of the DSO review pipeline. Its intent: prevent ad-hoc severity rewrites in `runner.py` or in autonomous-resolution code from quietly downgrading findings to make a review pass. The rule has held off real failure modes (operators or sub-agents rewriting `critical` to `minor` to clear a blocking review).

Epic sue-tribe-skid (F4 + F5 verifier bundle) introduces a new sub-agent — `code-reviewer-verifier` — that is explicitly designed to emit `downgrade-to-minor` and `drop` rulings on findings produced by other reviewers. A literal reading of rule 11 would forbid this sub-agent's existence: it is, by construction, a severity override mechanism.

The problem: the verifier is the documented response to a calibrated failure mode (PR-80 8/11 round-2 invalid; PR #102 hallucinated absence claims; PR #103 cycle thrash). Without it, the autonomous-resolution loop burns up to 5 attempts per invalid finding (rule 11 of CLAUDE.md), introduces unnecessary code complexity when acted upon, and erodes trust in the review pipeline. With it, rule 11 cannot be applied as a blanket prohibition.

A future maintainer reading rule 11 strictly may file a bug, refuse to ship the verifier path, or weaken rule 11 in a way that opens the original failure mode it was written to prevent. We need a documented, narrow exception that preserves rule 11's strength elsewhere while authorizing the verifier's specific authority.

## Decision Drivers

- Rule 11 must remain enforceable for ad-hoc severity rewrites in `runner.py`, autonomous-resolution sub-agents, and any code path not explicitly named by this exception.
- The verifier's authority must be narrow: only `code-reviewer-verifier` rulings flowing through the documented dispatch surface count as exempt.
- The exception must be discoverable by a maintainer reading rule 11 (not buried in a sub-agent file).
- The exception must be revocable: if the verifier later proves untrustworthy (e.g., systematic over-drop on real findings), reverting the exception must not require touching the verifier code itself — only this ADR and the rule-11 cross-reference.
- The exception must distinguish between "verifier emits a ruling" (legitimate) and "verifier ruling is honored by the pipeline" (gated by the documented dispatch surface, not by arbitrary callers).

## Considered Options

- **Approach A: Named exception in CLAUDE.md rule 11, ADR-anchored.** Update rule 11 to add a single sentence: "Exception: `code-reviewer-verifier` rulings (`downgrade-to-minor`, `drop`) flowing through the documented dispatch surface are authorized severity authority — see ADR 0013." The ADR (this file) defines the exception scope, the dispatch surface, and the revocation path.
- **Approach B: Strengthen the verifier's output to a non-severity field.** Have the verifier emit `verifier_action: drop|downgrade|confirm` on a separate schema field, and let the pipeline read both `severity` (reviewer-emitted, never overridden) and `verifier_action` (verifier-emitted, separate). The "severity" never changes; the resolution-loop honors `verifier_action`. Rule 11 is technically unchanged.
- **Approach C: Run the verifier as a reviewer, not an arbiter.** Make the verifier emit findings of its own (rather than rulings on others' findings) and let the resolution loop see two parallel finding streams. Rule 11 is unaffected because no severity is rewritten.
- **Approach D: Soften rule 11 globally.** Rewrite rule 11 to "no override of reviewer severity except where explicitly authorized" without naming a specific authority.

## Decision Outcome

Chosen option: **Approach A — named exception in CLAUDE.md rule 11, ADR-anchored.**

CLAUDE.md rule 11 is updated to add one sentence at the end of its existing text:

> **Exception**: `code-reviewer-verifier` sub-agent rulings (`downgrade-to-minor`, `drop`) flowing through the documented dispatch surface (`plugins/dso/scripts/dso_ci_review/runner.py` for CI; the local `/dso:review` reviewer pipeline) are an authorized severity authority. See `docs/adr/0013-verifier-severity-authority.md`.

The exception scope is explicitly:

1. **Sub-agent identity**: only `code-reviewer-verifier` (the agent file at `plugins/dso/agents/code-reviewer-verifier.md`). No other sub-agent inherits this authority — extracting verifier logic into a different agent forfeits the exception until the ADR is updated.
2. **Ruling enum**: only `downgrade-to-minor` and `drop`. The verifier may emit `confirm` freely; that is not a severity rewrite. Any future ruling the verifier may emit (e.g., a hypothetical `escalate-severity`) is NOT authorized by this exception.
3. **Dispatch surface**: only the documented integration points — the CI dispatch wrapper inside `plugins/dso/scripts/dso_ci_review/runner.py` and the local `/dso:review` reviewer pipeline. A test harness, a debugging script, an ad-hoc CLI invocation, or any third-party caller invoking the verifier directly does NOT inherit the exception; ruling outputs from such callers must NOT be honored as severity rewrites.
4. **Feature-flag gating**: the exception applies only when `review.verifier_enabled=true` (config key default `false`). When the flag is disabled, the verifier dispatch does not run, and no ruling is produced — the question of severity authority does not arise.

### Why Approach A over the alternatives

- **Approach B (separate `verifier_action` field)** preserves rule 11's literal text but creates a parallel severity surface that downstream consumers (autonomous-resolution loop, PR-comment formatter, `review-stats`) must learn to honor. The semantic content is identical to overriding severity — calling it a different field is sleight, not separation. Worse, it doubles the schema surface area and creates a foot-gun where one consumer reads `severity` and another reads `verifier_action` and they disagree about which wins. Rejected.
- **Approach C (verifier emits its own findings)** transforms drops/downgrades into "second opinions" that the resolution loop must decide between. This is significantly more complex than ruling on a single canonical finding stream — and the user-facing behavior (do we show both findings? does the resolution loop see both? do we count both in `review-stats`?) is harder to reason about. Rejected.
- **Approach D (soften rule 11 globally)** removes the integrity guarantee that motivated rule 11 in the first place. A future ad-hoc severity rewrite could appeal to "explicitly authorized" without an actual ADR, defeating the rule's intent. Rejected.

Approach A is narrowly scoped, ADR-anchored (revocable without code changes), and preserves rule 11's deterrent effect on every callsite that is NOT this specific exception.

## Consequences

### Positive

- Rule 11 retains its full deterrent effect on every code path except the named exception.
- The verifier sub-agent can ship without ambiguity about whether its rulings are "allowed."
- A future reviewer of rule 11 sees the exception inline (single sentence) and can read this ADR for the full scope.
- Revocation path is clean: if the verifier proves untrustworthy, this ADR's "Status" changes to `superseded` or `deprecated`, the rule-11 sentence is removed, and `review.verifier_enabled` defaults remain `false` — no verifier code change required to roll back.

### Negative

- Rule 11's text grows by one sentence (a real cost in a frequently-cited rule).
- Future verifier-class sub-agents (e.g., a hypothetical `code-reviewer-arbiter-v2` or `code-reviewer-test-verifier`) require explicit ADR amendments to inherit similar authority; they cannot infer it from this ADR. This is intentional — it forces explicit governance review of every new severity-authority claim.
- Maintainers must remember that ad-hoc invocations of `code-reviewer-verifier` (e.g., from a testing harness) do NOT inherit the exception. A test that asserts the verifier produced `drop` on a fixture is fine; a debugging script that reads the verifier's `drop` ruling and modifies `record-review.sh` output based on it is NOT covered by this exception.

### Neutral

- The exception scope (1–4 above) is enforced by convention, not by code. A future drift would require either an explicit ADR amendment or a violation that this ADR's scope language flags as out-of-bounds.

## Compliance Check

A change is compliant with this ADR if:

1. The severity-modifying ruling originates from `code-reviewer-verifier` (verified by sub-agent identity, e.g., agent file path or routing record).
2. The ruling is one of `downgrade-to-minor` or `drop`.
3. The ruling is consumed by the documented dispatch surface (CI `runner.py` wrapper or local `/dso:review` reviewer pipeline) as part of the post-reviewer / pre-`record-review.sh` integration.
4. `review.verifier_enabled=true` at the time of the ruling.

Any rule-11 candidate violation that fails any of (1)–(4) is NOT covered by this exception and must be evaluated against rule 11's full prohibition.

## Amendment 2026-06-02: `code-reviewer-arbiter` cycle-end rulings

- Amends: this ADR (extends the named exception to a second authority)
- Deciders: @joeoakhart
- Technical Story: b575-ac1c-f720-4839 (Cycle-end arbiter + workflow unification) — gap identified in ticket 7edb-c652-b675-41a4

The `code-reviewer-arbiter` sub-agent (`plugins/dso/agents/code-reviewer-arbiter.md`) emits cycle-end rulings `BLOCK`, `DEFER`, and `DROP`, consumed at the documented dispatch surface inside `plugins/dso/scripts/dso_ci_review/runner.py` (`dispatch_cycle_end_arbiter` → `process_rulings`). As the "Negative consequences" of the original decision anticipated, a new severity-authority claim from a verifier-class agent requires an explicit amendment rather than inheriting the exception — this section is that amendment.

Per-ruling Rule 11 analysis:

- **`BLOCK`** — merge gate only; does NOT modify any finding's severity field. Rule 11 is not triggered; no exception needed.
- **`DEFER`** — continuation signal; does NOT modify any finding's severity field. Rule 11 is not triggered; no exception needed.
- **`DROP`** — removes a finding from consideration. This is severity authority structurally identical to the verifier's `drop`. It is **authorized** under this ADR.

The arbiter's authorized exception scope mirrors the verifier's, with the arbiter's own identity and surface:

1. **Sub-agent identity**: only `code-reviewer-arbiter` (`plugins/dso/agents/code-reviewer-arbiter.md`). No other agent inherits arbiter authority.
2. **Ruling enum**: only `DROP` is a severity authority under this exception. `BLOCK` and `DEFER` are not severity rewrites and fall outside Rule 11 entirely. Any future arbiter ruling that modifies severity is NOT authorized until this ADR is further amended.
3. **Dispatch surface**: only the cycle-end arbiter dispatch in `plugins/dso/scripts/dso_ci_review/runner.py` (`dispatch_cycle_end_arbiter` / `process_rulings`). Ad-hoc or third-party callers invoking the arbiter directly do NOT inherit the exception.
4. **Dispatch gating**: the exception applies only when the arbiter is dispatched through the cycle-end path (`review.max_cycles` reached → `DISPATCH_ARBITER`). When the arbiter does not run, no ruling is produced and the question of severity authority does not arise.

A change is compliant with the arbiter exception if it satisfies (1)–(4) above with `DROP` as the ruling. The Compliance Check criteria for `code-reviewer-verifier` are unchanged; the two authorities are evaluated independently.

## References

- CLAUDE.md, "Critical Rules → Never Do These" rule 11 (after this ADR lands, includes the named-exception sentence pointing here).
- Epic 4100-95a4-07ce-41ab (sue-tribe-skid) — Pre-surfacing reviewer-findings verifier agent (F4 + F5 bundle).
- Epic e7f3-2b45-8d7d-4c68 (grainy-speck-ball) — Code review calibration umbrella.
- Plugin agent file: `plugins/dso/agents/code-reviewer-verifier.md` (authored by epic sue-tribe-skid).
- CI dispatch wrapper: `plugins/dso/scripts/dso_ci_review/runner.py` (modified by epic sue-tribe-skid).
- Local dispatch wrapper: `plugins/dso/skills/.../REVIEW-WORKFLOW.md` (modified by epic sue-tribe-skid).
- Config key: `review.verifier_enabled` (introduced by epic sue-tribe-skid).
