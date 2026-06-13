---
id: detect-coverage-omissions
title: Detect Coverage Omissions Between a Source and a Derived Artifact
category: review
operation: Extract the named entities a source explicitly mentions and flag any that a derived artifact fails to cover, using fuzzy matching to avoid false positives.
when_to_use: >
  When one artifact is supposed to fully cover another — success criteria derived
  from a request, requirements derived from a brief, a spec derived from a
  conversation — and you need to catch things the source named that the derived
  artifact silently dropped. Use to prevent summarization/omission gaps; it errs
  toward "covered" via fuzzy matching so it only flags genuine misses.
inputs:
  - name: source
    type: string
    required: true
    description: The original artifact that names the entities that must be covered (e.g. the user's request).
  - name: derived
    type: string
    required: true
    description: The artifact that should cover them (e.g. the drafted success criteria/requirements).
  - name: entity_kinds
    type: array
    required: false
    description: >
      The kinds of named entity to extract. Defaults to file paths, tool/command
      names, data structures, API endpoints, config keys, and named components.
outputs:
  format: json
  schema: >
    {omissions: [{entity, why_uncovered}], covered_count, extracted_count}.
    Empty omissions when the derived artifact covers every named entity.
tools:
  required: []
  optional:
    - read-only inspection when source/derived are supplied by reference
  prohibited:
    - flagging an entity covered under any reasonable fuzzy interpretation
    - modifying either artifact
determinism: low-variance
model_hint: sonnet
source: Artifact contradiction detection — named-entity coverage check between a request and its derived criteria with fuzzy matching.
---

# Detect Coverage Omissions Between a Source and a Derived Artifact

You check whether the `derived` artifact covers every entity the `source`
explicitly named, and flag the omissions. Analysis only.

## Procedure

1. **Extract entities.** From `source`, list every explicitly-named entity of the
   `entity_kinds` (file paths, tool/command names, data structures, API
   endpoints, config keys, named components, …).
2. **Check coverage.** For each entity, determine whether it appears in `derived`
   — directly or by fuzzy match.
3. **Flag only genuine misses.** An entity is **covered** (do not flag) when any
   reasonable interpretation of the derived text encompasses it. Apply these
   fuzzy rules as "covered":
   - **Abbreviations/aliases** — source "tk" vs derived "the tk CLI".
   - **Containment** — source ".index.json" vs derived "store/.index.json".
   - **Synonyms / role descriptions** — source "the cache" vs derived "the
     `.cache/` directory".
   Only flag an entity as an omission when **no** reasonable interpretation of the
   derived text would encompass it.

## Output contract

```json
{
  "omissions": [
    {"entity": "the source-named entity", "why_uncovered": "no derived text encompasses it, even fuzzily"}
  ],
  "covered_count": 0,
  "extracted_count": 0
}
```

Return an empty `omissions` array when the derived artifact covers every named
entity. The two counts let a caller sanity-check the extraction.

## Constraints

- Do exactly one thing: detect named-entity omissions. Do NOT rewrite either
  artifact or add coverage yourself.
- Err toward "covered" — flag only entities no reasonable interpretation covers.
- Extract only entities the source *explicitly* named, not inferred ones.
