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

The red team sub-agent returns a JSON object. Parse and route in this order — do not reorder, the model-requirement check MUST run before schema validation so the error-envelope payload `{"findings": [], "error": "model_requirement_unmet"}` is not misclassified as "missing sc_coverage_summary":

<!-- VALIDATION-ORDER: model_requirement_unmet check FIRST, schema validation SECOND. Do not reorder — tests/test_adversarial_review_prompts.sh pins the order with these anchor comments. -->
<!-- VALIDATION-STEP-1: model_requirement_unmet -->
1. **Model-requirement check (first)**: if the response is `{"findings": [], "error": "model_requirement_unmet"}` (or otherwise carries an `"error"` field equal to `"model_requirement_unmet"`), treat this as a dispatch defect — log `"Red team model requirement unmet — re-dispatching with explicit model: opus"` and retry once via the fallback path (`general-purpose` + `model: "opus"` + inline prompt). If the retry also returns `model_requirement_unmet`, log `"Red team review skipped: model_requirement_unmet on retry. Proceeding to Phase F."` and skip directly to Phase F.
<!-- VALIDATION-STEP-2: schema-validation -->
2. **Schema validation (second)**: with the model-requirement branch ruled out, validate the full response shape:
   - `sc_coverage_summary` is present and is an array (one entry per SC passed in, with `sc_id`, `sc_text`, `verdict`, `covering_story_ids` fields; `gap_summary` present when verdict ∈ {`partially_covered`, `uncovered`, `out_of_scope_for_stories`}).
   - `findings` is an array of objects with `type`, `target_story_id`, `title`, `description`, `rationale`, `taxonomy_category` fields; the `taxonomy_category` enum includes `sc_coverage_gap` for SC-traceability findings.

**Fallback — two-path protocol**:
- **Agent unavailable** (dispatch fails with "Unknown agent" or similar): Read `agents/red-team-reviewer.md` inline and re-dispatch as a general-purpose agent with `model: "opus"` using that content as the prompt. Do NOT perform the review inline — the agent must do it.
- **Execution failure** (timeout, malformed output, missing `sc_coverage_summary`, or fails to produce valid JSON) — but NOT `model_requirement_unmet` (handled above): Log a warning `"Red team review failed: <reason>. Skipping adversarial review, proceeding to Phase F."` and skip directly to Phase F.

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

## Step 3: Persist Adversarial Review Exchange

The orchestrator persists the full exchange for post-mortem analysis AND so the artifact path is available to the Step 4 remediation re-dispatch (the re-dispatch payload references the artifact by absolute path — the file must exist on disk before the dispatch builds the `remediation_context`). The blue team agent does NOT write files (it cannot run shell commands) — it returns `artifact_path: null`, and the orchestrator handles persistence here using the red team's `sc_coverage_summary` + raw findings and the blue team's `findings`/`rejected` arrays.

1. Resolve the artifact paths and write the full exchange JSON. The artifact must include the red team's `sc_coverage_summary` as a top-level key so the audit trail is preserved alongside the findings exchange:
   ```bash
   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
   ARTIFACTS_DIR=$(get_artifacts_dir)
   ARTIFACT_PATH="$ARTIFACTS_DIR/adversarial-review-<epic-id>.json"
   # JSON shape:
   # {
   #   "sc_coverage_summary": [ ... from red team ... ],
   #   "red_team_findings": [ ... raw, unfiltered ... ],
   #   "blue_team_accepted": { "findings": [ ... ] },
   #   "blue_team_rejected": { "findings": [ ... ] }
   # }
   ```
   Also persist the red-team and blue-team artifacts to separate absolute paths so the Step 4 re-dispatch can reference both producers' outputs independently:
   ```bash
   RED_TEAM_ARTIFACT_PATH="$ARTIFACTS_DIR/adversarial-review-<epic-id>-red-team.json"
   BLUE_TEAM_ARTIFACT_PATH="$ARTIFACTS_DIR/adversarial-review-<epic-id>-blue-team.json"
   ```
