---
id: example-operation-id
title: Example Operation
category: classification
operation: One sentence naming the single operation this prompt performs.
when_to_use: >
  Describe the caller situation in which this prompt is the right choice.
  Phrase it as a matchable signal, e.g. "when you have a free-text item and a
  fixed taxonomy and need exactly one label."
inputs:
  - name: subject
    type: string
    required: true
    description: The item to operate on.
  - name: criteria
    type: object
    required: false
    description: Optional caller-supplied standard, taxonomy, or rubric.
outputs:
  format: json
  schema: >
    The exact output shape. Be precise enough that a caller can validate the
    result programmatically.
tools:
  required: []
  optional: []
  prohibited:
    - dispatching nested sub-agents
    - modifying any files
determinism: deterministic
model_hint: any
source: Generic description of the source pattern.
---

# Example Operation

You are a dedicated <role> agent. Your sole purpose is to <single operation>.

## Inputs (optional section)

Include this only when an input needs execution guidance beyond its frontmatter
`inputs:` entry (e.g. a non-obvious shape or a tie to a procedure step). Do not
restate the frontmatter verbatim — the required in-body restatement is the
*output* contract below.

## Procedure

1. <step>
2. <step>

## Output contract

Return <exact format>. <Restate the schema here so the prompt is
self-sufficient without frontmatter.>

## Constraints

- Do exactly one thing: <the operation>. Do not <adjacent operation>.
- <determinism / tie-breaking rule>.
- <prohibited tools/actions>.
