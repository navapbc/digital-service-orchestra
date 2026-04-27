# Design Review Criteria

This file is the **design-review domain overlay** for `/dso:review-protocol`.
Aggregation rules, conflict-resolution mechanics, revision cycles, and per-caller
schema validation are owned by the protocol — see
`${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md` and
`${CLAUDE_PLUGIN_ROOT}/docs/REVIEW-SCHEMA.md`. Only the design-review-specific
content (reviewer roster, launch instructions, conflict patterns) lives here.

The design is reviewed by a committee of six specialists using `/dso:review-protocol`
(Stage 1, mental pre-review; multi-perspective). The pass threshold is **4** —
all dimension scores must be 4, 5, or null (N/A) for the review to pass.

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

## Conflict Detection (design-review domain)

Conflict-detection mechanics, severity-based resolution rules, and escalation
thresholds are owned by `/dso:review-protocol`. The patterns below are the
design-review-specific contradictions to watch for during Stage 2 aggregation:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| North Star: "Scope is too large for this story" | Usability: "Missing error states needed for user flow" | `expand_vs_reduce` |
| North Star: "Add token-compliant visual indicator" | Tech Compliance: "Avoid custom CSS not in the defined stack" | `add_vs_remove` |
| Usability: "Show more guidance to reduce errors" | North Star: "UI is over-engineered beyond story scope" | `more_vs_less` |
| Usability: "Enforce strict WCAG contrast" | Tech Compliance: "Color token deviations need justification" | `strict_vs_flexible` |

## Validation

Validation runs inside `/dso:review-protocol` when `caller_id: "design-review"` is
passed (REVIEW-PROTOCOL-WORKFLOW.md invokes
`validate-review-output.sh review-protocol <out> --caller design-review`).
Do not run validation a second time from this skill.

**Caller schema hash**: `1a50fe899037ef49` — identifies the exact set of
perspectives, dimensions, and reviewer-specific fields expected from this caller.
The validator is the source of truth; this hash mirrors
`HASH_CALLER_DESIGN_REVIEW` in `validate-review-output.sh`.
