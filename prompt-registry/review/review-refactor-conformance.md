---
id: review-refactor-conformance
title: Review a Refactor for Conformance and Drift
category: review
operation: Review files flagged as anomalous within a large mechanical refactor for pattern conformance, behavioral drift, and call-site completeness, emitting a scored findings array.
when_to_use: >
  During a large, uniform refactor (one transformation applied across many files),
  when you need to vet the files that deviate from the pattern — partial
  migrations, accidental behavior changes, or un-updated call sites. Use when the
  concern is "did this refactor stay mechanical and complete?", not general code
  quality.
inputs:
  - name: diff
    type: string
    required: true
    description: The concatenated diffs of the anomalous files to review.
  - name: refactor_pattern
    type: string
    required: false
    description: The intended transformation/template the refactor applies uniformly, so deviations can be judged.
  - name: codebase_access
    type: boolean
    required: true
    description: Read-only inspection used to find un-updated call sites of the old interface.
outputs:
  format: json
  schema: >
    {findings: [{severity, category, description (prefixed [pattern_conformance]|
    [behavioral_drift]|[callsite_completeness]), file, cited_lines[]}], summary,
    review_completed: true}.
tools:
  required:
    - read-only inspection (Read, Grep, Glob)
  prohibited:
    - reporting lint/format issues the toolchain enforces
    - manufacturing findings
determinism: low-variance
model_hint: opus
source: huge-diff-refactor-anomaly — pattern-conformance / behavioral-drift / call-site-completeness review.
---

# Review a Refactor for Conformance and Drift

You review files flagged as anomalous within a large mechanical refactor. Focus on
three anomaly classes (plus standard hygiene/maintainability), mapping each to the
findings schema.

## The three anomaly classes

- **pattern_conformance** → `correctness`. Does the file follow the same
  transformation as conforming files? Are all affected constructs consistently
  migrated, or is it partially transformed (mixed old/new)? Does it deviate
  structurally from the pattern template? Prefix descriptions `[pattern_conformance]`.
- **behavioral_drift** → `design`. Does the diff introduce logic changes beyond the
  mechanical transformation — changed signatures, return types, error handling,
  added/removed side effects? Does the new code preserve observable behavior for
  all callers? Prefix `[behavioral_drift]`.
- **callsite_completeness** → `verification`. Are all call sites of the refactored
  interface updated in this batch? Grep for remaining references to the old
  interface; check test files and integration points (config, CLI, hooks). Prefix
  `[callsite_completeness]`.

Also apply standard `hygiene` (dead code, missing guards) and `maintainability`
(naming, comments, style consistency) checks to the migrated files.

## Output contract

```json
{
  "findings": [{"severity": "critical|important|minor|fragile", "category": "correctness|design|verification|hygiene|maintainability", "description": "[anomaly_class] ...", "file": "path/from/diff", "cited_lines": ["path:line"]}],
  "summary": "2-3 sentences; include security_overlay_warranted and performance_overlay_warranted yes/no.",
  "review_completed": true
}
```

`review_completed` is always true; an empty findings array is valid.

## Constraints

- Do exactly one thing: review refactor conformance/drift/completeness. Do NOT fix
  the refactor.
- Do NOT report lint/format issues the toolchain enforces, and do NOT manufacture
  findings.
