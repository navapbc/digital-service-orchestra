# Verifiable Success-Criterion Check

Applied during SC drafting (Phase 2 Step 2 of `/dso:brainstorm`) to prevent post-deployment measurement criteria from polluting the verifiable SC list.

## Rule

**Post-deployment measurement SCs are prohibited from the verifiable SC list.**

After drafting each SC, apply this self-check:

> *Can this criterion be evaluated during the sprint session using only (a) code/artifacts in the repo, (b) CI test results, or (c) a command that runs in the local dev environment?*

If **NO** — because the criterion requires live production telemetry, A/B test accumulation, user adoption rates, rate comparisons against a pre-epic baseline, time-series measurements that don't exist yet, or user behavior observed post-deployment — then the criterion is a **post-deployment measurement SC** and must NOT appear as a verifiable sprint-session criterion.

## Violating examples

- "workflow-restart rate drops ≥30% against pre-epic baseline"
- "adoption rate reaches 40% within 30 days"
- "P95 latency improves by 20% over 2-week baseline"

## Remediation — pick one

**(a) Rewrite as a verifiable proxy** — instrument the measurement mechanism as the SC.

Example rewrite: "Monitoring dashboard for restart-rate is instrumented and emitting data" (instead of "restart rate drops ≥30%").

**(b) Tag as DEFERRED_MEASUREMENT** — include in the epic description with format:

```
DEFERRED_MEASUREMENT: <criterion text> — measurement plan: <who measures, when, against what baseline>
```

Do NOT count `DEFERRED_MEASUREMENT` items toward the 3–6 verifiable SC quota.
