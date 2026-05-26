# UI Designer Committee Arbitration

The ui-designer review committee produces a combined verdict from multiple reviewers. This document specifies the arbitration rules.

## Committee Composition

Standard 5-reviewer committee (post Integration B activation):

1. accessibility-specialist
2. design-systems-lead — owns `visual_hierarchy_intent` (intent-based / text-mediated)
3. frontend-engineer
4. product-manager
5. visual-spatial-evaluator (NEW) — owns `visual_hierarchy_legibility` (pixel-observable)

4-reviewer fallback (when Integration B token-budget hard-stop fires): committee runs without visual-spatial-evaluator.

## Tie-Break Rules

### Rule 1: Pixel-observable conflicts → visual_hierarchy_legibility wins

When the 5th reviewer (visual-spatial-evaluator) and design-systems-lead disagree about a pixel-observable hierarchy concern (legibility, contrast, font weight, size differential, etc.), the 5th reviewer's verdict prevails. Pixel-observable assessments are grounded in rendered DOM measurements; intent-only assessments are not.

**Example**: design-systems-lead scores `visual_hierarchy_intent: 4` (hierarchy intent is clear), but visual-spatial-evaluator scores `visual_hierarchy_legibility: 2` (contrast ratio 1.8:1 in rendered output). The legibility score prevails, and the combined verdict reflects the block.

### Rule 2: Intent-only conflicts → visual_hierarchy_intent wins

When the 5th reviewer and design-systems-lead disagree about a hierarchy concern that involves designer intent (whether a heading should be visually demoted relative to spec, whether de-emphasis is intentional, whether a visual weight choice reflects a deliberate design decision), design-systems-lead's verdict prevails.

**Example**: visual-spatial-evaluator flags a heading as under-emphasized relative to body text. design-systems-lead notes this is intentional per the Epic UX Map (de-emphasized secondary action). The intent score prevails.

### Rule 3: Mixed tie-break (3-2, both sides include the visual-spatial-evaluator)

When 3 reviewers (including visual-spatial-evaluator) hold position A and 2 reviewers hold position B, the 3-2 majority wins regardless of which side the 5th reviewer is on. Rules 1 and 2 apply only to the `visual_hierarchy_*` dimension pair specifically; for all other dimensions, majority wins.

### Rule 4: 2-2-abstain (4-reviewer fallback)

When the committee is in 4-reviewer fallback mode (visual-spatial-evaluator skipped due to budget hard-stop) and the remaining 4 reviewers split 2-2: **tie defaults to block** (verdict: `needs-revision`). The orchestrator must escalate to the user.

## Activation Conditions

The 5th reviewer is active when ALL of the following are true:
- Sprint Integration B has been activated
- Visual-evaluator skill preconditions pass (project is web, Playwright available, route-map fresh)
- Token budget hard-stop has NOT fired for the current batch

When the 5th reviewer is skipped, the orchestrator MUST note `"visual_spatial_skipped": true` in the combined verdict JSON.

## Combined Verdict Resolution

1. Collect all reviewer verdicts.
2. If any reviewer emits `"fail"`: combined verdict is `"fail"`.
3. If any reviewer emits `"needs-revision"` and none emit `"fail"`: combined verdict is `"needs-revision"`.
4. If all reviewers emit `"pass"`: combined verdict is `"pass"`.
5. Apply tie-break Rules 1–4 only when `visual_hierarchy_legibility` and `visual_hierarchy_intent` conflict within the same design.

## Regression Tests

See `tests/skills/test-ui-designer-5-reviewer.sh`.
