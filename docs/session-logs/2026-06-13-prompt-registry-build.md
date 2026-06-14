# Session Log — Prompt Registry Build

**Date:** 2026-06-13 → 2026-06-14
**Branch:** `claude/project-review-reliability-qe58sf`
**Scope:** Build a registry of discrete, single-operation prompts from the
project's agents/skills/workflows, then iteratively review, de-consolidate, and
harden it.

---

## Outcome (final state)

- **73 single-operation prompts across 10 categories** + **1 captured standard**,
  all passing `prompt-registry/scripts/validate-registry.sh`.
- Categories: review (26), diagnosis (10), classification (7), exploration (6),
  generation (6), verification (6), planning (4), remediation (4),
  decomposition (3), transformation (1).
- Supporting files: `README.md` (contract + design principles), `_TEMPLATE.md`,
  `STATUS.md` (coverage + audits), `scripts/validate-registry.sh`,
  `review/SELECTOR.md`, `diagnosis/SELECTOR.md`,
  `standards/behavioral-testing-standard.md`.
- 31 commits, all pushed to origin.

---

## How it started

The work was kicked off via `/loop 1h "Create a registry of prompts…"`. The loop
skill's recurrence backend (`CronCreate` / `ScheduleWakeup` / `send_later`) is
**not available in this Claude Code on the web environment** (ephemeral container,
no scheduler), so a true hourly recurrence could not be armed. Per the skill's
"execute now" step, each invocation ran the task immediately; the user re-issued
the command several times, which advanced the work in stages.

