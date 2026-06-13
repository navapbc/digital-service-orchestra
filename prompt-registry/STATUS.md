# Prompt Registry — Status & Continuation

This registry decomposes the project's agent, skill, and workflow definitions into
discrete, generic, single-operation prompts. This file tracks coverage, the
remaining source inventory, and the review verdicts.

## Coverage

**45 prompts across 10 categories**, all passing `scripts/validate-registry.sh`
(frontmatter contract, category/directory agreement, self-sufficient body), plus
two lens catalogs that parameterize the base prompts instead of duplicating them.

| Category | Count | Prompts |
|----------|-------|---------|
| classification | 6 | classify-into-taxonomy, assess-complexity-tier, detect-resource-interactions, triage-test-infeasibility, triage-merge-conflicts, score-value-effort |
| review | 12 | review-code-diff, review-against-standards, filter-false-positive-findings, detect-scope-drift, arbitrate-findings-at-cycle-end, check-complexity-gate, evaluate-visual-design, red-team-find-gaps, assess-integration-feasibility, review-plan-for-readiness, check-criteria-verifiable, enumerate-failure-scenarios (+ LENSES.md) |
| exploration | 5 | locate-code-by-intent, research-question-on-web, search-for-prior-art, decompose-exploration-question, scan-for-pattern-occurrences |
| generation | 5 | update-project-documentation, write-behavioral-test, write-plain-language-copy, design-ui-for-requirement, scaffold-integration-harness |
| verification | 5 | verify-claim-second-source, audit-process-compliance, verify-acceptance-criteria, adjudicate-evidence-claim, verify-fix-end-to-end |
| remediation | 3 | resolve-review-findings, apply-fix-across-occurrences, resolve-merge-conflicts |
| diagnosis | 2 | diagnose-llm-behavior, investigate-bug-root-cause (+ INVESTIGATION-LENSES.md, incl. cluster mode) |
| decomposition | 3 | decompose-work-into-tasks, decompose-into-vertical-slices, split-large-change-for-review |
| planning | 3 | select-implementation-approach, propose-implementation-approaches, classify-remediation-scope |
| transformation | 1 | repair-output-to-schema |

## Lens approach

The project's many reviewer variants (~12) and investigator variants (9) are not
separate operations — they are **lenses** (focus/depth/technique) on two base
prompts. Rather than mint near-duplicate files, the registry captures them as
parameter values:

- `review/LENSES.md` — depth (light/standard/deep), specialist (correctness,
  verification, hygiene, design, maintainability, performance, test-quality),
  security red/blue pair, and synthesis lenses for `review-code-diff` via a
  `review_focus` input.
- `diagnosis/INVESTIGATION-LENSES.md` — depth (basic→escalated) and technique
  (code-tracer/historical/empirical/web) lenses for `investigate-bug-root-cause`
  via `investigation_depth` / `investigation_technique` inputs.

This is the deliberate reuse choice flagged in the original plan: parameterize the
base contract, don't duplicate it.

## Source inventory — coverage status

All **53 agent definitions** map to a registry prompt or a lens:

- Captured as distinct prompts: bug-classifier, complexity-evaluator,
  cross-epic-interaction-classifier, bot-psychologist, code-reviewer (base),
  code-reviewer-arbiter, code-reviewer-verifier, blue-team-filter,
  scope-drift-reviewer, red-test-evaluator, completion-verifier,
  second-source-verifier, task-decomposer, story-decomposer, doc-writer,
  gov-copy-writer, ui-designer, visual-evaluator, red-test-writer,
  schema-correction, approach-proposer, approach-decision-maker,
  conflict-analyzer, verification-remediation-planner, intent-search,
  investigator (base), feasibility-reviewer, plan-review, red-team-reviewer,
  architectural-probe.
- Captured as **lenses** (not duplicated): the 12 `code-reviewer-*` tier/specialist
  variants → `review/LENSES.md`; the 9 `investigator-*` variants →
  `diagnosis/INVESTIGATION-LENSES.md`.
- Intentionally not extracted: `bloat-blue-team`/`bloat-resolver` and
  `huge-diff-*` (lenses of `review-against-standards` / `review-code-diff` — the
  bloat pair maps to a review + a transformation that the existing prompts cover
  with a `review_focus`), and `inference-incident-curator` (project-bookkeeping
  specific). Add as lenses if a consumer needs them.

Reusable **shared prompts** captured: prior-art-search, value-effort-scorer,
complexity-gate, exploration-decomposition, large-diff-splitting-guide,
verifiable-sc-check. The remaining shared files
(behavioral-testing-standard, anti-patterns, prohibited-fix-patterns, doc-router,
named-agent-dispatch, worktree-dispatch, single-agent-integrate,
ci-skeleton-templates, empirical-validation, scale-inference)
are **guidance standards, not single-operation prompts** — they are best
referenced by prompts (as `standards` inputs to `review-against-standards`) than
turned into standalone operations, per the one-operation-per-prompt rule.

