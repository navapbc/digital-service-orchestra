# Phase E: Adversarial Review (loaded by /dso:preplanning when threshold gate passes)

**Trigger**: ≥ 3 stories exist after Phase C completes. Skipped under `--lightweight` (lightweight mode does not create stories).

## Threshold Gate

Skip this phase if fewer than 3 stories exist after Phase C completes. Adversarial review adds value only when there are enough stories for cross-story interactions to matter. If skipped, log: `"Adversarial review skipped: fewer than 3 stories (<N> stories)."` and proceed directly to Phase F.

## Step 1: Red Team Dispatch

Dispatch via `subagent_type: "dso:red-team-reviewer"` (model defaults: opus). If the named type is unregistered in this session, fall back to `subagent_type: "general-purpose"` with `model: "opus"` and `agents/red-team-reviewer.md` content read inline as the prompt. The agent definition contains the full review prompt including the 6-category taxonomy and Consumer Enumeration directive. Pass the following as task arguments:

- `mode: story_review`
- `{epic-title}`: Epic title from Phase A
- `{epic-description}`: Epic description from Phase A
- `{story-map}`: All stories with their done definitions, considerations, and dependencies (formatted from Phase C output)
- `{risk-register}`: Risk Register table from Phase C
- `{dependency-graph}`: Dependency graph from `.claude/scripts/dso ticket deps <epic-id>`

The red team sub-agent returns a JSON `findings` array. Parse the response and validate it contains well-formed JSON with the expected schema (array of objects with `type`, `target_story_id`, `title`, `description`, `rationale`, `taxonomy_category` fields).

**Fallback — two-path protocol**:
- **Agent unavailable** (dispatch fails with "Unknown agent" or similar): Read `agents/red-team-reviewer.md` inline and re-dispatch as a general-purpose agent using that content as the prompt. Do NOT perform the review inline — the agent must do it.
- **Execution failure** (timeout, malformed output, or fails to produce valid JSON): Log a warning `"Red team review failed: <reason>. Skipping adversarial review, proceeding to Phase F."` and skip directly to Phase F.

## Step 2: Blue Team Dispatch

If the red team returns a non-empty findings array, dispatch via `subagent_type: "dso:blue-team-filter"` (model defaults: sonnet). If the named type is unregistered, fall back to `subagent_type: "general-purpose"` with `model: "sonnet"` and `agents/blue-team-filter.md` content read inline as the prompt. Pass the following as task arguments:

- `{epic-title}`: Same as red team
- `{epic-description}`: Same as red team
- `{story-map}`: Same as red team
- `{red-team-findings}`: The raw JSON findings array from the red team sub-agent

The blue team sub-agent returns a filtered JSON object with `findings` (accepted) and `rejected` arrays.

**If red team returned zero findings**: Skip the blue team dispatch entirely. Log: `"Red team found no cross-story gaps. Skipping blue team filter."` and proceed to Phase F.

**Partial failure — two-path protocol**:
- **Agent unavailable** (dispatch fails with "Unknown agent" or similar): Read `agents/blue-team-filter.md` inline and re-dispatch as a general-purpose agent using that content as the prompt. Do NOT perform the filtering inline — the agent must do it; inline filtering by the orchestrator defeats the purpose of the impartial blue team.
- **Execution failure** (timeout, malformed output, or error): **Discard all unfiltered findings** and proceed to Phase F. Do NOT apply unfiltered red team findings — the blue team filter exists to prevent false positives from polluting the story map. Log: `"Blue team filter failed: <reason>. Discarding unfiltered red team findings, proceeding to Phase F."`

## Step 3: Apply Surviving Findings

Parse the blue team's accepted findings and apply each one based on its `type`:

| Finding Type | Action |
|-------------|--------|
| `new_story` | Create a new story with description: `.claude/scripts/dso ticket create story "<title>" --parent=<epic-id> -d "<body with description, done definitions, and considerations>"`. |
| `modify_done_definition` | Use `.claude/scripts/dso ticket comment <target_story_id> "Done definition update: <description>"` to record the modified done definition. |
| `add_dependency` | Add the dependency: `.claude/scripts/dso ticket link <target_story_id> <dependency_id> depends_on` (extract dependency ID from the finding's description). |
| `add_consideration` | Use `.claude/scripts/dso ticket comment <target_story_id> "Consideration: <text>"` to append the consideration. |
| `escalate_to_epic` | The finding signals that a cross-story concern belongs at the epic level. Read the current epic description via `ticket show`, then use `.claude/scripts/dso ticket edit <epic-id> --description="<current-description>\n\nSC: <title> — <description>"` to append the new Success Criterion. Before emitting the escalation signal, check `sprint.max_replan_cycles` from config (default 2): if the current `replan_cycle_count` has already reached the limit, log `"escalate_to_epic: max_replan_cycles reached — recording SC but skipping REPLAN_ESCALATE"` and continue without escalating. Otherwise emit `REPLAN_ESCALATE: brainstorm EXPLANATION:<title>` to trigger brainstorm re-review of the updated epic scope before continuing. |

Log a summary after applying findings:
```
Adversarial review complete:
- Red team findings: <N> total
- Blue team filtered: <M> rejected, <K> accepted
- Applied: <A> new stories, <B> modified done definitions, <C> new dependencies, <D> new considerations
```

## Step 4: Persist Adversarial Review Exchange

After processing blue team findings, the orchestrator persists the full exchange for post-mortem analysis. The blue team agent does NOT write files (it cannot run shell commands) — it returns `artifact_path: null`, and the orchestrator handles persistence here using the red team findings and the blue team's `findings`/`rejected` arrays.

1. Resolve the artifact path and write the full exchange JSON:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   ARTIFACTS_DIR=$(get_artifacts_dir)
   ARTIFACT_PATH="$ARTIFACTS_DIR/adversarial-review-<epic-id>.json"
   # Write JSON combining the red team output and blue team findings/rejected arrays
   ```
2. Add a one-line ticket comment referencing the artifact:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Adversarial review: <N> findings, <M> accepted. Full exchange: $ARTIFACT_PATH"
   ```
3. If writing the artifact fails (disk full, permission error): log a warning and continue — persistence failure is non-blocking.
4. The artifact is available for future post-mortem analysis but is not surfaced in normal `ticket show` output.

## Step 5: Continue to Phase F

Proceed to Phase F (Walking Skeleton & Vertical Slicing) with the updated story map. New stories from adversarial review are included in the walking skeleton analysis.
