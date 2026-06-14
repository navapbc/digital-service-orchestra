# Prompt Registry

A library of **discrete, single-operation prompts** extracted from agent
definitions, skills, and workflows. Each prompt is self-contained, generic
(no assumptions about any particular project, ticket system, or sibling
prompt), and carries an explicit interface contract: what it consumes, what
it emits, which tools it may use, and when it should be selected.

The goal is reuse. A prompt here should drop cleanly into any agent harness —
a sub-agent dispatch, a single API call, a node in a larger workflow — without
edits beyond filling in its declared inputs.

## Design principles

1. **One operation per prompt.** A prompt performs exactly one named
   transformation from input to output. If a prompt does two things ("classify
   *and* fix"), it is two prompts.
2. **Explicit contract.** Inputs, outputs, and tool use are declared in
   frontmatter and restated in the body. A caller can satisfy the contract
   without reading the prose.
3. **Portable in mechanism, concrete in knowledge.** Strip project *plumbing* —
   repo paths, CLI/script names, file layouts, company names — so the prompt runs
   anywhere. Do NOT strip the evaluation *knowledge*: the rubrics, checklists,
   taxonomies, severity calibration, decision tables, and standards ARE the value
   of the prompt and must be embedded inline. Parameters are for genuinely
   per-use variation (the specific artifact under review, the acceptance criteria
   for *this* work) — never for the reusable criteria themselves. A prompt whose
   criteria live only in a caller-supplied input is hollow.
4. **Deterministic output shape.** The output format (text token, JSON object,
   findings array, XML blocks) is fixed and machine-checkable. Reviews and
   verifications emit a findings array; classifications emit a closed value
   set.
5. **Composable, not coupled.** A prompt never names another prompt or assumes
   it runs inside a particular pipeline. Orchestration is the caller's job.

## Categories

| Category | Operation shape | Output shape |
|----------|-----------------|--------------|
| `classification/` | Take an input, assign it to one value from a defined set | A single label (or small structured verdict) |
| `review/` | Evaluate an input against a standard | An array of findings, each with a severity |
| `exploration/` | Find information in a codebase, on the web, or in history | A structured report of what was found, with evidence |
| `generation/` | Produce a new artifact — code, docs, plans, tests | The artifact, plus a manifest of what was produced |
| `verification/` | Decide whether a claim/artifact meets stated criteria | A typed verdict (PASS/FAIL/…) with evidence |
| `transformation/` | Rewrite an input into a different shape, same information | The transformed artifact |
| `diagnosis/` | Find the root cause of an observed failure | A confirmed root cause with supporting evidence |
| `decomposition/` | Break one large item into smaller well-formed items | An ordered set of child items |
| `planning/` | Choose among options or sequence work before building | A decision record or ordered plan with rationale |
| `remediation/` | Resolve identified problems by applying changes | The applied change plus a result/summary of what was done |

Categories are chosen by **output shape and intent**, not by domain. A prompt
that "reviews architecture" and one that "reviews test quality" both live in
`review/` because both emit a findings array against a standard.

## Prompt file format

Every prompt is a single Markdown file with YAML frontmatter. See
[`_TEMPLATE.md`](./_TEMPLATE.md) for the canonical, copy-pasteable form. The
frontmatter contract:

```yaml
---
id: kebab-case-unique-id          # stable identifier
title: Human Readable Title
category: classification|review|exploration|generation|verification|transformation|diagnosis|decomposition|planning|remediation
operation: One sentence naming the single operation performed.
when_to_use: >
  The selection signal — what must be true of the caller's situation for this
  prompt to be the right choice. Written so a router can match on it.
inputs:                            # the input contract
  - name: subject
    type: string|object|array|file-ref
    required: true
    description: What it is and any shape constraints.
outputs:                           # the output contract
  format: single-line-token|json|jsonl|yaml|markdown|xml-blocks|structured-block|structured-artifact
  schema: >
    Exact description of the output shape. For review prompts this is an array
    of {finding, severity, ...}. For classification, the closed value set.
tools:                             # the tool-use contract
  required: []                     # tools the prompt must have to function
  optional: []                     # tools it may use if available
  prohibited: []                   # tools/actions it must never take
determinism: deterministic|low-variance|generative
model_hint: haiku|sonnet|opus|any  # advisory only
source: Generic description of the source pattern (not a project path).
---
```

The body that follows frontmatter is the actual prompt text, written in the
second person to the executing model.

## Authoring rules

- **Genericize mechanism, embed knowledge.** Replace project-specific paths,
  commands, and script names with declared inputs (e.g. if the original said "run
  `dso ticket show`," declare a `subject` input). Do NOT do this to evaluation
  knowledge: rubrics, checklists, taxonomies, and severity calibration must be
  written into the prompt body, not pushed out to a caller-supplied input. The
  source agents' hard-won criteria are the reason the prompt has value — losing
  them to "genericization" is the same mistake as collapsing distinct prompts.
  When a real, named project standard exists (a testing standard, a fix-pattern
  catalog, a classification registry), capture it as concrete registry content
  (see `standards/`) and embed the operative criteria in the prompts that apply
  it — reference is not a substitute for embedding.
- **Restate the contract in the body.** The body must contain an explicit
  output-format section so the prompt works even if frontmatter is stripped.
- **No prompt-to-prompt references.** Do not name sibling prompts or assume a
  pipeline. If two operations are usually chained, document that in the
  category README, not inside the prompt.
- **Closed value sets for classification.** A classifier must define its full
  output vocabulary and a default/escape value for "none fit."
- **Severity scale for reviews.** Reviews use a single shared severity scale
  (`critical`, `important`, `minor`, `nit`) unless the caller supplies its own.

## Distinct operations are distinct prompts

Prompts that share an output schema but apply a **different process or criteria**
are distinct operations and each gets its own file — never combine them. A dozen
code reviewers (light, correctness, security red-team, performance, test-quality,
…) all emit a findings array, but each runs a different checklist and severity
policy; the nine bug investigators share a root-cause schema but apply different
techniques (execution tracing vs. timeline reconstruction vs. empirical
instrumentation). These are separate prompts. Two source files map to the *same*
prompt only when their process AND criteria are identical (differing solely in
dispatch harness or model).

Routing across related prompts is handled by `SELECTOR.md` index docs (e.g.
[`review/SELECTOR.md`](./review/SELECTOR.md),
[`diagnosis/SELECTOR.md`](./diagnosis/SELECTOR.md)), which point to the individual
prompts and describe composition patterns — without consolidating them.

## Status

See [`STATUS.md`](./STATUS.md) for current coverage, the source-inventory map, the
five-criteria review verdict, and the anti-pattern pass. Run
`scripts/validate-registry.sh` to check the interface contract across all prompts.
