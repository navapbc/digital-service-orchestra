# Preplanning Architecture Board Review Criteria

## Overview

Each user story produced by `/preplanning` is reviewed by a virtual Architecture
Board of six specialists using `/review-protocol` (Stage 1, per-story review).
The Board evaluates the story's scope, done definitions, and considerations for
cross-cutting risks before implementation begins.

`pass_threshold: 4` — all dimension scores must be 4, 5, or null (N/A) to pass.

Each reviewer has a self-contained prompt file in `docs/reviewers/` that defines
their persona, dimensions, and scoring rubric. All reviewer output conforms to
`REVIEW-SCHEMA.md`. See that document for the JSON schema, field reference, and
pass/fail derivation rules.

## Reviewer Prompts

| Reviewer | Prompt File | Perspective Label | Focus |
|----------|-------------|-------------------|-------|
| Senior Security Engineer | [reviewers/security.md](reviewers/security.md) | Security | Auth coverage, data protection, OWASP Top 10 |
| Senior Performance Engineer | [reviewers/performance.md](reviewers/performance.md) | Performance | Latency targets, resource efficiency, scalability (input size boundaries, concurrent access) |
| WCAG Accessibility Specialist | [reviewers/accessibility.md](reviewers/accessibility.md) | Accessibility | WCAG 2.1 AA compliance, inclusive UX for new UI stories |
| Senior Software Engineer in Test | [reviewers/testing.md](reviewers/testing.md) | Testing | User journey coverage, boundary scenarios, verifiable outcomes |
| Senior Site Reliability Engineer | [reviewers/reliability.md](reviewers/reliability.md) | Reliability | Error handling, graceful degradation, failover (blast radius calibrated) |
| Senior Software Architect | [reviewers/maintainability.md](reviewers/maintainability.md) | Maintainability | Coupling risk, changeability, documentation of non-obvious decisions |

## Launching Reviews

Use the Task tool to launch all six reviewers **in parallel**. For each:

1. Read the reviewer's prompt file from `docs/reviewers/`
2. Construct the Task prompt by combining:
   - The reviewer prompt (role, dimensions, scoring scale, instructions)
   - The story context: ID, title, description, done definitions, considerations
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md`:
   `perspective`, `status`, `dimensions` map, `findings` array
4. Launch the Task with `subagent_type: "general-purpose"`

**Subject line** for each review: the story title.

## Score Aggregation Rules

Per `/review-protocol` and `REVIEW-SCHEMA.md`:

1. Collect all dimension scores from all six reviewers.
2. Any individual dimension score below 4 means the story **fails** for that dimension.
3. ALL dimension scores must be 4, 5, or null (N/A) for the story to **pass**.
4. Log every review cycle with story ID, reviewer, scores, and pass/fail outcome.
5. Maximum 3 automated revision cycles. After 3 failures, escalate to the user.

## Conflict Detection

Per `/review-protocol`, scan findings for **direct contradictions** — pairs of
suggestions targeting the same story element but pulling in opposite directions.

Common conflict patterns in story-level review:

| Reviewer A says... | Reviewer B says... | Pattern |
|--------------------|--------------------|---------|
| Security: "Restrict data access to owner only" | Performance: "Cache results globally to reduce DB load" | `strict_vs_flexible` |
| Testing: "Require mock interface for LLM calls" | Reliability: "Add live circuit breaker around LLM calls" | `add_vs_remove` |
| Accessibility: "Add detailed WCAG done definitions" | Maintainability: "Story scope is too prescriptive" | `more_vs_less` |
| Performance: "Batch operations to reduce API calls" | Reliability: "Add per-item retry with backoff" | `expand_vs_reduce` |

**Resolution** (per `/review-protocol`):
- Critical vs minor: critical finding wins, no escalation
- Both critical/major: escalate to user immediately
- Both minor: caller chooses direction

## Revision Protocol

Per `/review-protocol`'s revision protocol:

1. Triage findings by severity (critical → major → minor).
2. Resolve conflicts before revising.
3. Modify the specific story element each finding targets — scope, done definitions,
   or considerations — not the implementation.
4. Document each revision in the review log with before/after description.
5. Re-submit the updated story for the next review cycle.

## Validation

After aggregating all reviewer outputs into the combined JSON (`subject`, `reviews[]`, `conflicts[]`), validate the output before using scores or findings. This ensures every required perspective, dimension, and reviewer-specific field is present and correctly typed.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh"
REVIEW_OUT="$(get_artifacts_dir)/preplanning-review-output.json"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
"${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/scripts/validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller preplanning
```

**Caller schema hash**: `dba581aa06265af0` — identifies the exact set of perspectives, dimensions, and reviewer-specific fields expected from this caller.

If `SCHEMA_VALID: no` is printed:
1. Read the listed errors — they identify exactly which perspective, dimension, or finding field is missing or wrong.
2. Fix the output (re-request from the reviewer sub-agent if needed, correcting the format prompt).
3. Re-run validation until `SCHEMA_VALID: yes` before proceeding to score aggregation or revision cycles.
