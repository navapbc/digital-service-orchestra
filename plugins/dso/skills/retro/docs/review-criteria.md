# Codebase Health Review Criteria

## Overview

The codebase health assessment is reviewed by a committee of five specialists using
`/dso:review-protocol` (Stage 2, multi-agent). Data collection in Phase 2 of `/dso:retro`
serves as Stage 1. Each reviewer has a self-contained prompt file in `docs/reviewers/`
that defines their persona, dimensions, and scoring rubric.

All reviewer output conforms to `REVIEW-SCHEMA.md`. See that document for the
JSON schema, field reference, and pass/fail derivation rules.

**pass_threshold**: 4 — all dimension scores must be >= 4 or null (N/A) for the
codebase to pass this review stage.

## Reviewer Prompts

| Reviewer | Prompt File | Perspective Label | Focus |
|----------|-------------|-------------------|-------|
| Test Quality Analyst | [reviewers/test-quality.md](reviewers/test-quality.md) | Test Quality | Assertion coverage, mock discipline, test naming |
| Documentation Health Specialist | [reviewers/documentation.md](reviewers/documentation.md) | Documentation | Freshness of resolved issues, completeness of TODO/FIXME tracking |
| Senior Software Engineer (Code Quality) | [reviewers/code-quality.md](reviewers/code-quality.md) | Code Quality | File size, function complexity, duplication |
| Python Style and Conventions Auditor | [reviewers/naming-conventions.md](reviewers/naming-conventions.md) | Naming Conventions | snake_case modules/functions, PascalCase classes, UPPER_CASE constants |
| Software Architect (Layering and Boundaries) | [reviewers/architecture.md](reviewers/architecture.md) | Architecture | Route/service/provider layering, circular imports, PipelineState discipline |

## Launching Reviews

Use the Task tool to launch all five reviewers **in parallel**. For each:

1. Read the reviewer's prompt file from `docs/reviewers/`
2. Construct the Task prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale)
   - The collected metrics from Phase 2 data collection (TEST_METRICS, CODE_METRICS,
     KNOWN_ISSUES sections from `retro-gather.sh`, plus the additional spot-checks)
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Launch the Task with `subagent_type: "general-purpose"`

## Score Aggregation Rules

Per `/dso:review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all five reviewers.
2. Any individual dimension score below 4 means the codebase **fails** for that dimension.
3. ALL dimension scores must be 4, 5, or null (N/A) for the codebase to **pass**.
4. Maximum 3 automated revision cycles. After 3 failures, escalate to the user.
5. Present findings grouped by tier: Critical (P0-P1), Improvement (P2), Cleanup (P3-P4).

## Conflict Detection

Per `/dso:review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same file or pattern but pulling in opposite directions.

Common conflict patterns in codebase health review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| Code Quality: "Extract this 60-line function" | Architecture: "This decomposition would split a cohesive bounded context" | `strict_vs_flexible` |
| Documentation: "Add more inline comments" | Code Quality: "This file is already too long" | `more_vs_less` |
| Test Quality: "Add more edge case tests" | Code Quality: "Test file is too large" | `expand_vs_reduce` |
| Naming: "Rename this module" | Architecture: "This interface is part of a public contract" | `strict_vs_flexible` |

**Resolution** (per `/dso:review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/dso:review-protocol`'s revision protocol, codebase health findings do not trigger
automated code revisions. Instead:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before scoping the remediation epic.
3. Group findings into priority tiers for Phase 3 user confirmation.
4. Convert confirmed findings into ticket tasks in Phase 4.

## Validation

After aggregating all reviewer outputs into the combined JSON (`subject`, `reviews[]`, `conflicts[]`), validate the output before using scores or findings. This ensures every required perspective, dimension, and reviewer-specific field is present and correctly typed.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
REVIEW_OUT="$(get_artifacts_dir)/retro-review-output.json"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
".claude/scripts/dso validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller retro
```

**Caller schema hash**: `8a1a3dd74e54f101` — identifies the exact set of perspectives, dimensions, and reviewer-specific fields expected from this caller.

If `SCHEMA_VALID: no` is printed:
1. Read the listed errors — they identify exactly which perspective, dimension, or finding field is missing or wrong.
2. Fix the output (re-request from the reviewer sub-agent if needed, correcting the format prompt).
3. Re-run validation until `SCHEMA_VALID: yes` before proceeding to score aggregation or revision cycles.
