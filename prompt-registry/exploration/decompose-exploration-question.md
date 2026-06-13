---
id: decompose-exploration-question
title: Classify and Decompose an Exploration Question
category: exploration
operation: Classify a research/investigation question as single-source or multi-source and, when multi-source, decompose it into focused leaf sub-questions for parallel investigation.
when_to_use: >
  At the start of any research or codebase-investigation task, before searching.
  Use to avoid answering a compound question with one flawed synthesis — it
  decides whether to answer directly or to split the question into independently
  answerable sub-questions, and signals mid-flight when an answer depends on an
  unstated factor or sources contradict.
inputs:
  - name: question
    type: string
    required: true
    description: The exploration question to classify and possibly decompose.
  - name: max_redecomposition
    type: integer
    required: false
    description: How many decomposition levels are allowed. Defaults to 1 — sub-questions must be answerable directly.
outputs:
  format: structured-block
  schema: >
    Either a FINDING block (when single-source and answerable) with
    source/confidence/answer/evidence/caveats; or a DECOMPOSE_RECOMMENDED block
    with a reason and a list of focused leaf sub-questions.
tools:
  required: []
  optional:
    - read-only search to confirm a question is single-source before answering
  prohibited:
    - answering a multi-source question with a single synthesis
    - expanding unfamiliar acronyms/terms without a confirmed source definition
    - emitting sub-questions that themselves require further decomposition
determinism: low-variance
model_hint: any
source: Exploration decomposition protocol — single/multi-source classification with a bounded decompose escape hatch.
---

# Classify and Decompose an Exploration Question

You classify an exploration question by source and scope, then either answer it
directly (single-source) or decompose it into focused sub-questions
(multi-source). The point is to prevent answering a compound question with one
flawed synthesis.

## Classification

**SINGLE_SOURCE** (proceed directly) when ALL hold: the answer lives in one
well-defined place; a specific artifact is named (pronouns like "we/our" do NOT
imply a particular scope); and there is a single correct answer not requiring
comparison across locations.

**MULTI_SOURCE** (decompose first) when ANY hold: it is a broad web question (the
web is not a single source — split by knowledge facet); a codebase question
spanning multiple architectural layers (split by layer); a comparative question
(requires comparing two+ things); ambiguous scope (could mean several things —
ambiguity itself drives decomposition); or contradictory signals are detected.

Preserve unfamiliar acronyms/terms **verbatim** as opaque search tokens — never
guess an expansion; an incorrect expansion corrupts all downstream exploration.

## Mid-flight escape hatch

If, while exploring, you hit a bright-line trigger — (1) the correct answer
depends on a factor not stated in the question (environment, role, version), or
(2) two sources directly contradict — emit `DECOMPOSE_RECOMMENDED` rather than
guessing.

## Bounded re-decomposition

Re-decomposition is bounded to `max_redecomposition` (default 1) level. Emitted
sub-questions must be **leaf** questions — each answerable directly without
triggering another decomposition. If a candidate sub-question is still
multi-source, narrow it before emitting; do not defer the bound to the caller.

## Output contract

When single-source and answerable:

```
FINDING
source: <file path, URL, or "synthesized">
confidence: high | medium | low
answer: <the direct answer>
evidence: <quote or reference supporting it>
caveats: [<conditions under which this may not hold>]
```

When decomposition is needed:

```
DECOMPOSE_RECOMMENDED
reason: <one sentence: which trigger fired>
sub_questions:
  - <focused leaf question 1>
  - <focused leaf question 2>
```

Use `low` confidence when a decompose trigger was present but unresolved — never
silently inflate confidence.

## Constraints

- Do exactly one thing: classify and (if needed) decompose. Do not synthesize a
  multi-source answer here.
- Do NOT expand unfamiliar terms without a confirmed source definition.
- Sub-questions must be leaf questions answerable without further decomposition.
