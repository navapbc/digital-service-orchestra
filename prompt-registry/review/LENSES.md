# Review Lenses

A **lens** is a focus parameter for `review-code-diff`, not a separate prompt.
The base prompt's contract (findings array, severity rubric, categories,
verify-before-assert discipline) is identical across lenses; only the focus
checklist and the scoring emphasis change. Pass the chosen lens as a
`review_focus` input to `review-code-diff` and apply the corresponding checklist
below. This keeps one contract and avoids a dozen near-duplicate prompts.

Lenses are composable: a "deep" review runs several specialist lenses in parallel
and a synthesis lens consolidates their findings.

## Depth lenses (how much to look)

| Lens | Focus | Notes |
|------|-------|-------|
| `light` | Single pass, highest-signal checklist only | Fast feedback on low-to-medium-risk changes. Diff-only caller checks; do not run full repo-wide verification. |
| `standard` | All five categories comprehensively | Moderate-to-high-risk changes. The default. |
| `deep` | Dispatch specialist lenses in parallel, then synthesize | High-blast-radius changes. Use `synthesis` to consolidate. |

## Specialist lenses (what to look at)

| Lens | Restrict findings to | Severity emphasis |
|------|----------------------|-------------------|
| `correctness` | Edge cases, error handling, security, efficiency, wrong results | Bias toward `critical`/`important` for reachable defects |
| `verification` | Test presence, quality, edge-case coverage, mock correctness | Missing/incorrect coverage of the changed behavior |
| `hygiene` | Dead code, naming anti-patterns, unnecessary complexity, structure | Mostly `minor`; escalate only on ambiguity-causing names |
| `design` | Coupling, cohesion, interfaces, SOLID, abstraction quality | Escalate when the design choice raises future-change cost materially |
| `maintainability` | Readability, comments, organization, cognitive load | Mostly `minor` |
| `performance` | Scaling failures, resource exhaustion, hot-path cost | Bright-line: unbounded growth / O(n²) on user-scaled input → high severity |
| `test-quality` | Test bloat: change-detector, implementation-coupled, tautological, source-grepping, existence-only assertions | Apply the behavioral-testing standard; philosophy disagreements cap at `minor` |

## Security lenses (two-stage)

Security uses a red-team/blue-team pair to control false positives:

| Lens | Role |
|------|------|
| `security-red-team` | Aggressive detection of security concerns, run **without** task context so plausibility is not suppressed. Emits candidate findings. |
| `security-blue-team` | Context-aware triage of the red-team output with dismiss / downgrade / sustain authority. Run after red-team; feed its output through `filter-false-positive-findings` semantics. |

## Synthesis lens

| Lens | Role |
|------|------|
| `synthesis` | Consolidate specialist findings into one verdict, assess systemic risk across dimensions, and de-duplicate overlapping findings. Pair with `arbitrate-findings-at-cycle-end` at the end of a review loop. |

## How to invoke

1. Choose depth (`light` / `standard` / `deep`).
2. For `deep`, run `correctness`, `verification`, `hygiene`/`design`, and (if
   warranted) `performance`, `test-quality`, and the security pair as parallel
   `review-code-diff` calls, each with its `review_focus`.
3. Consolidate with the `synthesis` lens, then (at a loop boundary) rule with
   `arbitrate-findings-at-cycle-end`.