The original umbrella request ("review this project for reliability and
maintainability") was superseded by the `/loop` prompt-registry task.

---

## Narrative arc

### 1. Scaffold and first extraction
Established `prompt-registry/` with a README defining the interface contract
(frontmatter: id/title/category/operation/when_to_use/inputs/outputs/tools/
determinism/model_hint/source) and category taxonomy, a `_TEMPLATE.md`, and the
first prompts (classification, diagnosis, review, …). Added
`validate-registry.sh` to enforce the contract mechanically. Committed/pushed per
batch. (Commits `8e911f3`–`dbac5a4`.)

### 2. Breadth pass — all categories
Extracted prompts across every category, derived from the agent/skill/workflow
sources and genericized. Reached ~33 prompts, then ~39, ~45, ~49 across
successive passes, adding a `remediation/` category. Ran **bot-psychologist
anti-pattern audits** (17-point taxonomy, KERNEL minimal-fix, affirmative
framing) after each batch and applied the fixes. (Commits through `c727a06`.)

### 3. Coverage methodology
On request, designed and ran a coverage method: enumerate all `plugins/dso`
markdown, signal-detect operation-shaped files (role frame + output contract),
subtract what's captured. A **section-level scan** then found operations embedded
inside SKILL.md/workflow bodies (not just `prompts/` subdirs), yielding more
distinct operations (prioritize-into-tiers, reconcile-committee-review,
coverage-omissions, unverified-assumptions, etc.).

### 4. Major course-correction #1 — reverse the "lens" collapse
**The biggest correction.** An earlier pass had collapsed two families — the ~12
code-reviewer variants and the 9 bug-investigator variants — into two base prompts
plus "lens" catalogs, on the theory that they shared an output schema. The user
flagged this as wrong: *prompts that share a contract but apply a different process
and criteria are distinct and must be separate files.* Combining them erased the
per-variant evaluation IP.

Reversed entirely: extracted each reviewer (light, standard, performance,
test-quality, deep-correctness/hygiene/verification/architecture, security
red-team/blue-team) and each investigator (intermediate, advanced
code-tracer/historical, escalated code-tracer/empirical/history/web, cluster) as
its own self-contained prompt with its distinct criteria preserved verbatim.
Replaced the `LENSES.md` catalogs with `SELECTOR.md` routing indexes (point to
the prompts; never combine them). Also extracted previously-dismissed distinct
agents (refactor-conformance, bloat triage/removal, incident-corpus curation,
CI-failure scan, task-list gap analysis, scenario filter). Reached 73 prompts.
Independent audits **confirmed all de-consolidated prompts are genuinely distinct**
(no accidental duplicates). Genuine duplicates (CI reviewers, huge-diff
light/standard, intermediate-fallback) were intentionally NOT separated — same
process and criteria, only dispatch harness/model differs. (Commits
`0ff8f98`–`c1f007a`.)

### 5. Hardening — instruction-leaking guard sweep
Audits surfaced a systemic gap: prompts that ingest externally-authored content
lacked a data-not-instructions guard (#14 instruction leaking). Applied a
standardized guard to all 63 prompts whose input is untrusted content
(review/diagnosis/analytical-classification/verification/remediation/exploration +
diff-ingesting transformation/generation/decomposition). The 10 generative/
planning/spec-driven prompts were deliberately excluded — their input is the
operator's brief, not untrusted data. (Commits `218c065`, `a6f84b4`.)

### 6. Major course-correction #2 — design principle #3 was wrong
The user identified that principle #3 ("portable; domain specifics arrive through
declared inputs, never hardcoded") was wrong: it conflated **mechanism**
portability (paths/CLIs/scripts — correctly stripped) with **evaluation
knowledge** (rubrics/standards/taxonomies — wrongly stripped). Externalizing
criteria to caller inputs hollows the prompt; the criteria are its value — the
same class of error as the lens collapse.

Re-evaluation found the damage was narrower than feared (most prompts already
embed their rubric with the parameter as an optional override), with a three-way
correct treatment: **mechanism → strip; reusable knowledge → embed + capture in
`standards/`; instance data → parameterize.** Corrected principle #3 and the
authoring rule, created `standards/`, and captured the flagship
`behavioral-testing-standard.md` (research-grounded, 6 rules) as proof. (Commit
`ed1cbd9`.)

---

## Key design decisions

- **Distinctness over consolidation.** Distinct process/criteria ⇒ distinct
  prompt. Routing via SELECTOR indexes, not combined prompts.
- **Mechanism vs knowledge vs instance data** (corrected principle #3). Strip the
  first, embed the second, parameterize the third.
- **Evidence-or-abstain discipline** across reviews/verifications (absence is
  INCONCLUSIVE/FAIL, never inferred); fail-open vs fail-closed stated per prompt.
- **Self-sufficient bodies** — each prompt restates its output contract so it works
  if frontmatter is stripped.
- **Genuine duplicates are not duplicated** either — CI/huge-diff/fallback variants
  map to their canonical prompt.

---

## Verification

- `validate-registry.sh` enforces frontmatter contract, category/dir agreement,
  and self-sufficient body sections: 73/73 pass, 0 violations.
- Seven independent bot-psychologist audits; all de-consolidated prompts confirmed
  distinct; fixes applied (output-anchor consistency, schema pinning, affirmative
  reframing, the instruction-leaking sweep).

---

## Open follow-ups (recorded in STATUS.md)

1. Capture remaining reusable standards in `standards/`: prohibited-fix-patterns,
   anti-patterns catalog, a generic plain-language/accessibility copy standard.
2. Wire those into the under-embedded prompts (`resolve-review-findings` /
   `apply-fix-across-occurrences` ← prohibited-fix-patterns; `write-plain-language-copy`
   ← copy standard).
3. Add a `standards/SELECTOR.md` mapping standards → consuming prompts.
4. Optional durability: add a `source_ref:` frontmatter field + `coverage-report.sh`
   to make source-coverage exact rather than estimated.
5. Instance data (bug taxonomy, UI canon, config keys) stays external by design.

---

## Commit history (this session)

```
8e911f3 Add prompt-registry scaffold with classification and diagnosis prompts
f182452 Add review-category prompts
ab94ecf Add generation, decomposition, exploration, verification, diagnosis prompts
8050e49 Add transformation, planning, and behavioral-test prompts
dbac5a4 Add registry validator and status/continuation doc
f2b85c7 Add review/verification/classification distinct-operation prompts
77a3437 Add arbiter, approach-proposer, plain-language-copy prompts
5e48d07 Add conflict-triage, prior-art, value/effort, complexity-gate, remediation-scope
0ecfba0 Add story-decomposition, UI-design, visual-evaluation prompts
968cb89 Add exploration-decomposition prompt, lens catalogs, finalize
ddacc86 Refine prompts per bot-psychologist anti-pattern audit
275c242 Record completed bot-psychologist refinement stage in STATUS
6192086 Extract six more distinct-operation prompts previously deferred
545a732 Refine new batch per bot-psychologist audit
cb66852 Update STATUS: 39 prompts, fourth audit pass
32b28d0 Add six verified-new prompts and a remediation category
8b67589 Refine coverage-sweep prompts per fifth audit; update STATUS
0d52f4e Add four embedded-operation prompts from the section-level scan
c727a06 Refine section-level prompts per sixth audit; update STATUS
0ff8f98 Reverse lens collapse (1/N): distinct reviewer tiers
c216a31 Reverse lens collapse (2/N): deep-tier + security reviewers
512ab54 Reverse lens collapse (3/N): distinct investigators; selectors replace lens catalogs
c664de1 Reverse lens collapse (4/N): previously-dismissed distinct agents
d025920 Reverse lens collapse (5/N): gap-analysis, scenario filter, CI scan
f955049 Update README + STATUS: distinctness principle, selectors, 73 prompts
eb72ba1 Apply seventh audit fixes to de-consolidated prompts
c1f007a STATUS: record seventh audit (all distinct)
218c065 Registry-wide data-not-instructions guard sweep (#14)
a6f84b4 STATUS: mark guard sweep complete
ed1cbd9 Correct design principle #3 (mechanism-vs-knowledge); capture first standard
```
