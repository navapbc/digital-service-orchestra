# Investigation Lenses

A **lens** is a depth/technique parameter for `investigate-bug-root-cause`, not a
separate prompt. The base contract (structured localization, five-whys, empirical
validation, typed result) is identical; the lens sets how deep to go and which
investigative technique to apply. Pass the chosen lens as an
`investigation_depth` / `investigation_technique` input and apply the
corresponding guidance below.

## Depth lenses (how hard to look)

| Lens | Depth | Output emphasis |
|------|-------|-----------------|
| `basic` | Single-pass localization + five whys | One proposed fix; low-complexity bugs. |
| `intermediate` | Dependency-ordered reading, intermediate-variable tracking, hypothesis elimination | ≥ 2 ranked fixes with tradeoffs. |
| `advanced` | Two technique lenses in parallel (see below), convergence-checked | Code-evidence and/or change-history hypothesis sets; the caller computes convergence across the two. |
| `escalated` | Deepest application of a technique lens, with extra authority | Used when advanced did not converge. |

## Technique lenses (how to look)

| Lens | Technique | Extra authority at `escalated` |
|------|-----------|--------------------------------|
| `code-tracer` | Execution-path tracing, dependency-ordered analysis, state/concurrency inspection | Deeper path tracing across modules |
| `historical` | Timeline reconstruction, fault-tree analysis, commit bisection | Bisection beyond the advanced depth |
| `empirical` | Run the code; test dynamic hypotheses by execution | **May add temporary logging/instrumentation; has veto over theory-only consensus; MUST confirm the instrumentation was reverted** |
| `web` | Error-pattern analysis, dependency changelogs, upstream-issue correlation | Web search/fetch authorized for known-issue correlation |

## Composition

- `advanced` runs two technique lenses (typically `code-tracer` + `historical`)
  in parallel; compare their `ROOT_CAUSE` fields for convergence. Diverging root
  causes signal the need to escalate.
- The `empirical` lens is the tie-breaker: it tests dynamic hypotheses by
  execution rather than source-reading, and its veto authority exists because a
  statically-plausible root cause can still be wrong at runtime. It must always
  confirm any temporary instrumentation was reverted before reporting.

## How to invoke

1. Pick depth by complexity (`basic` → `escalated`).
2. Pick the technique that matches the failure signature: reproducible logic bug
   → `code-tracer`; "worked before" regression → `historical`; behavior only
   observable at runtime → `empirical`; third-party/upstream suspicion → `web`.
3. Apply the base `investigate-bug-root-cause` contract with the lens guidance,
   and (for `advanced`/`escalated`) reconcile multiple lenses' results before
   proposing a fix.
