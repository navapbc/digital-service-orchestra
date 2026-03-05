# Dev Onboarding: Architecture Blueprint Review Criteria

This document defines the peer review configuration for Phase 4 of `/dev-onboarding`.
The review evaluates the generated Architecture Blueprint using `/review-protocol`
with `pass_threshold: 4` and `start_stage: 1` (mental pre-review included).

**Subject**: `"Architecture Blueprint for {project name}"`

## Reviewers

| Reviewer Title | Prompt File | Perspective Label | Focus |
|----------------|-------------|-------------------|-------|
| Senior SRE (Failure Modes) | [reviewers/failure-modes.md](reviewers/failure-modes.md) | `"Failure Modes"` | Resource boundaries, failure isolation, recovery by design, degradation paths |
| Senior Security and Platform Engineer (Hardening) | [reviewers/hardening.md](reviewers/hardening.md) | `"Hardening"` | Secure by default (auth, secrets, input, access control), observable by default (logging, health, lifecycle, errors), enforced by default (architectural invariants, pre-action gates, commit-time checks, dependency boundaries, CI enforcement) |
| Senior Staff Software Architect (Scalability) | [reviewers/scalability.md](reviewers/scalability.md) | `"Scalability"` | Stateless by default, data patterns (pagination, query guardrails, growth planning) |

## Launching Reviews

For each reviewer, construct a sub-agent prompt as follows:

1. Read the reviewer file (e.g., `reviewers/failure-modes.md`) to obtain the reviewer's system prompt.
2. Pass the full Phase 2 blueprint (tech stack, API design, data model, system context diagram, directory structure, ADR 001, and key config files) as the artifact.
3. Instruct the reviewer to return JSON conforming to `REVIEW-SCHEMA.md` using their specified perspective label.
4. Do NOT inflate scores. Suggestions must be concrete and reference specific components or files from the blueprint.

## Score Aggregation Rules

- **Pass**: ALL dimension scores across ALL three perspectives are >= 4 or `null`.
- **Fail**: Any single dimension score below 4 triggers a fail. Present findings to the user before proceeding.
- Log the full JSON output from each reviewer for audit. Do not summarize findings — present them in full.

## Conflict Detection

Common conflict patterns for architecture reviews:

| Pattern | Example |
|---------|---------|
| `strict_vs_flexible` | Failure Modes requires circuit breakers; Scalability accepts simpler retry logic for early stage |
| `more_vs_less` | Hardening requests comprehensive structured logging; blueprint minimizes initial dependencies |
| `add_vs_remove` | Scalability recommends external session store; blueprint keeps sessions in-process for simplicity |

When two perspectives conflict, surface the conflict in the `conflicts[]` array per `REVIEW-SCHEMA.md`.
Present both recommendations to the user and ask which tradeoff to make before revising the blueprint.

## Revision Protocol

Follow the standard `/review-protocol` revision protocol. After findings are presented:
1. Ask the user which findings to address before generating the Repository Skeleton.
2. Revise only the specific blueprint sections flagged by accepted findings.
3. Re-run the affected reviewer(s) if changes are substantial enough to shift a score.

## Validation

After aggregating all reviewer outputs into the combined JSON (`subject`, `reviews[]`, `conflicts[]`), validate the output before using scores or findings. This ensures every required perspective, dimension, and reviewer-specific field is present and correctly typed.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh"
REVIEW_OUT="$(get_artifacts_dir)/dev-onboarding-review-output.json"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
"${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/scripts/validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller dev-onboarding
```

**Caller schema hash**: `9ec70789c77bcca2` — identifies the exact set of perspectives, dimensions, and reviewer-specific fields expected from this caller.

If `SCHEMA_VALID: no` is printed:
1. Read the listed errors — they identify exactly which perspective, dimension, or finding field is missing or wrong.
2. Fix the output (re-request from the reviewer sub-agent if needed, correcting the format prompt).
3. Re-run validation until `SCHEMA_VALID: yes` before proceeding to score aggregation or revision cycles.