The **skills** (sprint, brainstorm, preplanning, debug-everything, etc.) are
multi-step orchestrations, not single operations — the orchestration logic itself
is out of scope. However, several skills carry discrete sub-agent prompts under
`skills/*/prompts/` and `docs/workflows/prompts/` that ARE single operations. A
coverage sweep (role-frame + output-contract signal detection across all 431
`plugins/dso/**/*.md`, minus already-captured sources) surfaced these; manual
verification extracted six genuinely-new ones: `resolve-review-findings`,
`apply-fix-across-occurrences`, `resolve-merge-conflicts`,
`scan-for-pattern-occurrences`, `verify-fix-end-to-end`, and
`enumerate-failure-scenarios`. Three candidates were verified **not** new and were
documented rather than duplicated: `cluster-investigation` (a cluster mode of
`investigate-bug-root-cause`, added to INVESTIGATION-LENSES.md), `gap-analysis`
(`red-team-find-gaps` with an implementation-task gap taxonomy), and `gha-scanner`
(orchestration + ticket-bookkeeping coupled; thin generic kernel). The
`agents/ci/*` and `docs/workflows/prompts/reviewer-delta-*` files are CI/delta
renderings of reviewers already captured via `review-code-diff` + LENSES.

To make this repeatable, a future pass should add a `source_ref:` frontmatter
field (origin path / `lens:<base>` / `excluded:<reason>`) and a
`coverage-report.sh` that prints source files with operation signals and no
inbound `source_ref` — the live miss list.

## Review verdict (interface contracts, separation, reusability, portability, reliability)

- **Interface contracts** — PASS. `validate-registry.sh` enforces required
  frontmatter keys, category/directory agreement, and output-contract +
  constraints sections. 45/45 prompts pass, 0 violations.
- **Separation of concerns** — PASS. One named operation per prompt; reviews emit
  findings (no fixing), verifications decide (no modifying), diagnoses find root
  cause (no implementing), decompositions draft (no creating).
- **Reusability** — PASS. Contracts are parameterized (taxonomy, severity scale,
  tier vocabulary, standards, doc schema, precedence ladder, lens) and the
  reviewer/investigator families collapse onto two parameterized bases.
- **Portability** — PASS. No project scripts, ticket CLI, or
  worktree/orchestrator mechanics survive in prompt bodies; domain terms appear
  only as illustrative examples or in this meta-doc.
- **Reliability** — PASS. Output shapes are machine-checkable; classifiers define
  closed value sets with an escape value; reviews/verifications use
  evidence-or-abstain discipline (absence is INCONCLUSIVE/FAIL, never inferred);
  fail-open vs. fail-closed is stated explicitly per prompt.

## Anti-pattern pass (bot-psychologist lens) — completed

Three independent bot-psychologist audits were run over the full set (general
agents primed with the 17-point taxonomy, KERNEL minimal-fix, the 20% rule, and
the affirmative-framing audit), each instructed to prefer precision over quantity
and to quote-and-fix. They returned ~20 high-confidence findings (no invented
ones); the legitimate ones were applied as minimal fixes (commit "Refine prompts
per bot-psychologist anti-pattern audit"):

- **Contract drift** — the README `outputs.format` vocabulary was expanded to
  match registry usage (`yaml`, `structured-block`, `structured-artifact`);
  `detect-resource-interactions` now declares its failure shape;
  `adjudicate-evidence-claim` honors its overridable `rulings` input and fixed a
  hardcoded example boolean.
- **Positional bias / instruction locality** — `review-code-diff` restates the
  no-`critical`-on-unverified-out-of-diff-claim rule at the severity-assignment
  site; `assess-complexity-tier` co-locates the confidence cap with its
  definition.
- **#17 Pink-Elephant / #8 Verbosity** — clustered `DO NOT` blocks in
  `diagnose-llm-behavior`, `repair-output-to-schema`, `write-behavioral-test`,
  and `arbitrate-findings-at-cycle-end` were consolidated into affirmative
  specifications, keeping hard prohibitions terse.
- **Portability** — `write-plain-language-copy` dropped government/federal
  framing; the two base prompts were decoupled from the lens-catalog filenames
  (enumerated lens values remain inline).

Findings deliberately **not** applied (with rationale): the `structured-block`
format was kept (and the vocabulary widened instead) since it is an established
convention across the registry; `classify-into-taxonomy`'s escape-value
restatement was kept as sanctioned reinforcement of a hard final-format
constraint (20% rule); `filter-false-positive-findings`'s reject criteria were
kept since they are the operative filter definition and already lead with the
affirmative survive-condition.

After refinement, all 45 prompts pass `validate-registry.sh` and a portability
sweep shows no residual domain leaks in prompt bodies.

A fourth bot-psychologist audit was run over the six later-added prompts
(red-team-find-gaps, assess-integration-feasibility, review-plan-for-readiness,
check-criteria-verifiable, scaffold-integration-harness,
split-large-change-for-review). It found four legitimate defects, all fixed:
`red-team-find-gaps` carried a fix-action `type` field that conflicted with its
find-only operation and was undeclared in the schema (dropped; `taxonomy_category`
is the gap type, severity enum added to the schema); and two review prompts used
`major` instead of the registry's shared `important` severity (aligned).

A fifth audit covered the six coverage-sweep prompts (resolve-review-findings,
apply-fix-across-occurrences, resolve-merge-conflicts, scan-for-pattern-occurrences,
verify-fix-end-to-end, enumerate-failure-scenarios). It confirmed all six are
genuinely distinct from existing prompts (no duplicates) and found two
structured-output-collapse issues, both fixed: `verify-fix-end-to-end` emitted a
`SKIPPED` tier not present in its output contract (added to the schema), and
`resolve-review-findings` did not specify when `TESTING_MODES: n/a` applies
(clarified to "only when zero Fix actions were taken").
