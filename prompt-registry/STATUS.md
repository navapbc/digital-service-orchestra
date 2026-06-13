# Prompt Registry — Status & Continuation

This registry decomposes the project's agent, skill, and workflow definitions into
discrete, generic, single-operation prompts.

## Distinctness principle (load-bearing)

**Prompts that share an output contract but apply a different process or criteria
are DISTINCT and each gets its own file.** A correctness checklist, a security
red-team sweep, and a performance analysis all emit a findings array — they are
three different operations, not one with a parameter. Likewise an execution-path
bug trace vs. a timeline-reconstruction trace. Two prompts are the *same*
operation only when their process AND criteria are identical (differing solely in
dispatch mechanics or model). The registry does not consolidate distinct
processes; it captures each one. Routing across related prompts is handled by
`SELECTOR.md` index docs, which point to the prompts without combining them.

## Coverage

**73 prompts across 10 categories**, all passing `scripts/validate-registry.sh`.

| Category | Count |
|----------|-------|
| review | 26 |
| diagnosis | 10 |
| classification | 7 |
| exploration | 6 |
| generation | 6 |
| verification | 6 |
| planning | 4 |
| remediation | 4 |
| decomposition | 3 |
| transformation | 1 |

Selectors: `review/SELECTOR.md` and `diagnosis/SELECTOR.md` index the related
review and investigation prompts and describe composition patterns (deep review =
run the specialists in parallel then synthesize; security = red-team then
blue-team; advanced/escalated investigation = parallel lenses then empirical
confirm).

## Distinct families captured (the reversal)

An earlier pass wrongly collapsed two families into one base prompt each plus a
"lens" catalog. That destroyed the per-variant IP and has been reversed — every
variant is now its own self-contained prompt:

- **Reviewers (10):** review-code-light, review-code-diff (standard),
  review-code-performance, review-test-quality, review-code-deep-correctness,
  review-code-deep-hygiene, review-code-deep-verification,
  review-code-deep-architecture, review-security-red-team,
  review-security-blue-team.
- **Investigators (9):** investigate-bug-root-cause (basic/universal),
  investigate-bug-intermediate, investigate-bug-advanced-code-tracer,
  investigate-bug-advanced-historical, investigate-bug-escalated-code-tracer,
  investigate-bug-escalated-empirical, investigate-bug-escalated-history,
  investigate-bug-escalated-web, investigate-bug-cluster.

Other distinct operations extracted in the same pass: review-refactor-conformance,
analyze-task-list-gaps, filter-failure-scenarios, triage-bloat-candidates,
apply-bloat-removals, curate-incident-corpus, scan-ci-for-failures.

## Genuine duplicates NOT separated (per the distinctness rule)

These are the *same* operation (identical process AND criteria) and are
intentionally not given their own prompt — separating them would be duplication,
which the rule forbids just as it forbids consolidating distinct ones:

- `agents/ci/code-reviewer-*` — identical criteria to the top-level reviewers;
  they differ only in dispatch harness (CI has no tool access). Same operation,
  different I/O channel.
- `huge-diff-reviewer-light` / `huge-diff-reviewer-standard` — explicitly
  "identical behavior to code-reviewer-light/standard but on opus." Same process,
  different model/context.
- `investigator-intermediate-fallback` — explicitly "investigation depth and
  quality match investigator-intermediate; only the persona framing differs."
- `docs/workflows/prompts/reviewer-delta-*` and `investigator-delta-*` — build
  fragments composed into the agents above, not separate operations.

If a consumer needs a model/harness variant, it selects the matching prompt and
overrides `model_hint` / tool availability.

## Source inventory

All 53 top-level agents are now individual prompts (or, for the four duplicates
above, the canonical prompt they duplicate). Reusable shared prompts captured:
prior-art-search, value-effort-scorer, complexity-gate, exploration-decomposition,
large-diff-splitting-guide, verifiable-sc-check. Skill-embedded sub-agent prompts
captured across both a file-level coverage sweep and a section-level scan. The
remaining shared files (behavioral-testing-standard, anti-patterns,
prohibited-fix-patterns, doc-router, named-agent-dispatch, worktree-dispatch,
single-agent-integrate, ci-skeleton-templates, empirical-validation,
scale-inference) are guidance *standards* consumed as `standards` inputs, not
single operations. SKILL.md bodies are multi-step orchestrations.

To make coverage auditable rather than estimated, a future pass should add a
`source_ref:` frontmatter field and a `coverage-report.sh` that lists
operation-signal source files with no inbound `source_ref`.

## Review verdict (interface contracts, separation, reusability, portability, reliability)

- **Interface contracts** — PASS. `validate-registry.sh`: 73/73, 0 violations.
- **Separation of concerns** — PASS. One named operation per prompt; distinct
  processes are distinct files.
- **Reusability** — PASS. Contracts parameterized; domain coupling genericized.
- **Portability** — PASS. No project scripts/CLI/mechanics survive in prompt
  bodies; project-specific criteria (banned tools, locking, encapsulated
  subsystems) genericized while preserving the substantive check.
- **Reliability** — PASS. Machine-checkable output shapes; closed value sets;
  evidence-or-abstain discipline; explicit fail-open vs. fail-closed.

## Anti-pattern audits (bot-psychologist)

Seven independent bot-psychologist audits have run across the registry (17-point
taxonomy, KERNEL minimal-fix, 20% rule, affirmative framing). The seventh covered
the ~24 prompts added during the de-consolidation and, crucially, **confirmed
every de-consolidated prompt is genuinely distinct in process AND criteria — no
accidental duplicates** (the closest pairs — test-quality vs deep-verification,
advanced vs escalated lenses, the two scenario/finding filters — were each
verified non-duplicate). Fixes applied across the audits include: expanded
`outputs.format` vocabulary (incl. `jsonl`); declared failure shapes; positional-
bias / instruction-locality co-location; affirmative reframing of clustered
prohibitions; dropped sibling-lens cross-references; a uniform output-block anchor
across the investigator family; and data-not-instructions guards on the
highest-exposure untrusted-input prompts.

**Instruction-leaking guard — DONE (registry-wide).** A standardized
data-not-instructions guard now sits in every prompt whose input is
externally-authored untrusted content (63 of 73): all review and diagnosis
prompts, the analytical classification/verification/exploration prompts, the
findings/conflict-ingesting remediation prompts, and the diff-ingesting
transformation/generation/decomposition prompts. The 10 prompts without it are
the generative/planning/spec-driven ones whose input is the operator's legitimate
brief (not untrusted data), where the guard would be semantically wrong. Coverage
is verifiable: `grep -L` for the guard across the registry returns exactly that
spec-driven set.
