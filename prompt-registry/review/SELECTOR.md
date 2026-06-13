# Review Prompt Selector

These are **distinct review prompts** — each applies a different process and
criteria, even where several share the findings-array output schema. They are NOT
interchangeable and are NOT parameterizations of one base. This index helps a
caller pick the right one (or dispatch several in parallel); it does not combine
them.

## Code-diff reviewers

| When you need… | Use |
|----------------|-----|
| Fast, high-signal feedback on a low/medium-risk change (single pass, diff-only) | `review-code-light` |
| A comprehensive pass across all dimensions for a moderate/high-risk change | `review-code-diff` |
| Correctness only, deep (logic, edge cases, error handling, security, efficiency, reference existence) | `review-code-deep-correctness` |
| Test coverage only, deep (presence, quality, edge cases, mocks, environment divergence) | `review-code-deep-verification` |
| Hygiene/design/maintainability only, deep (dead code, naming, SOLID, portability, readability) | `review-code-deep-hygiene` |
| Architectural synthesis of several specialists' findings into one verdict | `review-code-deep-architecture` |
| Performance defects that scale or exhaust resources | `review-code-performance` |
| Test-bloat anti-patterns in test code | `review-test-quality` |
| Aggressive, context-free security detection (high recall) | `review-security-red-team` |
| Context-aware triage of security findings (dismiss/downgrade/sustain) | `review-security-blue-team` |

A **deep review** is the *composition pattern*, not a prompt: run
`review-code-deep-correctness`, `review-code-deep-verification`, and
`review-code-deep-hygiene` in parallel, then `review-code-deep-architecture` to
synthesize. A **security review** runs `review-security-red-team` then
`review-security-blue-team`.

## Non-code reviewers (evaluate other artifacts against standards)

| When you need… | Use |
|----------------|-----|
| Evaluate any artifact against a supplied rubric | `review-against-standards` |
| Find coverage gaps / blind spots in a plan | `red-team-find-gaps` |
| Enumerate production failure scenarios for a spec | `enumerate-failure-scenarios` |
| Readiness review of a plan/design (feasibility/completeness/YAGNI/alignment) | `review-plan-for-readiness` |
| Verify external-integration feasibility with evidence | `assess-integration-feasibility` |
| Check that acceptance criteria are verifiable in-session | `check-criteria-verifiable` |
| Detect scope drift in a change | `detect-scope-drift` |
| Filter a findings set for false positives | `filter-false-positive-findings` |
| Terminal per-finding ruling at a review-loop boundary | `arbitrate-findings-at-cycle-end` |
| Gate a proposed complexity (YAGNI/Rule-of-Three/dependency) | `check-complexity-gate` |
| Score a rendered UI against a design spec | `evaluate-visual-design` |
| Reconcile multiple reviewers' scores + conflicts into a verdict | `reconcile-committee-review` |
| Detect entities a source named that a derived artifact omits | `detect-coverage-omissions` |
