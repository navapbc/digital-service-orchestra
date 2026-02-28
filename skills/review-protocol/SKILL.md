---
name: review-protocol
description: Use when a skill needs structured multi-perspective review with conflict detection, revision cycles, and standardized JSON output — replaces ad-hoc mental reviews and custom sub-agent review logic
---

# Review Protocol

Standardized 3-stage review process producing schema-compliant JSON output.
See `.claude/docs/REVIEW-SCHEMA.md` for the output schema.

## Parameters

Callers configure the review by providing:

| Parameter | Required | Description |
|-----------|----------|-------------|
| `subject` | Yes | What is being reviewed (used in schema output) |
| `artifact` | Yes | The content to review (text, JSON, code, design spec) |
| `perspectives` | Yes | Array of perspective definitions (see below) |
| `pass_threshold` | No | Minimum dimension score to pass. Default: 4 |
| `start_stage` | No | `1` (default), `2`, or `3`. Use `2` to skip mental pre-review when caller already self-validated |
| `max_revision_cycles` | No | Default: 3 |

### Perspective Definition

Each perspective in the `perspectives` array:

```
{
  "name": "Security",
  "dimensions": {
    "auth_coverage": "All endpoints require appropriate authentication",
    "input_validation": "All user inputs are validated and sanitized"
  },
  "context": "Optional additional context for this perspective"
}
```

- `name`: Short label (appears in output as `perspective`)
- `dimensions`: Map of dimension names to descriptions of what "passing" looks like
- `context`: Optional extra context the reviewer should consider

For complex reviewers with separate prompt files (e.g., `/design-wireframe`'s reviewer prompts), the caller reads the file and passes its content as `context`.

---

## Stage 1: Mental Pre-Review

**Skip when**: `start_stage >= 2`. Use this when the calling skill has already performed its own self-validation (e.g., `/design-wireframe` Phase 4 artifact consistency check).

The calling agent reviews the artifact against each perspective's dimensions. For each dimension, ask: "Would this score below {pass_threshold}?"

If obvious issues are found:
1. Fix them directly in the artifact
2. Note what was changed (for transparency in the review log)
3. Proceed to Stage 2 with the revised artifact

This is cheap (no sub-agent) and catches low-hanging issues before spending tokens on a sub-agent.

---

## Stage 2: Sub-Agent Structured Review

Dispatch a **single sub-agent** with a structured multi-perspective rubric.

### Sub-Agent Prompt Template

```
## Structured Multi-Perspective Review

Review the following artifact from multiple perspectives. For each perspective,
score every dimension 1-5 (or null if not applicable). For any score below
{pass_threshold}, provide a finding with severity, description, and specific
suggestion.

### Artifact
{artifact content}

### Perspectives and Dimensions

{For each perspective:}
#### {perspective.name}
{perspective.context if provided}

Dimensions (score each 1-5, null if N/A):
{For each dimension: "- {name}: {description of passing}"}

### Conflict Detection

After scoring all dimensions, scan your findings for contradictions:
- Group findings by target (the component, file, or section they address)
- Within each group, check if any two suggestions pull in opposite directions:
  - add vs remove
  - more detail vs less complexity
  - stricter vs more flexible
  - expand scope vs reduce scope
- Only flag contradictions where both findings have severity "critical" or "major"
- Minor-vs-anything is not a conflict (minor finding yields to the other)

### Output Format

Return valid JSON matching this structure:
{REVIEW-SCHEMA.md schema}
```

#### Determine Review Model

Before launching the sub-agent, check whether the artifact under review contains high-blast-radius content — changes that cascade project-wide when wrong. Inspect the artifact (and any associated file paths provided by the caller) for these patterns:

- `.claude/skills/**` — skill definitions
- `.claude/skills/**/prompts/**` — sub-agent prompt templates
- `.claude/hooks/**` — hook scripts
- `.claude/docs/**` — agent documentation
- `CLAUDE.md` — project-level agent instructions
- `.github/workflows/**` — CI configuration
- `scripts/**` — orchestration scripts
- `.pre-commit-config.yaml` — pre-commit hooks
- `Makefile` — build/test/lint commands

If **any** pattern matches:
```
model="opus"    # Tier 3: high-blast-radius files — changes to skills/CI/scripts cascade project-wide
```

If **none** match:
```
model="sonnet"  # Tier 2: routine code review — standard code changes
```

Launch with:
```
subagent_type: "general-purpose"
model: "{opus or sonnet per detection above}"
```

### Parse and Validate

After the sub-agent returns:
1. Parse the JSON output
2. Validate it has all required fields per `REVIEW-SCHEMA.md`
3. If parsing fails, retry once with explicit format correction prompt

---

## Stage 3: Conflict Escalation

**Trigger**: `conflicts[]` array is non-empty after Stage 2.

For each conflict:
- If one finding is `critical` and the other is `minor` → resolve in favor of the critical finding, no escalation
- If both are `critical` or `major` → **escalate to user** via AskUserQuestion, presenting both suggestions as options
- If both are `minor` → caller chooses either direction without escalation

**Multi-agent escalation** (optional, caller decides): If the caller prefers sub-agent resolution over user escalation, dispatch one sub-agent per conflicting perspective to debate the tradeoff. Each receives the other's finding and must propose a resolution that addresses both concerns. Use only when user escalation is impractical (e.g., batch processing).

---

## Revision Protocol

When the review does not pass (any dimension below `pass_threshold`):

1. **Triage by severity**: Address `critical` findings first, then `major`, then `minor`. Skip `minor` if they don't affect pass/fail.

2. **Check conflicts first**: If `conflicts[]` is non-empty, resolve conflicts (Stage 3) before spending a revision cycle.

3. **Revise**: For each finding being addressed, modify the specific artifact it targets. The calling skill documents what changed.

4. **Re-submit**: Send the full revised artifact back through Stage 2. Do not send partial updates.

5. **Cycle limit**: Maximum `max_revision_cycles` automated cycles (default 3). After exhausting cycles:
   - Do NOT revise automatically
   - Present the user with: current artifact state, all unresolved findings across all cycles, and specific questions about direction
   - Apply user input, then run one final Stage 2 review

6. **Cycle tracking**: The calling skill is responsible for tracking cycle count and logging review history in whatever format it uses (beads notes, review-log.md, etc.).

---

## Quick Reference

```
Stage 1 (Mental)  → Caller self-reviews, fixes obvious issues
                     Skip if start_stage=2
Stage 2 (Single)  → One sub-agent, multi-perspective rubric
                     Returns REVIEW-SCHEMA.md JSON
Stage 3 (Conflict) → Triggered by non-empty conflicts[]
                     Escalate critical+critical to user
                     Minor yields to other finding
Revision           → Triage by severity, resolve conflicts first
                     Max 3 cycles, then escalate to user
```

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Skipping Stage 1 without reason | Only skip if caller already self-validated. Set `start_stage: 2` explicitly. |
| Speculative conflict detection | Don't guess whether a suggestion "might" worsen another dimension. Only flag direct contradictions in suggestions. |
| Revising before resolving conflicts | Always resolve Stage 3 conflicts before spending a revision cycle. |
| Ignoring N/A dimensions | `null` scores are valid. Don't treat them as failures. |
| Retrying failed review parse indefinitely | One retry with format correction. After that, report the raw output to the caller. |
