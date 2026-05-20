# Phase E: Adversarial Review (loaded by /dso:preplanning when threshold gate passes)

**Trigger**: ≥ 3 stories exist after Phase C completes. Skipped under `--lightweight` (lightweight mode does not create stories).

## Threshold Gate

Skip this phase if fewer than 3 stories exist after Phase C completes. Adversarial review adds value only when there are enough stories for cross-story interactions to matter. If skipped, log: `"Adversarial review skipped: fewer than 3 stories (<N> stories)."` and proceed directly to Phase F.

## Step 1: Red Team Dispatch

Dispatch via `subagent_type: "dso:red-team-reviewer"` with `model: "opus"` passed explicitly (do not rely on the agent frontmatter default — the SC→DD coverage audit and cross-story taxonomy depend on opus-level sustained reasoning, and the explicit param defends against future routing changes that might silently downgrade). If the named type is unregistered in this session, fall back to `subagent_type: "general-purpose"` with `model: "opus"` and `agents/red-team-reviewer.md` content read inline as the prompt. Pass the following as task arguments:

- `mode: story_review`
- `{epic-title}`: Epic title from Phase A
- `{epic-description}`: Epic description from Phase A
- `{epic-success-criteria}`: The bullet items from the epic's `## Success Criteria` section, parsed from the ticket text (do NOT rely on session memory). Number them with stable identifiers in a Markdown list, e.g.:
  ```
  - sc-1: Users can export reviewed rules as Rego.
  - sc-2: Review state persists across sessions.
  - sc-3: An admin can audit who approved each rule.
  ```
  If the epic has no `## Success Criteria` section, pass `(none — epic has no Success Criteria section; coverage audit will be vacuous)` so the agent records the absence in `sc_coverage_summary` rather than failing.
- `{story-map}`: All stories with their done definitions, considerations, and dependencies (formatted from Phase C output)
- `{risk-register}`: Risk Register table from Phase C
- `{dependency-graph}`: Dependency graph from `.claude/scripts/dso ticket deps <epic-id>`

The red team sub-agent returns a JSON object with `sc_coverage_summary` (mandatory) and `findings` (may be empty) arrays. Parse the response and validate that:
1. `sc_coverage_summary` is present and is an array (an entry per SC passed in, with `sc_id`, `sc_text`, `verdict`, `covering_story_ids` fields; `gap_summary` present when verdict ≠ `fully_covered`).
2. `findings` is an array of objects with `type`, `target_story_id`, `title`, `description`, `rationale`, `taxonomy_category` fields; the `taxonomy_category` includes `sc_coverage_gap` for SC-traceability findings.
3. If the agent returns `{"findings": [], "error": "model_requirement_unmet"}`, treat this as a dispatch defect: log `"Red team model requirement unmet — re-dispatching with explicit model: opus"` and retry once with the fallback path (`general-purpose` + `model: "opus"` + inline prompt). If the retry also returns `model_requirement_unmet`, log and skip to Phase F.

**Fallback — two-path protocol**:
- **Agent unavailable** (dispatch fails with "Unknown agent" or similar): Read `agents/red-team-reviewer.md` inline and re-dispatch as a general-purpose agent with `model: "opus"` using that content as the prompt. Do NOT perform the review inline — the agent must do it.
- **Execution failure** (timeout, malformed output, missing `sc_coverage_summary`, or fails to produce valid JSON): Log a warning `"Red team review failed: <reason>. Skipping adversarial review, proceeding to Phase F."` and skip directly to Phase F.

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

Parse the blue team's accepted findings and apply each one based on its `type`. `taxonomy_category: "sc_coverage_gap"` findings use the same routing as their `type`, with one additional ticket-comment line citing the SC id for traceability.

| Finding Type | Action |
|-------------|--------|
| `new_story` | Create a new story with description: `.claude/scripts/dso ticket create story "<title>" --parent=<epic-id> -d "<body with description, done definitions, and considerations>"`. For `sc_coverage_gap` findings, append `Covers: <sc_id>` to the description body so the SC→story link is preserved in the ticket. |
| `modify_done_definition` | Use `.claude/scripts/dso ticket comment <target_story_id> "Done definition update: <description>"` to record the modified done definition. For `sc_coverage_gap` findings, prefix the comment with `[SC <sc_id>] ` so the comment thread carries the SC link. |
| `add_dependency` | Add the dependency: `.claude/scripts/dso ticket link <target_story_id> <dependency_id> depends_on` (extract dependency ID from the finding's description). |
| `add_consideration` | Use `.claude/scripts/dso ticket comment <target_story_id> "Consideration: <text>"` to append the consideration. |
| `escalate_to_epic` | The finding signals that a cross-story concern belongs at the epic level. Read the current epic description via `ticket show`, then use `.claude/scripts/dso ticket edit <epic-id> --description="<current-description>\n\nSC: <title> — <description>"` to append the new Success Criterion. Before emitting the escalation signal, check `sprint.max_replan_cycles` from config (default 2): if the current `replan_cycle_count` has already reached the limit, log `"escalate_to_epic: max_replan_cycles reached — recording SC but skipping REPLAN_ESCALATE"` and continue without escalating. Otherwise emit `REPLAN_ESCALATE: brainstorm EXPLANATION:<title>` to trigger brainstorm re-review of the updated epic scope before continuing. |

After applying findings, also post the SC coverage summary as a single ticket comment on the epic so the audit is visible in the epic timeline:
```bash
.claude/scripts/dso ticket comment <epic-id> "SC coverage audit (red team): <fully_covered_count> fully covered, <partially_covered_count> partial, <uncovered_count> uncovered, <out_of_scope_for_stories_count> out-of-scope. Full summary in adversarial review artifact."
```

Log a summary after applying findings:
```
Adversarial review complete:
- SC coverage: <fully> fully / <partial> partial / <uncovered> uncovered / <oos> out-of-scope-for-stories
- Red team findings: <N> total (<S> sc_coverage_gap, <O> other)
- Blue team filtered: <M> rejected, <K> accepted
- Applied: <A> new stories, <B> modified done definitions, <C> new dependencies, <D> new considerations
```

## Step 4: Persist Adversarial Review Exchange

After processing blue team findings, the orchestrator persists the full exchange for post-mortem analysis. The blue team agent does NOT write files (it cannot run shell commands) — it returns `artifact_path: null`, and the orchestrator handles persistence here using the red team's `sc_coverage_summary` + raw findings and the blue team's `findings`/`rejected` arrays.

1. Resolve the artifact path and write the full exchange JSON. The artifact must include the red team's `sc_coverage_summary` as a top-level key so the audit trail is preserved alongside the findings exchange:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   ARTIFACTS_DIR=$(get_artifacts_dir)
   ARTIFACT_PATH="$ARTIFACTS_DIR/adversarial-review-<epic-id>.json"
   # JSON shape:
   # {
   #   "sc_coverage_summary": [ ... from red team ... ],
   #   "red_team_findings": [ ... raw, unfiltered ... ],
   #   "blue_team_accepted": [ ... ],
   #   "blue_team_rejected": [ ... ]
   # }
   ```
2. Add a one-line ticket comment referencing the artifact:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Adversarial review: <N> findings, <M> accepted. Full exchange: $ARTIFACT_PATH"
   ```
3. If writing the artifact fails (disk full, permission error): log a warning and continue — persistence failure is non-blocking.
4. The artifact is available for future post-mortem analysis but is not surfaced in normal `ticket show` output.

## Step 5: Continue to Phase F

Proceed to Phase F (Walking Skeleton & Vertical Slicing) with the updated story map. New stories from adversarial review are included in the walking skeleton analysis.
