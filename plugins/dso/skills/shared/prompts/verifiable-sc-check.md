# Verifiable Success-Criterion Check

Applied during SC drafting (Phase 2 Step 2 of `/dso:brainstorm`) to prevent SCs that cannot be resolved within the session that closes the epic.

## Rule

**Session-infeasible SCs are prohibited from the verifiable SC list.**

After drafting each SC, apply this self-check:

> *Can this criterion be evaluated during the session that closes the epic, using only (a) code/artifacts in the repo, (b) CI/test results from the closing PR or merge, or (c) a command that runs in the local dev environment or against a live target the agent can reach?*

If **NO** — because the criterion requires accumulated production telemetry, A/B test results, user adoption over days/weeks, baseline comparisons that don't yet exist, or human dogfooding feedback — then the criterion is **session-infeasible** and must NOT appear as a verifiable closing-session criterion.

"Post-deployment" is **not** the same as "session-infeasible." A criterion gated on a deployment that completes during the closing session, and whose outcome is observable via a deterministic command (`gh pr checks`, `gh run list`, an HTTP probe, a CLI invocation against a live endpoint), IS verifiable.

## Violating examples (session-infeasible)

- "workflow-restart rate drops ≥30% against pre-epic baseline"
- "adoption rate reaches 40% within 30 days"
- "P95 latency improves by 20% over 2-week baseline"
- "users report the new flow is clearer in feedback survey"

## Permitted examples (in-session verifiable, even if post-deployment)

- "After merging to main, all required CI status checks report a green conclusion on the merge commit (verified via `gh run list`)"
- "After deployment, `curl <prod-endpoint>/health` returns 200 and the new field is present in the response body"
- "After enabling the Ruleset, an attempted direct push to main from a clean clone is rejected with the expected error"

If the SC produces a deterministic pass/fail within the closing session, it is verifiable — regardless of whether the verification step happens before or after the merge/deploy.

## Remediation for session-infeasible SCs — pick one

**(a) Rewrite as a verifiable proxy** — instrument the measurement mechanism as the SC.

Example rewrite: "Monitoring dashboard for restart-rate is instrumented and emitting data" (instead of "restart rate drops ≥30%").

**(b) Tag as DEFERRED_MEASUREMENT** — include in the epic description with format:

```
DEFERRED_MEASUREMENT: <criterion text> — measurement plan: <who measures, when, against what baseline>
```

Do NOT count `DEFERRED_MEASUREMENT` items toward the 3–6 verifiable SC quota.

**(c) Route to Closure Checks** — add the criterion to the epic's or story's `## Closure Checks` section when it represents durable end-state intent (something that should remain true after the epic is closed) but cannot be evaluated deterministically during the closing session.

Criteria suitable for Closure Checks: architectural invariants, operational health targets, non-regressing behavioral contracts. Do NOT use Closure Checks for one-time transitional work (setup steps, migration markers, manual verification checkboxes) — those belong in the Done Definitions as explicit closure tasks.

## End-state-only rule (route-to-Closure-Checks litmus)

When deciding between an SC (durable system property) and a Closure Check (one-time transition), apply this canonical litmus test:

> *Could this item be false before the sprint began and true only because of this sprint's specific work? If yes, route to Closure Checks.*

If the item describes a durable property the system will continue to satisfy (independent of which sprint shipped it), it is a valid SC. If the item describes a transition (a state change effected by this sprint's work) it belongs in Closure Checks.

### Accept examples (valid SCs — durable system properties)

- "the system supports OAuth" — present-tense durable capability; remains true after this sprint and indefinitely.
- "the legacy adapter is absent from imports" — present-tense durable invariant; the absence is itself the end-state property.

### Reject examples (route to Closure Checks — past-tense transitions)

- "OAuth has been migrated" — describes a transition, not a durable property. The system either supports OAuth or doesn't; "has been migrated" is the act of this sprint, not a persistent invariant.
- "legacy adapter has been removed" — describes the removal event, not the durable absence. Reframe as "the legacy adapter is absent from imports" to make it a valid SC, or route the removal step to Closure Checks.

### Brainstorm refusal copy

When a participant proposes an SC that fails this litmus test, surface the following refusal:

> "Per the **end-state-only litmus test** in `shared/prompts/verifiable-sc-check.md` — could this item be false before the sprint began and true only because of this sprint's specific work? Yes — so it describes a one-time transition rather than a durable system property. Moving it to `## Closure Checks`. To keep it as an SC, reframe it as ongoing system behavior."

The refusal references the canonical litmus test by name (per epic a03c-d55e-1393-4f27 SC2) so the user can trace the rejection back to the rule.
