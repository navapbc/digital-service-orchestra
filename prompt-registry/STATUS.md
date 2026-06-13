# Prompt Registry — Status & Continuation

This registry decomposes the project's agent, skill, and workflow definitions into
discrete, generic, single-operation prompts. This file tracks coverage, the
remaining source inventory, and the review verdicts.

## Coverage

**33 prompts across 9 categories**, all passing `scripts/validate-registry.sh`
(frontmatter contract, category/directory agreement, self-sufficient body), plus
two lens catalogs that parameterize the base prompts instead of duplicating them.

| Category | Count | Prompts |
|----------|-------|---------|
| classification | 6 | classify-into-taxonomy, assess-complexity-tier, detect-resource-interactions, triage-test-infeasibility, triage-merge-conflicts, score-value-effort |
| review | 7 | review-code-diff, review-against-standards, filter-false-positive-findings, detect-scope-drift, arbitrate-findings-at-cycle-end, check-complexity-gate, evaluate-visual-design (+ LENSES.md) |
| exploration | 4 | locate-code-by-intent, research-question-on-web, search-for-prior-art, decompose-exploration-question |
| generation | 4 | update-project-documentation, write-behavioral-test, write-plain-language-copy, design-ui-for-requirement |
| verification | 4 | verify-claim-second-source, audit-process-compliance, verify-acceptance-criteria, adjudicate-evidence-claim |
| diagnosis | 2 | diagnose-llm-behavior, investigate-bug-root-cause (+ INVESTIGATION-LENSES.md) |
| decomposition | 2 | decompose-work-into-tasks, decompose-into-vertical-slices |
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
  investigator (base).
- Captured as **lenses** (not duplicated): the 12 `code-reviewer-*` tier/specialist
  variants → `review/LENSES.md`; the 9 `investigator-*` variants →
  `diagnosis/INVESTIGATION-LENSES.md`.
- Intentionally not extracted: `bloat-blue-team`/`bloat-resolver`,
  `huge-diff-*`, `architectural-probe`, `inference-incident-curator`,
  `feasibility-reviewer`, `plan-review`, `red-team-reviewer` — these are either
  project-bookkeeping-specific or thin variants of `review-against-standards` /
  `review-code-diff` lenses. Add as lenses if a consumer needs them.

Reusable **shared prompts** captured: prior-art-search, value-effort-scorer,
complexity-gate, exploration-decomposition. The remaining shared files
(behavioral-testing-standard, anti-patterns, prohibited-fix-patterns, doc-router,
named-agent-dispatch, worktree-dispatch, single-agent-integrate,
verifiable-sc-check, ci-skeleton-templates, empirical-validation, scale-inference)
are **guidance standards, not single-operation prompts** — they are best
referenced by prompts (as `standards` inputs to `review-against-standards`) than
turned into standalone operations, per the one-operation-per-prompt rule.

The **skills** (sprint, brainstorm, preplanning, debug-everything, etc.) are
multi-step orchestrations, not single operations. Their embedded discrete
operations are already covered by the agent-derived prompts above; the
orchestration logic itself is intentionally out of scope for a registry of
single-operation prompts.

## Review verdict (interface contracts, separation, reusability, portability, reliability)

- **Interface contracts** — PASS. `validate-registry.sh` enforces required
  frontmatter keys, category/directory agreement, and output-contract +
  constraints sections. 33/33 prompts pass, 0 violations.
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

## Anti-pattern pass (bot-psychologist lens)

Applying the 17-point taxonomy to the full set, the live risk remains **#17
Pink-Elephant (negative-instruction priming)**: the source agents cluster
`DO NOT / NEVER` constraints, and naive extraction carries that framing in.
Mitigation applied uniformly: every `Constraints` section **leads with an
affirmative** "Do exactly one thing: <operation>" before any prohibition, and
hard prohibitions (output format, no-mutation, no nested dispatch) are kept terse
rather than elaborated into failure narratives. Secondary check for **#1
Structured Output Collapse**: every prompt that emits JSON states the exact schema
in-body and marks which fields are required, so an empty-but-valid result is
distinguishable from a truncated one (e.g. `review_completed: true`). No #3
(truncation) or #16 (locality) risk: each prompt is self-contained and restates
its contract in-body.
