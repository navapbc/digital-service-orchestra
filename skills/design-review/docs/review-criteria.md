# Design Review Criteria

## Overview

The design is reviewed by a committee of six specialists using `/review-protocol`
(Stage 1, mental pre-review; multi-perspective). Each reviewer has a self-contained
prompt file in `docs/reviewers/` that defines their persona, dimensions, and scoring
rubric. The pass threshold is **4** — all dimension scores must be 4, 5, or null (N/A)
for the review to pass.

All reviewer output conforms to `REVIEW-SCHEMA.md`. See that document for the
JSON schema, field reference, and pass/fail derivation rules.

## Reviewer Prompts

| Reviewer | Prompt File | Perspective Label | Focus |
|----------|-------------|-------------------|-------|
| North Star Alignment Specialist | [reviewers/north-star-alignment.md](reviewers/north-star-alignment.md) | North Star Alignment | User archetype fit (incl. information hierarchy), anti-pattern avoidance, design system compliance, scope fit, future readiness |
| Usability & HCD Specialist | [reviewers/usability-hcd.md](reviewers/usability-hcd.md) | Usability (HCD) | User feedback, interaction quality, accessibility (WCAG 2.1 AA), content clarity |
| Visual Design Specialist | [reviewers/visual-design.md](reviewers/visual-design.md) | Visual Design | Visual hierarchy (incl. type scale discipline), intentional layout (incl. Gestalt principles), fidelity balance |
| Senior Design System Engineer | [reviewers/component-reuse.md](reviewers/component-reuse.md) | Component Reuse | Library-first approach, portability, trope vs useful, removal impact |
| Senior Interaction Designer | [reviewers/form-input-design.md](reviewers/form-input-design.md) | Form & Input Design | Minimal input, validation guidance, review before submit |
| Technical Compliance Engineer | [reviewers/tech-compliance.md](reviewers/tech-compliance.md) | Tech Compliance | Tech stack correctness, system architecture consistency |

## Launching Reviews

For each reviewer:

1. Read the reviewer's prompt file from `docs/reviewers/`
2. Construct the sub-agent prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale, instructions)
   - The story context (ID, title, description, acceptance criteria)
   - The proposed design (code snippet, wireframe description, or diff)
   - Design notes content from `design.design_notes_path` (required for North Star Alignment and Tech Compliance)
   - Epic context if the story belongs to an epic (for scope_fit and future_readiness)
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Reviewers may be launched sequentially or in parallel depending on context size

## Score Aggregation Rules

Per `/review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all six reviewers.
2. Any individual dimension score below 4 means the design **fails** for that dimension.
3. ALL dimension scores must be 4, 5, or null (N/A) for the design to **pass**.
4. Log every review cycle with before/after findings summary.
5. Maximum 3 automated revision cycles. After 3 failures, escalate to the user.

## Conflict Detection

Per `/review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same component or artifact but pulling in opposite directions.

Common conflict patterns in design review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| North Star: "Scope is too large for this story" | Usability: "Missing error states needed for user flow" | `expand_vs_reduce` |
| North Star: "Add token-compliant visual indicator" | Tech Compliance: "Avoid custom CSS not in the defined stack" | `add_vs_remove` |
| Usability: "Show more guidance to reduce errors" | North Star: "UI is over-engineered beyond story scope" | `more_vs_less` |
| Usability: "Enforce strict WCAG contrast" | Tech Compliance: "Color token deviations need justification" | `strict_vs_flexible` |

**Resolution** (per `/review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/review-protocol`'s revision protocol:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before revising.
3. Modify the specific artifact (code, wireframe description, or diff) each finding targets.
4. Document each revision with before/after description.
5. Re-submit the revised design for the next review cycle.

## Validation

After aggregating all reviewer outputs into the combined JSON (`subject`, `reviews[]`, `conflicts[]`), validate the output before using scores or findings. This ensures every required perspective, dimension, and reviewer-specific field is present and correctly typed.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh"
REVIEW_OUT="$(get_artifacts_dir)/design-review-output.json"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
"${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/scripts/validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller design-review
```

**Caller schema hash**: `1a50fe899037ef49` — identifies the exact set of perspectives, dimensions, and reviewer-specific fields expected from this caller.

If `SCHEMA_VALID: no` is printed:
1. Read the listed errors — they identify exactly which perspective, dimension, or finding field is missing or wrong.
2. Fix the output (re-request from the reviewer sub-agent if needed, correcting the format prompt).
3. Re-run validation until `SCHEMA_VALID: yes` before proceeding to score aggregation or revision cycles.
