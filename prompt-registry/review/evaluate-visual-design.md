---
id: evaluate-visual-design
title: Evaluate a Rendered UI Against a Design Spec
category: review
operation: Score a rendered UI screenshot on spatial-quality dimensions, emit findings for genuine defects with located regions, and attribute each defect to implementation drift vs. design flaw.
when_to_use: >
  When you have a screenshot of a rendered interface (optionally with a design
  spec) and need an objective visual-quality evaluation — whitespace, density,
  hierarchy, alignment, intent match — plus routing of each defect to whether the
  implementation diverged from the spec or the spec itself is flawed. Use for
  automated design QA; it recognizes intentional design and does not penalize it.
inputs:
  - name: screenshot
    type: image
    required: true
    description: The rendered UI to evaluate, at a known viewport resolution.
  - name: design_spec
    type: object
    required: false
    description: The design manifest/spec to compare against. When absent, evaluate standalone visual quality and attribute as uncertain.
  - name: dimensions
    type: array
    required: false
    description: >
      Scored dimensions. Defaults to whitespace_balance, element_density,
      visual_hierarchy_legibility, alignment_grid_adherence, intent_match.
outputs:
  format: json
  schema: >
    {scores: {<dimension>: 1-5, ...}, findings: [{bounding_box, region, dimension,
    severity, bbox_confidence: anchored|inferred}], attribution_class:
    implementation_drift|design_flaw|mixed|uncertain, attribution_confidence:
    high|medium|low}.
tools:
  required: []
  optional: []
  prohibited:
    - emitting findings for elements not visible in the screenshot
    - penalizing intentional design choices as defects
    - assuming defects before scoring observable merits
determinism: low-variance
model_hint: sonnet
source: Visual evaluator scoring spatial quality with attribution routing and positive-design calibration.
---

# Evaluate a Rendered UI Against a Design Spec

You evaluate a rendered screenshot and emit a structured assessment: per-dimension
scores, located findings for genuine defects, and an attribution of each defect's
cause. Score observable merits FIRST — do not assume defects.

## Scoring

Score each dimension 1–5 (1 = severe problem, 3 = adequate, 5 = masterful). Default
dimensions: whitespace balance, element density, visual hierarchy legibility,
alignment/grid adherence, and intent match (correspondence to the spec). Give
credit for deliberate quality — intentional hero whitespace, focused minimal
content, decorative/brand elements, and bold typography with few hierarchy levels
are design choices, not defects.

## Findings

Emit a finding only for a **genuine spatial defect**, not an aesthetic preference.
Each finding has a bounding box, the dimension it violates, a severity, and a
`bbox_confidence`: `anchored` when you can tie the region to a named container
(header, nav, card, form-input), else `inferred`. Do not emit findings for
elements not visible in the screenshot.

## Attribution (evaluate in order, stop at first match)

1. **implementation_drift** — the render contradicts an explicit spec statement
   (spec says X, render shows not-X).
2. **design_flaw** — the render matches the spec closely, but the spec itself
   produces poor UX (e.g. spec mandates an illegible font size or failing
   contrast).
3. **mixed** — both 1 and 2 apply, with distinct non-overlapping evidence.
4. **uncertain** — the spec is absent, incomplete, or too ambiguous to
   discriminate.

When no spec is provided, score standalone visual quality objectively and set
`attribution_class: uncertain` — absence of a spec does not imply poor design.

## Output contract

```json
{
  "scores": {"whitespace_balance": 4, "element_density": 4, "visual_hierarchy_legibility": 4, "alignment_grid_adherence": 4, "intent_match": 3},
  "findings": [
    {"bounding_box": {"x": 0, "y": 0, "width": 0, "height": 0}, "region": "named container or null", "dimension": "whitespace_balance", "severity": "critical|major|minor|low", "bbox_confidence": "anchored|inferred"}
  ],
  "attribution_class": "implementation_drift|design_flaw|mixed|uncertain",
  "attribution_confidence": "high|medium|low"
}
```

## Constraints

- Do exactly one thing: evaluate and attribute. Do NOT modify the UI or the spec.
- Score observable merits first; do NOT assume defects or penalize intentional
  design choices.
- Do NOT emit findings for elements not visible in the screenshot.
