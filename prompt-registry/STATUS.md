# Prompt Registry — Status & Continuation

This registry is being built incrementally by decomposing the project's agent,
skill, and workflow definitions into discrete, generic, single-operation prompts.
This file tracks what is done, what remains, and the review verdicts so the work
can resume in a later pass without re-deriving context.

## Coverage so far

16 prompts across 9 categories, all passing
`scripts/validate-registry.sh` (frontmatter contract, category/dir match,
self-sufficient body):

| Category | Prompts |
|----------|---------|
| classification | classify-into-taxonomy, assess-complexity-tier, detect-resource-interactions |
| review | review-code-diff, review-against-standards |
| exploration | locate-code-by-intent, research-question-on-web |
| generation | update-project-documentation, write-behavioral-test |
| verification | verify-claim-second-source, audit-process-compliance |
| diagnosis | diagnose-llm-behavior, investigate-bug-root-cause |
| decomposition | decompose-work-into-tasks |
| transformation | repair-output-to-schema |
| planning | select-implementation-approach |

Every category named in the original objective is represented, and each prompt
is genericized: no project name, ticket CLI, file layout, or sibling-prompt
reference. Domain specifics arrive through declared inputs only.

## Source inventory remaining

The project ships **53 agent definitions** (`plugins/dso/agents/*.md`),
**41 skills** (`plugins/dso/skills/*/`), and a set of workflow/prompt
fragments (`plugins/dso/docs/workflows/`, `plugins/dso/skills/shared/prompts/`).
The prompts above were extracted from a representative subset. High-value
sources not yet decomposed, grouped by the registry category they map to:

- **review**: `code-reviewer-{light,deep-arch,deep-correctness,deep-hygiene,
  deep-verification,performance,security-red-team,security-blue-team,
  test-quality,arbiter}`, `plan-review`, `scope-drift-reviewer`,
  `feasibility-reviewer`, `red-team-reviewer`, `bloat-blue-team`,
  `huge-diff-reviewer-*`. Most share the universal review base already captured
  in `review-code-diff`; each delta is a *lens* (a focus checklist + a
  `review_focus` input) rather than a new contract — prefer adding a
  `review_focus` parameter over minting near-duplicate prompts.
- **classification**: `bug-classifier`, `complexity-evaluator` (captured),
  `cross-epic-interaction-classifier` (captured), `blue-team-filter`,
  `red-test-evaluator` (verdict classifier).
- **exploration**: `investigator-{basic,intermediate,advanced-*,escalated-*}`,
  `architectural-probe`, `intent-search` (captured as locate-code-by-intent).
  The investigator tiers share `investigate-bug-root-cause`'s base; deltas are
  depth/technique lenses.
- **generation**: `doc-writer` (captured), `gov-copy-writer` (plain-language
  rewrite — maps to transformation), `ui-designer`, `red-test-writer`
  (captured), `ci-skeleton-templates`.
- **verification**: `completion-verifier` (typed-enum P-gate verdict),
  `code-reviewer-verifier`, `second-source-verifier` (captured),
  `verification-remediation-planner`.
- **decomposition**: `story-decomposer`, `task-decomposer` (captured).
- **planning**: `approach-proposer`, `approach-decision-maker` (captured),
  `conflict-analyzer`, `complexity-gate`.
- **diagnosis**: `bot-psychologist` (captured), `inference-incident-curator`,
  `schema-correction` (captured as transformation/repair-output-to-schema).

When resuming: prefer **parameterizing an existing prompt** (e.g. a
`review_focus` or `investigation_depth` input) over creating a near-duplicate.
The base contracts are already in the registry; most remaining sources are
lenses on those bases.

## Review verdict (interface contracts, separation, reusability, portability, reliability)

- **Interface contracts** — PASS. `validate-registry.sh` enforces the required
  frontmatter keys, category/directory agreement, and the presence of an output
  contract + constraints section in every body. 0 violations across 16 files.
- **Separation of concerns** — PASS. Each prompt performs one named operation;
  review prompts emit findings (no fixing), verification prompts decide (no
  modifying), investigation prompts diagnose (no implementing).
- **Reusability** — PASS. Contracts are parameterized (taxonomy, severity scale,
  tier vocabulary, standards, doc schema are all inputs).
- **Portability** — PASS. No DSO scripts, ticket CLI, worktree/orchestrator
  mechanics, or sibling-prompt references survive. Domain terms appear only as
  illustrative examples in `when_to_use`.
- **Reliability** — PASS. Output shapes are machine-checkable; classifiers define
  closed value sets with an escape value; reviews/verifications use evidence-or-
  abstain discipline (absence is INCONCLUSIVE/FAIL, never inferred).

## Anti-pattern pass (bot-psychologist lens)

Applying the 17-point taxonomy to the registry, the relevant risk is **#17
Pink-Elephant (negative-instruction priming)**: the source agents lean on
clustered `DO NOT / NEVER` constraints, and naive extraction would carry that
framing in. Mitigation applied across all prompts: every `Constraints` section
**leads with an affirmative specification** ("Do exactly one thing: <operation>")
before any prohibition, and hard prohibitions (output format, no-mutation, no
nested dispatch) are kept terse per the bot-psychologist Step-5 modifier rather
than elaborated into failure narratives. No other taxonomy mode (truncation,
locality, schema collapse) applies, because each prompt is self-contained and
restates its output contract in-body.

Residual refinement for a future pass: audit the longest prompt
(`review/review-code-diff`) for #8 Verbosity — its severity carve-outs are
faithful to the source but could be compressed once the lens-parameterization
above lets several review variants share one body.
