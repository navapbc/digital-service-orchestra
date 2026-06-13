---
id: split-large-change-for-review
title: Split a Large Change Into Reviewable Units
category: decomposition
operation: Given an oversized change (a large diff or working tree), propose an ordered set of smaller commits each scoped to a single concern or layer, with tests kept alongside their code.
when_to_use: >
  When a change exceeds a reviewable size and mixes concerns, and you need a plan
  to break it into focused commits a reviewer can assess in isolation. Use to
  improve review quality — a reviewer holding many unrelated changes at once misses
  interactions; smaller focused units catch more.
inputs:
  - name: change
    type: object
    required: true
    description: The oversized change — a diff or a description of the files and concerns in the working tree.
  - name: size_threshold
    type: integer
    required: false
    description: Approximate scorable-line ceiling per unit. Defaults to ~600 (generated/lock/migration and test-only files are typically exempt).
outputs:
  format: json
  schema: >
    {units: [{order, purpose, files[], includes_tests: bool, rationale}],
    split_strategy: "by-concern|by-layer|mixed", notes}. Each unit is one concern,
    reviewable without the others, with its tests co-located.
tools:
  required: []
  optional:
    - read-only inspection of the change to group files by concern/layer
  prohibited:
    - applying the split, staging, or committing (propose the plan only)
    - separating tests from the code they cover
determinism: low-variance
model_hint: sonnet
source: Large-diff splitting guide — split by concern or layer, keep tests with code.
---

# Split a Large Change Into Reviewable Units

You propose how to break an oversized change into smaller, independently
reviewable commits. You produce the plan only — you do not stage or commit.

## Principles

- **One concern per unit.** Each unit has a single reason to exist, summarizable
  in a one-line message with no "and". Signs a split is needed: the message needs
  "and"/a semicolon; files span unrelated areas; a reviewer would need to
  understand two unrelated systems.
- **Split by layer for a vertical slice.** When the change is one feature across
  layers, order units: data model → service/business logic → API/contract → UI.
  Each layer is reviewable in isolation because the interfaces between them are
  well-defined.
- **Keep tests with their code.** A unit contains both the implementation and the
  tests that cover it — never a separate "add tests" unit. A reviewer needs the
  tests to assess the code.
- **Account for exemptions.** Generated files, lock files, migrations, and
  test-only changes are typically exempt from the size ceiling; if the change is
  large mostly because of those, note it and split only the non-exempt work.

## Procedure

1. Identify the independent concerns (or layers) in the change.
2. Group files into units, each one concern/layer, each under `size_threshold`
   scorable lines, each carrying its own tests.
3. Order the units so dependencies land first (e.g. data model before service).
4. Emit the plan; flag any unit still over threshold for a further split.

## Output contract

```json
{
  "units": [
    {
      "order": 1,
      "purpose": "one-line reason, no 'and'",
      "files": ["path", "path/test"],
      "includes_tests": true,
      "rationale": "why this is independently reviewable"
    }
  ],
  "split_strategy": "by-concern|by-layer|mixed",
  "notes": "exemptions noted; any unit still oversized"
}
```

## Constraints

- Do exactly one thing: propose the split plan. Do NOT stage, commit, or apply it.
- Never separate tests from the code they cover.
- Each unit must be one concern, reviewable without the others.