2. Add a one-line ticket comment referencing the artifact:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Adversarial review: <N> findings, <M> accepted. Full exchange: $ARTIFACT_PATH"
   ```
3. If writing the artifact fails (disk full, permission error): log a warning and continue — persistence failure is non-blocking. (If the artifact write fails, the Step 4 re-dispatch MUST also be skipped: the dispatch payload would carry a dangling absolute path that the producer's pre-generation Read gate would fail on.)
4. The artifact is available for future post-mortem analysis but is not surfaced in normal `ticket show` output.

Also post the SC coverage summary as a single ticket comment on the epic so the audit is visible in the epic timeline:
```bash
.claude/scripts/dso ticket comment <epic-id> "SC coverage audit (red team): <fully_covered_count> fully covered, <partially_covered_count> partial, <uncovered_count> uncovered, <out_of_scope_for_stories_count> out-of-scope. Full summary in adversarial review artifact."
```

## Step 4: Remediation Re-Dispatch (replaces Step 3 — supersedes the deprecated mechanical-transcription path)

<!-- TOUCHPOINT-EMBEDDING-ANCHOR: phase-e-remediation-loop -->

**Option A pin — this section replaces Step 3 (which is now persistence-only)**: Earlier revisions of this prompt had a Step 3 named "Apply Surviving Findings" that mechanically transcribed every blue-team-accepted finding type (`new_story` / `modify_done_definition` / `add_dependency` / `add_consideration` / `escalate_to_epic`) into inline ticket-CLI calls at the orchestrator. That mechanical-transcription step is the anti-pattern that the parent epic eliminates. The previous "Apply Surviving Findings" responsibility is **superseded** by this Step 4 re-dispatch and is deprecated. The orchestrator MUST NOT also run the deprecated transcription path inline; the re-dispatch is in lieu of Step 3, never additive. (Step 3 in this revised prompt is renamed to artifact persistence only.)

**Null-case guard — BOTH branches MUST be preserved**:

- **(a) PRE-filter — red team returned zero findings**: This branch is handled by Step 2's existing skip — see the "Red team found no cross-story gaps. Skipping blue team filter." log. When the red-team `findings` array is empty, Steps 2–4 are ALL skipped and the orchestrator proceeds directly to Phase F. This branch MUST remain intact.
- **(b) POST-filter — blue team rejected everything (`blue_team_accepted.findings` is empty / `[]`)**: When the blue team filter accepts zero findings (every red-team finding is rejected), Phase E SKIPS the re-dispatch (null-case guard). Step 3 artifact persistence still completes (the empty exchange is recorded for audit), but Step 4 emits no Task call. Log: `"Blue team accepted zero findings (blue_team_accepted.findings is empty). Skipping remediation re-dispatch (null-case guard); proceeding to Phase F."` and continue to Phase F.

Case (a) skips Steps 2–4 entirely; case (b) only skips Step 4 (Step 3 still runs). The two branches MUST be preserved separately — a naive single-guard implementation would conflate the PRE-filter and POST-filter null cases.

**Re-dispatch (when `blue_team_accepted.findings` is non-empty)**:

1. **Extract unique `target_story_ids`** from the accepted findings:
   ```bash
   target_story_ids=$(jq -r '[.blue_team_accepted.findings[].target_story_id] | unique | join(",")' "$ARTIFACT_PATH")
   ```

2. **Build the by-reference `remediation_context` payload**. The payload references reviewer artifacts by **absolute file path** (red-team artifact path + blue-team artifact path) plus the extracted `target_story_ids` list. The payload MUST NOT embed finding bodies — the producer (dso:story-decomposer in DELTA OUTPUT mode) re-reads the artifacts at the absolute paths and quotes evidence from each before emitting drafts (pre-generation Read gate).

   The canonical payload shape is defined in `${CLAUDE_PLUGIN_ROOT}/docs/contracts/remediation-context-payload.md` — that document is the source of truth. Do NOT inline or duplicate the payload spec here; this prompt only references the contract by absolute path.

   Skeleton (the linked spec is authoritative for the full shape):
   ```json
   {
     "remediation_context": {
       "red_team_artifact_path": "<absolute path: $RED_TEAM_ARTIFACT_PATH>",
       "blue_team_artifact_path": "<absolute path: $BLUE_TEAM_ARTIFACT_PATH>",
       "target_story_ids": ["<id1>", "<id2>", ...]
     }
   }
   ```

3. **Dispatch dso:story-decomposer** with `subagent_type: "dso:story-decomposer"` and the literal `model: "opus"` field on the dispatch payload. The `model: "opus"` token MUST be present on the dispatch line so the synthetic-findings fixture catches accidental sonnet downgrade:
   ```
   Task(
     subagent_type: "dso:story-decomposer",
     model: "opus",
     prompt: <constructed-from-remediation_context>
   )
   ```
   If the named subagent_type is unregistered, fall back to `subagent_type: "general-purpose"` while still passing `model: "opus"` and `agents/story-decomposer.md` content read inline as the prompt.

4. **Instruct DELTA OUTPUT mode + evidence-quote in the dispatch prompt** (dispatch-block INSTRUCTIONS only — the producer's runtime output assertions are owned by sibling story a7c0). The dispatch prompt MUST instruct the sub-agent to:
   - Declare `DELTA OUTPUT` mode at the top of its response (literal token).
   - Quote evidence verbatim from each artifact path (one evidence quote per artifact) before emitting any story draft — the producer's pre-generation Read gate.
   - Emit only stories whose `target_story_id` appears in the passed `target_story_ids` list — NO full re-decomposition; absence of unlisted stories is a contract assertion that the fixture verifies.

5. **Merge the delta into the full story map.** After the sub-agent returns, parse the `DELTA OUTPUT` block and apply the following merge procedure to produce the authoritative updated story set: (a) take all prior `done_definitions` from `DECOMP_JSON` for each targeted story; (b) for DDs addressed by a finding, apply the modification specified in the finding; (c) for DDs NOT addressed by any finding, carry forward verbatim; (d) append new DDs introduced by the delta. Apply the merged result — the full `done_definitions` list is the union of carried-forward and delta entries. Stories outside the passed `target_story_ids` MUST be absent from the producer's response; if any unlisted stories appear, log a contract violation and discard them.

6. **Record a single ticket comment** on the epic referencing the dispatch (SC5 single-comment policy):
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Remediation re-dispatch (Phase E): dso:story-decomposer (model: opus) invoked with remediation_context referencing $RED_TEAM_ARTIFACT_PATH + $BLUE_TEAM_ARTIFACT_PATH; target_story_ids: $target_story_ids"
   ```

Log a summary after the re-dispatch returns:
```
Adversarial review complete:
- SC coverage: <fully> fully / <partial> partial / <uncovered> uncovered / <oos> out-of-scope-for-stories
- Red team findings: <N> total (<S> sc_coverage_gap, <O> other)
- Blue team filtered: <M> rejected, <K> accepted
- Remediation re-dispatch: <emitted | skipped (null-case guard)>; producer delta: <P> new stories, <Q> modified done definitions
```

## Step 5: Continue to Phase F

Proceed to Phase F (Walking Skeleton & Vertical Slicing) with the updated story map. New stories from adversarial review are included in the walking skeleton analysis.
