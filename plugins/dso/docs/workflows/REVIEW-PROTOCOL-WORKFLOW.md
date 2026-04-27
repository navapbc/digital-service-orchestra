# Review Protocol Workflow

Standardized 3-stage review process producing schema-compliant JSON output.
See `${CLAUDE_PLUGIN_ROOT}/docs/REVIEW-SCHEMA.md` for the output schema.

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
| `caller_id` | No | If the caller has a registered schema (see `scripts/validate-review-output.sh --list-callers`), pass the caller ID here to enable per-caller validation of perspectives, dimensions, and reviewer-specific finding fields. Known IDs: `roadmap`, `ui-designer`, `implementation-plan`, `retro`, `design-review`, `architect-foundation`, `preplanning`. |

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

For complex reviewers with separate prompt files (e.g., `dso:ui-designer`'s reviewer prompts), the caller reads the file and passes its content as `context`.

---

## Stage 1: Mental Pre-Review

**Skip when**: `start_stage >= 2`. Use this when the calling skill has already performed its own self-validation (e.g., `dso:ui-designer` Phase 4 artifact consistency check).

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

Check whether the artifact under review contains high-blast-radius content. For code reviews, use the pattern list in `REVIEW-WORKFLOW.md` Step 3. For non-code reviews (plans, designs), the caller specifies the model (e.g., `/dso:plan-review` uses opus for designs, sonnet for implementation plans).

If **any** high-blast-radius pattern matches → `model="opus"`. Otherwise → `model="sonnet"`.

Launch with:
```
subagent_type: "general-purpose"
model: "{opus or sonnet per detection above}"
```

### Parse and Validate

After the sub-agent returns:
1. Save the JSON output to a temp file
2. Run the schema validator (schema-hash: 3053fa9a43e12b79):
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   REVIEW_OUT="$(get_artifacts_dir)/review-protocol-output.json"
   cat > "$REVIEW_OUT" <<'EOF'
   <sub-agent JSON output>
   EOF

   # Base schema check (always)
   ".claude/scripts/dso validate-review-output.sh" review-protocol "$REVIEW_OUT"

   # Per-caller check (when caller_id is provided)
   # ".claude/scripts/dso validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller <caller_id>
   ```
3. If `SCHEMA_VALID: no` — retry the sub-agent once with an explicit format correction prompt; do not proceed with invalid output
4. If `SCHEMA_VALID: yes` — emit the review result event, then proceed to Stage 3

### Emit Review Result (post-Stage 2)

After Stage 2 completes with valid schema output, emit a review event so downstream observability can track review outcomes:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
".claude/scripts/dso" emit-protocol-review-result.sh \
  --review-type="<caller's review type, e.g. implementation-plan, brainstorm-fidelity, architectural>" \
  --pass-fail="<passed|failed, based on whether all dimensions meet pass_threshold>" \
  --revision-cycles=0
```

The `--review-type` value comes from the caller context (the skill invoking this workflow). `--revision-cycles` is `0` for the initial Stage 2 pass. This call is best-effort — a failure does not block the review.

**When `caller_id` is provided**, pass `--caller <caller_id>` to the validator. This additionally checks that:
- All expected perspectives are present (or marked `not_applicable`)
- Each perspective's `dimensions` map contains the required dimension keys
- Each finding contains the reviewer-specific fields required by that perspective (e.g., `wcag_criterion` for Accessibility, `owasp_category` for Security)
- Enum-typed fields use valid values (e.g., `complexity_estimate` must be `"low"`, `"medium"`, or `"high"`)
- Conditional fields are checked only when the finding's `dimension` matches (e.g., `stale_location` is only required for `freshness` findings)

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

6. **Cycle tracking**: The calling skill is responsible for tracking cycle count and logging review history in whatever format it uses (ticket notes, review-log.md, etc.).

### Emit Review Result (post-Revision Protocol)

After the Revision Protocol resolves (either all dimensions pass, or cycles are exhausted and user input is applied), emit a final review event reflecting the outcome:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
".claude/scripts/dso" emit-protocol-review-result.sh \
  --review-type="<caller's review type>" \
  --pass-fail="<passed|failed, final outcome after revisions>" \
  --revision-cycles="<number of revision cycles consumed>"
```

This replaces the initial post-Stage 2 emission when revisions occurred (i.e., do not emit twice for the same review — emit once after Stage 2 if it passes immediately, or once here if the Revision Protocol was entered). Best-effort — a failure does not block the workflow.

---

## Quick Reference

```
Stage 1 (Mental)  → Caller self-reviews, fixes obvious issues
                     Skip if start_stage=2
Stage 2 (Single)  → One sub-agent, multi-perspective rubric
                     Returns REVIEW-SCHEMA.md JSON
Stage 3 (Conflict) → Triggered by non-empty conflicts[]
                     Escalate critical+major or higher to user
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
