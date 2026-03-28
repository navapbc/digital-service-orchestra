# Milestone Fidelity Review Criteria

## Overview

Each drafted milestone is reviewed by three specialist reviewers using `/dso:review-protocol`
(Stage 1, pass_threshold 4). Each reviewer has a self-contained prompt file in
`shared/docs/reviewers/` (relative to the `skills/` directory) that defines their persona,
dimensions, and scoring rubric. The subject for every review is `"Milestone: {milestone title}"`.

All reviewer output conforms to `REVIEW-SCHEMA.md`. See that document for the
JSON schema, field reference, and pass/fail derivation rules.

## Reviewer Prompts

| Reviewer | Prompt File | Perspective Label | Focus |
|----------|-------------|-------------------|-------|
| Senior Technical Program Manager | [../../shared/docs/reviewers/agent-clarity.md](../../shared/docs/reviewers/agent-clarity.md) | Agent Clarity | Self-contained spec, measurable success criteria |
| Senior Product Strategist | [../../shared/docs/reviewers/scope.md](../../shared/docs/reviewers/scope.md) | Scope | Right-sized deliverable, no overlap with other milestones, explicit dependency mapping |
| Senior Product Manager | [../../shared/docs/reviewers/value.md](../../shared/docs/reviewers/value.md) | Value | User or business impact, user validation signal |

## Launching Reviews

Use the Task tool to launch all three reviewers **in parallel**. For each:

1. Read the reviewer's prompt file from `../../shared/docs/reviewers/` (relative to this file's location)
2. Construct the Task prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale)
   - The milestone spec (title, Context narrative, Success Criteria)
   - For the Scope reviewer: the titles and summaries of all other milestones being drafted in this session (roadmap context)
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Launch the Task with `subagent_type: "general-purpose"`

## Score Aggregation Rules

Per `/dso:review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all three reviewers.
2. Any individual dimension score below 4 means the milestone **fails** for that dimension.
3. ALL dimension scores must be 4, 5, or null (N/A) for the milestone to **pass**.
4. Incorporate findings into the milestone spec before presenting to the user.
5. If a milestone fails, revise the spec and re-run the fidelity check before proceeding.

## Conflict Detection

Per `/dso:review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same part of the milestone spec but pulling in opposite
directions.

Common conflict patterns in milestone review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| Scope: "Milestone is too broad, split it" | Agent Clarity: "Success criteria are already thin, don't reduce further" | `expand_vs_reduce` |
| Value: "Add dependency on prior milestone" | Scope: "This overlap means it should merge with that milestone" | `strict_vs_flexible` |
| Agent Clarity: "Add more context to the spec" | Scope: "Scope is already too wide" | `more_vs_less` |

**Resolution** (per `/dso:review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/dso:review-protocol`'s revision protocol:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before revising.
3. Modify the milestone's Context narrative and/or Success Criteria based on findings.
4. Re-run the fidelity check until all dimensions score 4 or above, or escalate to the user.

## Validation

After aggregating all reviewer outputs into the combined JSON (`subject`, `reviews[]`, `conflicts[]`), validate the output before using scores or findings. This ensures every required perspective, dimension, and reviewer-specific field is present and correctly typed.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
REVIEW_OUT="$(get_artifacts_dir)/roadmap-review-output.json"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
".claude/scripts/dso validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller roadmap
```

**Caller schema hash**: `f4e5f5a355e4c145` — identifies the exact set of perspectives, dimensions, and reviewer-specific fields expected from this caller.

If `SCHEMA_VALID: no` is printed:
1. Read the listed errors — they identify exactly which perspective, dimension, or finding field is missing or wrong.
2. Fix the output (re-request from the reviewer sub-agent if needed, correcting the format prompt).
3. Re-run validation until `SCHEMA_VALID: yes` before proceeding to score aggregation or revision cycles.
