# Design Review Criteria

## Overview

The design is reviewed by a committee of four specialists using `/dso:review-protocol`
(Stage 2, multi-agent). Each reviewer has a self-contained prompt file in
`docs/reviewers/` that defines their persona, dimensions, and scoring rubric.

All reviewer output conforms to `REVIEW-SCHEMA.md`. See that document for the
JSON schema, field reference, and pass/fail derivation rules.

## Reviewer Prompts

| Reviewer | Prompt File | Perspective Label | Focus |
|----------|-------------|-------------------|-------|
| Senior Product Manager | [reviewers/product-manager.md](reviewers/product-manager.md) | Product Management | Strategic alignment, user value, scope, anti-pattern compliance |
| Senior Design Systems Lead | [reviewers/design-systems-lead.md](reviewers/design-systems-lead.md) | Design Systems | Component reuse, visual hierarchy, system compliance |
| CPWA Accessibility Specialist | [reviewers/accessibility-specialist.md](reviewers/accessibility-specialist.md) | Accessibility | WCAG 2.1 AA, keyboard, screen reader, HCD heuristics |
| Senior Frontend Software Engineer | [reviewers/frontend-engineer.md](reviewers/frontend-engineer.md) | Frontend Engineering | Feasibility, performance, state complexity, spec clarity |

## Launching Reviews

Use the Task tool to launch all four reviewers **in parallel**. For each:

1. Read the reviewer's prompt file from `docs/reviewers/`
2. Construct the Task prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale)
   - The story context (ID, title, description, acceptance criteria)
   - The design artifacts (manifest, JSON, SVG description, tokens)
   - Reviewer-specific context (see Phase 5 Step 16 in SKILL.md)
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Launch the Task with `subagent_type: "general-purpose"`

## Score Aggregation Rules

Per `/dso:review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all four reviewers.
2. Any individual dimension score below 4 means the design **fails** for that dimension.
3. ALL dimension scores must be 4, 5, or null (N/A) for the design to **pass**.
4. Log every review cycle to `designs/<uuid>/review-log.md`.
5. Maximum 3 automated revision cycles. After 3 failures, escalate to the user.

## Conflict Detection

Per `/dso:review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same component/artifact but pulling in opposite directions.

Common conflict patterns in design review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| PM: "Add onboarding guidance" | DSL: "Too much visual clutter" | `more_vs_less` |
| A11y: "Add visible labels to all inputs" | DSL: "Visual hierarchy is too flat" | `add_vs_remove` |
| FE: "Simplify state management" | PM: "Add undo capability" | `strict_vs_flexible` |
| PM: "Scope is too large" | FE: "Specification is incomplete" | `expand_vs_reduce` |

**Resolution** (per `/dso:review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/dso:review-protocol`'s revision protocol:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before revising.
3. Modify the specific artifact (JSON, SVG, tokens, or manifest) each finding targets.
4. Document each revision in the review log with before/after description.
5. Re-submit ALL artifacts for the next review cycle.

## Validation

After aggregating all reviewer outputs into the combined JSON (`subject`, `reviews[]`, `conflicts[]`), validate the output before using scores or findings. This ensures every required perspective, dimension, and reviewer-specific field is present and correctly typed.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
REVIEW_OUT="$(get_artifacts_dir)/ui-designer-review-output.json"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
.claude/scripts/dso validate-review-output.sh review-protocol "$REVIEW_OUT" --caller ui-designer
```

**Caller schema hash**: `2c3ece1bc2820109` — identifies the exact set of perspectives, dimensions, and reviewer-specific fields expected from this caller.

If `SCHEMA_VALID: no` is printed:
1. Read the listed errors — they identify exactly which perspective, dimension, or finding field is missing or wrong.
2. Fix the output (re-request from the reviewer sub-agent if needed, correcting the format prompt).
3. Re-run validation until `SCHEMA_VALID: yes` before proceeding to score aggregation or revision cycles.
