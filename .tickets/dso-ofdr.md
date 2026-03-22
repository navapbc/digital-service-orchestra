---
id: dso-ofdr
status: in_progress
deps: []
links: []
created: 2026-03-22T14:53:47Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-jtkr
---
# Contract: classifier JSON output tier-selection interface

Create the contract document for the interface between review-complexity-classifier.sh (emitter) and REVIEW-WORKFLOW.md (parser).

## Purpose

The classifier emits a JSON object consumed by REVIEW-WORKFLOW.md to select the named review agent. This interface must be specified before either side is implemented to prevent implicit assumptions.

## Contract Document

Create: plugins/dso/docs/contracts/classifier-tier-output.md

### Signal Name
CLASSIFIER_TIER_OUTPUT

### Emitter
plugins/dso/scripts/review-complexity-classifier.sh

### Parser
plugins/dso/docs/workflows/REVIEW-WORKFLOW.md (Step 3)

### Fields (from epic success criteria)
- per_factor_scores: object — keys: blast_radius, critical_path, anti_shortcut, staleness, cross_cutting, diff_lines, change_volume (each integer)
- computed_total: integer — sum of all factor scores before floor rules
- selected_tier: string — one of: light | standard | deep

### Example
{
  "blast_radius": 2,
  "critical_path": 0,
  "anti_shortcut": 0,
  "staleness": 1,
  "cross_cutting": 1,
  "diff_lines": 1,
  "change_volume": 0,
  "computed_total": 5,
  "selected_tier": "standard"
}

### Tier Thresholds
- 0-2: light
- 3-6: standard
- 7+: deep

### Failure Contract
If classifier exits non-zero, times out (exit 144), or outputs malformed JSON: default to standard tier.

## TDD Requirement

No RED test required — this task creates a static contract document (no conditional logic, no executable behavior). Exemption: Unit exemption criterion 3 (static assets only — a Markdown document has no executable assertions).

## Implementation Steps

1. Create plugins/dso/docs/contracts/ directory if it does not exist
2. Write plugins/dso/docs/contracts/classifier-tier-output.md with the sections above
3. Verify the contract document is complete before any implementation tasks begin


## ACCEPTANCE CRITERIA

- [ ] Contract document exists at plugins/dso/docs/contracts/classifier-tier-output.md
  Verify: `test -f plugins/dso/docs/contracts/classifier-tier-output.md`
- [ ] Document contains Signal Name, Emitter, Parser, and Schema sections
  Verify: `grep -q 'Signal Name' plugins/dso/docs/contracts/classifier-tier-output.md && grep -q 'Schema' plugins/dso/docs/contracts/classifier-tier-output.md`
- [ ] Schema specifies per_factor_scores, computed_total, selected_tier fields
  Verify: `grep -q 'per_factor_scores\|computed_total\|selected_tier' plugins/dso/docs/contracts/classifier-tier-output.md`
- [ ] Document specifies exit code semantics (0=success, non-zero=failure)
  Verify: `grep -q 'exit.*0\|exit code' plugins/dso/docs/contracts/classifier-tier-output.md`
- [ ] ruff format passes: `ruff format --check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] ruff check passes: `ruff check plugins/dso/scripts/*.py tests/**/*.py`

## Notes

**2026-03-22T15:22:02Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T15:22:17Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T15:22:20Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-22T15:22:48Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T15:23:03Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T15:23:14Z**

CHECKPOINT 6/6: Done ✓
