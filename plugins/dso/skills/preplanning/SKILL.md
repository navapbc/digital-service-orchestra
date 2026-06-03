---
name: preplanning
description: Use when breaking down an epic into user stories, story splitting, backlog grooming, defining acceptance criteria, or auditing and reconciling existing epic children before implementation. Dispatches an opus `dso:story-decomposer` sub-agent to draft prioritized vertical-slice user stories with measurable done definitions tied to epic Success Criteria (never inline), identifies dependencies, runs an adversarial red-team review pass, dispatches a UI designer for UI stories, and writes the story tickets to the tracker. Trigger phrases include 'break down this epic', 'split into stories', 'story splitting', 'backlog grooming', 'write user stories', 'define acceptance criteria', 'plan the epic', 'decompose the epic', 'reconcile epic children'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:preplanning requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

## Startup Configuration

At the very start of execution (immediately after passing the SUB-AGENT-GUARD check), read the interactive mode flag:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
PREPLANNING_INTERACTIVE=$(bash "$PLUGIN_SCRIPTS/read-config.sh" preplanning.interactive 2>/dev/null || echo 'true')  # shim-exempt: internal orchestration script
PREPLANNING_INTERACTIVE=$(echo "$PREPLANNING_INTERACTIVE" | tr '[:upper:]' '[:lower:]')
# Default: true (interactive) when the key is absent or empty
if [[ -z "$PREPLANNING_INTERACTIVE" ]]; then
  PREPLANNING_INTERACTIVE="true"
fi
```

Default is `true` (interactive) when the key is absent — new projects without the key should default to interactive mode. Only set `preplanning.interactive=false` in `.claude/dso-config.conf` for automated pipelines.

# Pre-Planning: High-Fidelity Story Mapping

Act as a Senior Technical Product Manager (Google-style) to audit, reconcile, and decompose a ticket Epic into prioritized User Stories with measurable Done Definitions that bridge the epic's vision to task-level acceptance criteria.


**Supports dryrun mode.** Use `/dso:dryrun /dso:preplanning` to preview without changes.

## Usage

```
/dso:preplanning                          # Interactive epic selection
/dso:preplanning <epic-id>                # Pre-plan specific epic
/dso:preplanning <epic-id> --lightweight  # Enrich epic without creating stories (used by /dso:sprint for MODERATE epics)
```

## Arguments

- `<epic-id>` (optional): The ticket epic to decompose. If omitted, presents an interactive list of open epics.
- `--lightweight` (optional): Enrich the epic with done definitions and considerations without creating child stories. Returns `ENRICHED` or `ESCALATED`. Used by `/dso:sprint` for MODERATE-complexity epics. If the scope scan discovers COMPLEX qualitative overrides, returns `ESCALATED` so the orchestrator can re-invoke in full mode.

## Process Overview

This skill transforms epics into implementable stories:

- **Entry routing** (Phase A Step 1.5): classify epic complexity (SIMPLE → `/dso:implementation-plan`; MODERATE → lightweight mode; COMPLEX → full preplanning). Skipped when `--lightweight` was explicitly passed.
- **Phase A**: Reconciliation — audit existing work, clarify scope
- **Phase B**: External Dependencies Reading (flag-gated) — read epic's External Dependencies block, generate manual:awaiting_user stories
- **Story Decomposition**: dispatch `dso:story-decomposer` (opus) to draft the new vertical-slice stories needed so the collective set covers every epic Success Criterion
- **Phase C**: Risk & Scope Scan — flag cross-cutting concerns, identify split candidates
- **Phase D**: Integration Research — verify external integrations pre-slicing
- **Phase E**: Adversarial Review — red/blue team review for cross-story blind spots (3+ stories only)
- **Refusal Gate**: External Dependencies coverage check (flag-gated) — halt if externally-shaped SCs lack block coverage
- **Phase F**: Walking Skeleton & Vertical Slicing — prioritize minimum viable path, Foundation/Enhancement splits
- **Phase G**: Story-Level Research — research per-story decomposition gaps post-slicing
- **Phase H**: Verification & Traceability — create stories, link criteria, validate, wireframe UI stories

**Lightweight mode** (`--lightweight`): runs an abbreviated subset (Phase A Step 1, abbreviated Phase C); see Lightweight Mode Appendix for the authoritative spec. Returns `ENRICHED` or `ESCALATED`.

---

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated, never blocks the skill):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/migrate-design-notes-to-design-md.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

---

## Scrutiny Gate

Before proceeding, check if the epic has a `scrutiny:pending` tag:

1. Run `.claude/scripts/dso ticket show <epic-id>` and check the `tags` field
2. If `scrutiny:pending` is present in the tags array: **HALT immediately**. Output:
   "This epic has not been through scrutiny review. Run `/dso:brainstorm <epic-id>` first to complete the scrutiny pipeline, then retry `/dso:preplanning`."
   Do NOT produce any planning output.
3. If `scrutiny:pending` is NOT present (or tags field is empty/absent): proceed normally.

This is a presence-based check — only block when the tag IS present. Existing epics without the tags field are NOT blocked.

---

## Interaction Conflict Gate

Before proceeding, check if the epic has an `interaction:deferred` tag:

1. Run `.claude/scripts/dso ticket show <epic-id>` and check the `tags` field
2. If `interaction:deferred` is present in the tags array: **HALT immediately**. Output:
   "This epic has unresolved cross-epic interaction conflicts. Resolve or override them in `/dso:brainstorm <epic-id>` before proceeding to `/dso:preplanning`."
   Do NOT produce any planning output.
3. If `interaction:deferred` is NOT present (or tags field is empty/absent): proceed normally.

This is a presence-based check — only block when the tag IS present. Existing epics without the tags field are NOT blocked.
<!-- EMIT-PRECONDITIONS: gate_name=preplanning_interaction_deferred_tag degradation_type=inferred_decision -->
If ticket show fails, treat the tag as absent and proceed (fail-open).

---

## UI Probes Deferred Gate

Before proceeding, check if the epic has a `ui_probes:deferred` tag:

1. Run `.claude/scripts/dso ticket show <epic-id>` and check the `tags` field
2. If `ui_probes:deferred` is present in the tags array: **HALT immediately**. Output:
   "This epic has unresolved UX probe gaps from a non-interactive brainstorm run. Re-run `/dso:brainstorm <epic-id>` interactively to complete the UX probe questions, then retry `/dso:preplanning`."
   Do NOT produce any planning output.
3. If `ui_probes:deferred` is NOT present (or tags field is empty/absent): proceed normally.

This is a presence-based check — only block when the tag IS present. Existing epics without the tags field are NOT blocked.
<!-- EMIT-PRECONDITIONS: gate_name=preplanning_ui_probes_tag degradation_type=inferred_decision -->
If ticket show fails, treat the tag as absent and proceed (fail-open).

---

### Preconditions Entry Gate (/dso:preplanning)

<!-- Schema reference: docs/designs/stage-boundary-preconditions/ -->

[Instructions for the LLM: Before Phase A Step 1, validate that a brainstorm PRECONDITIONS event exists.
Run: `.claude/scripts/dso preconditions-validator.sh <epic_id> brainstorm_complete [--event-file=<path if known>]`
(or use preconditions-record.sh invocation from brainstorm; fail-open if script not found)
If exit 0: continue. If exit 1: BLOCK with PRECONDITIONS_GATE_BLOCKED diagnostic.
If exit 2 (not found): BLOCK with "Run /dso:brainstorm first" message.
<!-- EMIT-PRECONDITIONS: gate_name=preplanning_preconditions_validator degradation_type=inferred_decision -->
Fail-open: if preconditions-validator.sh itself is not found (command not found), emit WARN and continue.
This gate is depth-agnostic — unknown fields in the event are ignored, not rejected.]

---

## Phase A: Reconciliation (/dso:preplanning)

### Step 1: Select and Load Epic (/dso:preplanning)

If `<epic-id>` was not provided:

**[CP1 non-interactive]** If `PREPLANNING_INTERACTIVE=false` and no `<epic-id>` was provided: log `INTERACTIVITY_DEFERRED: preplanning.interactive=false — no epic-id provided` and exit with error.

1. Run `.claude/scripts/dso ticket list --type=epic`
2. If no open epics exist, report and exit
3. Present epics to the user (if more than 5, show first 5 with option to see more)
4. Get user selection

Load the epic:
```bash
.claude/scripts/dso ticket show <epic-id>
```

### Step 1.5: Complexity Classification & Routing (/dso:preplanning)

Classify the epic's complexity to determine whether full preplanning is warranted, whether the epic should run in `--lightweight` mode, or whether the epic can skip preplanning entirely and route directly to `/dso:implementation-plan`.

**Skip this step entirely when `--lightweight` was passed as an explicit argument.** An explicit `--lightweight` flag is a deliberate caller choice (user or `/dso:sprint`) and must be honored without re-classification — continue to Step 2.

#### Step 1.5a: Dispatch Complexity Evaluator Agent

Dispatch the dedicated complexity evaluator agent. Read `agents/complexity-evaluator.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "haiku"`. Pass the epic ID as the argument and `tier_schema=SIMPLE`. (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` — the Agent tool only accepts built-in types.)

```
Agent tool:
  subagent_type: "general-purpose"
  model: "haiku"
  argument: <epic-id>
  context:
    tier_schema: SIMPLE
    success_criteria_count: <count of SC bullet items parsed from the epic description's `## Success Criteria` section>
    scenario_survivor_count: <count of scenarios surviving blue team filter from the epic's Planning Intelligence Log, or 0 if no scenario analysis was recorded>
```

Compute `success_criteria_count` by parsing the `## Success Criteria` section of the epic description (do NOT rely on session memory — the value must be derived from the ticket text). Read `scenario_survivor_count` from the `### Planning Intelligence Log` event in the epic (written by the canonical scrutiny pipeline during brainstorm); use 0 if the pipeline did not run scenario analysis.

<!-- EMIT-PRECONDITIONS: gate_name=preplanning_complexity_evaluator degradation_type=inferred_decision -->
If the agent fails or returns malformed JSON, log a warning and fall through to full preplanning (safe fallback — proceed to Step 2 in full mode).

#### Step 1.5b: Route Based on Classification

Apply the routing table below. **Always consult the table** — do NOT skip preplanning based on prose heuristics. Only SIMPLE epics bypass preplanning. (`tier_schema=SIMPLE` is the epic-level vocabulary per `agents/complexity-evaluator.md`, where the lowest tier is named SIMPLE rather than TRIVIAL.)

**Session-signal override** (applies before the routing table): If EITHER is true, override to COMPLEX regardless of evaluator output:
- `success_criteria_count ≥ 7` — count from the spec text (do NOT rely on session memory which may be lost after compaction)
- `scenario_survivor_count ≥ 10` — read from the Planning Intelligence Log, or re-count from the `## Scenario Analysis` section

Log the override: `"Epic classified as COMPLEX (session-signal override: <reason>) — continuing with full preplanning"`

| Classification | scope_certainty | Routing |
|---|---|---|
| SIMPLE | High (always) | Invoke `/dso:implementation-plan <epic-id>` and exit preplanning |
| MODERATE | High | Continue preplanning in lightweight mode (jump to Lightweight Mode Appendix) |
| MODERATE | Medium | Continue preplanning in lightweight mode (jump to Lightweight Mode Appendix) |
| MODERATE | Low | Promoted to COMPLEX by evaluator |
| COMPLEX | any | Continue preplanning in full mode (proceed to Step 2) |

**Rationale**: SIMPLE epics route directly to `/dso:implementation-plan` — the brainstorm dialogue produced task-level detail. MODERATE+High/Medium runs a risk/scope scan and writes structured done definitions before implementation planning. MODERATE+Low is converted to COMPLEX by the evaluator (row listed for completeness). COMPLEX epics require full story decomposition.

#### Step 1.5c: Apply Routing

Output the classification line and apply the routing **in the same response** — do not yield to the user:

```
Epic classified as <TIER> (scope_certainty: <HIGH|MEDIUM|LOW>) — <action>
```

Then immediately (same response, no pause):

- **SIMPLE**: Invoke `/dso:implementation-plan` via the Skill tool with `args: "<epic-id>"`. Exit preplanning — do NOT proceed to Step 2. Control returns here only if the invoked skill escalates.
- **MODERATE** (High or Medium): Treat as if `--lightweight` was passed for the remainder of execution; jump to the **Lightweight Mode Appendix**. Do NOT proceed to Step 2 (lightweight mode skips escalation policy selection anyway).
- **COMPLEX** (or any session-signal override): Continue to Step 2 in full mode.

### Step 2: Select Escalation Policy (/dso:preplanning)

**[CP2 non-interactive]** If `PREPLANNING_INTERACTIVE=false`: skip `AskUserQuestion`, default `{escalation_policy_label} = "Escalate when blocked"` (full text from Phase H Step 2 table), and continue.

Use `AskUserQuestion` to ask the user which escalation policy should apply to all stories in this epic. Skip this step in `--lightweight` mode.

- **Question**: "Which escalation policy should agents apply when working on stories in this epic?"
- **Header**: "Escalation"
- **Options**:
  1. **Autonomous** — Agents proceed with best judgment at all times. Reasonable assumptions are made and documented. No escalation for uncertainty.
  2. **Escalate when blocked** — Agents proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. All assumptions made without escalating are documented.
  3. **Escalate unless confident** — Agents escalate whenever high confidence is absent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

Store the selected policy label and its full text as `{escalation_policy_label}` and `{escalation_policy_text}` for use in Phase H Step 2.

### Lightweight Mode Gate (/dso:preplanning)

If `--lightweight` was passed: jump to the **Lightweight Mode Appendix** (single authoritative source). Do not continue with Phase A Steps 3–5 or any subsequent phase.

If `--lightweight` was NOT passed, continue to Phase A Step 3.

Source the planning flag helper now to determine whether External Dependencies processing is enabled:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh"
```

If `is_external_dep_block_enabled` returns exit 1 (flag absent or `false`), set `EXTERNAL_DEP_BLOCK_ENABLED=false` — Phase B will be skipped. When the function returns exit 0, set `EXTERNAL_DEP_BLOCK_ENABLED=true`.

### Step 3: Audit Existing Children (/dso:preplanning)

Gather all existing child items:
```bash
.claude/scripts/dso ticket deps <epic-id>
```

For each child, run `.claude/scripts/dso ticket show <child-id>` to read full details.

### Step 4: Reconcile Existing Work (/dso:preplanning)

```
For each existing child:
  completed    → Keep as-is
  in_progress  → Review for reuse
  pending      → Fits new vision? Yes: Keep | No: Modify | Conflict: Delete
```

For each existing child, classify it:
- **Reuse**: Child aligns with the epic's success criteria and can be used as-is
- **Modify**: Child is partially relevant but needs updated description or success criteria
- **Delete**: Child conflicts with the epic's vision or is redundant

**Important**: If boundaries are unclear or if existing tasks conflict with the new vision, pause and ask:
- "Tell me more about the intended scope for [Feature]... should it include [X]?"
- "I see existing tasks for [Y]. Should these be absorbed into our new story map or kept separate?"

**[CP3 non-interactive]** If `PREPLANNING_INTERACTIVE=false` and scope clarification is required: log `INTERACTIVITY_DEFERRED: preplanning.interactive=false — scope clarification required` and exit with error.

### Step 5: Document Reconciliation Plan (/dso:preplanning)

Before creating new stories, present a reconciliation summary:

| Child ID | Title | Status | Recommendation | Rationale |
|----------|-------|--------|----------------|-----------|
| xxx-123 | ... | pending | Reuse | Aligns with Epic criterion 1 |
| xxx-124 | ... | in_progress | Modify | Needs updated success criteria |
| xxx-125 | ... | pending | Delete | Redundant with new story approach |

**[CP4 non-interactive]** If `PREPLANNING_INTERACTIVE=false`: auto-apply reconciliation (skip `AskUserQuestion`); **in-progress guard**: do NOT auto-apply Delete on `in_progress` children — skip and log `"Skipping Delete for in_progress story <id> — manual review required."`; continue.

Use `AskUserQuestion` to get user approval before proceeding:
- Question: "The reconciliation plan above summarizes how existing children will be handled. Do you approve this plan?"
- Options: ["Approve — proceed with story creation", "Request changes"]

If the user requests changes, iterate on the reconciliation plan and re-present.

---

## Phase B: External Dependencies Reading (/dso:preplanning)

**Skip this phase when `EXTERNAL_DEP_BLOCK_ENABLED=false`.**

### Purpose

After auditing existing children (Phase A Step 3), read the parent epic's `## External Dependencies` block (conforming to `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`) and generate the corresponding child stories.

### Reading the Block

Parse the epic's description field for a YAML block under the `## External Dependencies` heading. If no block exists, skip this phase entirely and proceed to Phase C.

**Validation**: For each entry, if `confirmation_token_required: true` is present alongside a `verification_command`, log a warning and ignore `confirmation_token_required`: `"Entry <name>: confirmation_token_required is only meaningful when verification_command is absent — ignoring."` Do not block story creation.

### Idempotency Check

Before creating any story for a block entry, get the epic's current children:

```bash
.claude/scripts/dso ticket deps <epic-id>
```

Parse the `children` field from the JSON output (not `deps` or `blockers`). Check whether any child is already tagged `manual:awaiting_user` with a title matching the entry's `name` field. If a match is found, skip creation for that entry to avoid duplicates. Log: `"Skipping <name> — existing manual:awaiting_user story already created (idempotency)."`

### Story Generation

For each entry in the `external_dependencies` block:

**`handling: claude_auto` entries:**
- Create a standard automation story as a child of the epic (same Phase H story creation flow).
- Story title: `"Verify and integrate <name>"`.
- Done definition: verification_command passes and Claude has confirmed access.

**`handling: user_manual` entries:**
- Create a story tagged `manual:awaiting_user` as a child of the epic.
- Story title: `"Complete manual step: <name>"`.
- Done definitions must include:
  - The entry's `justification` field verbatim (if present, explain why the step requires human action).
  - If `verification_command` is present: the command as the verification step.
  - If `verification_command` is absent: a confirmation-token prompt using `confirmation_token_required` (if `true`) or a simple acknowledgment (if `false` or absent).

---

## Story Decomposition (/dso:preplanning)

<!-- EMIT-PRECONDITIONS: gate_name=preplanning_story_decomposition degradation_type=unresolved_question -->

**Purpose.** The orchestrator MUST NOT draft new stories inline. After reconciliation (Phase A) and external-dependency story generation (Phase B), dispatch the `dso:story-decomposer` opus sub-agent to produce the new vertical-slice story drafts needed so the collective story set covers every epic Success Criterion. The orchestrator writes the drafts to the tracker in Phase H — this phase only produces the drafts.

**Rationale.** Inline drafting by the orchestrator has been observed to produce under-specified Done Definitions and to drop SCs through summarization. Dispatching a dedicated opus sub-agent (mirroring the Phase E red-team and the sprint-tier opus arbiter) restores sustained multi-document reasoning for the highest-leverage step in preplanning.

### Skip Condition

Skip this phase entirely when running under `--lightweight` (lightweight mode does not create stories — see the Lightweight Mode Appendix).

### Dispatch

> **Named-agent dispatch invariant**: Attempt dispatch via `subagent_type: "dso:<agent-name>"` first. Read the agent file (e.g., `agents/<agent-name>.md`) and pass its content inline **only** when the dispatch returns an "Unknown agent" or "agent type not registered" error in the current session. Reading the agent file before the dispatch attempt wastes context tokens, leaks agent internals into the orchestrator window, and inverts the fallback contract. Exception: agents documented as "NOT a valid `subagent_type` value" (e.g., `dso:complexity-evaluator`) always use `general-purpose` + inline read — no named dispatch to attempt.

<!-- EMIT-PRECONDITIONS: gate_name=preplanning_story_decomposer_dispatch degradation_type=inferred_decision -->
Dispatch via `subagent_type: "dso:story-decomposer"` with `model: "opus"` passed explicitly (do not rely on the agent frontmatter default — vertical slicing, INVEST-checking, and SC-coverage decomposition require opus, and the explicit param defends against future routing changes that might silently downgrade). If the named type is unregistered in this session, fall back to `subagent_type: "general-purpose"` with `model: "opus"` and `agents/story-decomposer.md` content read inline as the prompt.

Pass the following as task arguments:

- `{epic-title}`: Epic title from Phase A
- `{epic-description}`: Epic description from Phase A
- `{epic-success-criteria}`: Bullet items from the epic's `## Success Criteria` section parsed from the ticket text (do NOT rely on session memory). Number them with stable identifiers in a Markdown list, e.g.:
  ```
  - sc-1: Users can export reviewed rules as Rego.
  - sc-2: Review state persists across sessions.
  - sc-3: An admin can audit who approved each rule.
  ```
  If the epic has no `## Success Criteria` section, pass `(none — epic has no Success Criteria section)` so the agent records the absence in `decomposition_notes` and returns empty drafts rather than fabricating SCs.
- `{epic-closure-checks}`: Bullet items from the epic's `## Closure Checks` section parsed from the ticket text (do NOT rely on session memory). Number them with stable identifiers `cc-1, cc-2, ...` analogously to SCs:
  ```
  - cc-1: The reviewer registry rejects duplicate registrations at startup.
  - cc-2: All closed child stories have a DSO-Story-Merge trailer reachable from HEAD.
  ```
  If the epic has no `## Closure Checks` section, pass `(none — epic has no Closure Checks section)`. The agent will return an empty (or omitted) `cc_coverage_plan` in that case. Stories that validate a CC use the `← Validates Closure Check: "<verbatim CC text>"` DD annotation form (in addition to or instead of `← Satisfies: sc-N`).
- `{existing-stories}`: The kept-or-modified children from Phase A reconciliation. For each, include id, title, description, current Done Definitions, and considerations. Format as a Markdown list with one entry per story.
- `{external-dep-stories}`: The `manual:awaiting_user` stories created in Phase B. Same format as `{existing-stories}`. If Phase B was skipped (flag off or no entries), pass `(none)`.
- `{escalation-policy}`: Both the `{escalation_policy_label}` from Phase A Step 2 and its full text, so the agent can write the label verbatim into every draft's `escalation_policy` field for Phase H.
- `SCRATCH_TICKET_ID`: The epic ticket id (the `<epic-id>` value for this preplanning run) — the sub-agent uses this to namespace the scratch write.
- `SCRATCH_KEY`: The literal string `preplanning:step4:story-decomp-draft` — the sub-agent uses this as the scratch key when writing its output.

**Sub-agent output contract** (include verbatim in the dispatched prompt):

```xml
<output_contract>
You MUST write your full JSON output (sc_coverage_plan, story_drafts, decomposition_notes) to
the ticket scratch store before returning, using the SCRATCH_TICKET_ID and SCRATCH_KEY values
provided:

  bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" set "$SCRATCH_TICKET_ID" "$SCRATCH_KEY" "<your-json-output>"  # shim-exempt: sub-agent instruction block

After writing, return ONLY a 3-field receipt JSON — do NOT embed the draft body in your return block:

  {"ticket_id": "<SCRATCH_TICKET_ID>", "key": "<SCRATCH_KEY>", "byte_count": <N>}

where byte_count is the byte length of the JSON payload you wrote.

NEGATIVE EXAMPLE (contract violation — do NOT do this):
  {"ticket_id": "...", "key": "...", "byte_count": 4096, "story_drafts": [...]}
  ^^^ Extra fields beyond the 3-field envelope are a contract violation and will
      cause RECEIPT_PARSE_ERROR on the orchestrator side.

NEGATIVE EXAMPLE (contract violation — do NOT do this):
  Here are the story drafts: sc_coverage_plan: [...], story_drafts: [...]
  ^^^ Returning the draft body inline (not via scratch) is a contract violation.
      A SCRATCH_MISS on the orchestrator side is NOT a fallback signal to send
      the payload inline — it is a hard error requiring the agent to be re-dispatched.
</output_contract>
```

### Parse Output (Receipt-Only Contract)

After the sub-agent returns, validate its receipt via `receipt-parse.sh` before reading any payload:

```bash
# Prompt Alignment Finding 1: receipt validation co-located with the read site
PARSE_RESULT=$(printf '%s' "<sub-agent-return-block>" | \
    bash "$PLUGIN_SCRIPTS/receipt-parse.sh" preplanning:step4 dso:story-decomposer)  # shim-exempt: sub-agent instruction block
PARSE_EXIT=$?
if [ "$PARSE_EXIT" -ne 0 ]; then
    # RECEIPT_PARSE_ERROR — halt workflow; structured error already logged to stderr by receipt-parse.sh
    # Inline cleanup: remove any partial scratch written before the failure
    bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID" "preplanning:step4:story-decomp-draft" 2>/dev/null || true  # shim-exempt: sub-agent instruction block
    echo "HALT: story decomposer returned a malformed receipt — see RECEIPT_PARSE_ERROR above. Re-dispatch the sub-agent to fix the return contract before continuing." >&2
    exit 1
fi
# Extract ticket_id and key from the validated receipt
SCRATCH_TICKET_ID_OUT=$(echo "$PARSE_RESULT" | awk '{print $1}')
SCRATCH_KEY_OUT=$(echo "$PARSE_RESULT" | awk '{print $2}')

# Retrieve the payload from scratch
SCRATCH_RESULT=$(bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" get "$SCRATCH_TICKET_ID_OUT" "$SCRATCH_KEY_OUT")  # shim-exempt: sub-agent instruction block
SCRATCH_STATUS=$(echo "$SCRATCH_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")

# Prompt Alignment Finding 1: SCRATCH_MISS guard co-located with the get call
if [ "$SCRATCH_STATUS" != "hit" ]; then
    # SCRATCH_MISS — hard error; do NOT fall back to accepting inline payload  # precondition-emit-ok: negation, no degradation event
    # Inline cleanup: no payload to remove, but clear any stale key
    bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID_OUT" "$SCRATCH_KEY_OUT" 2>/dev/null || true  # shim-exempt: sub-agent instruction block
    echo "HALT: scratch key '$SCRATCH_KEY_OUT' not found for ticket '$SCRATCH_TICKET_ID_OUT' (status=$SCRATCH_STATUS). A SCRATCH_MISS is not a signal to accept an inline payload — re-dispatch the sub-agent." >&2
    exit 1
fi
DECOMP_JSON=$(echo "$SCRATCH_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
```

The retrieved `DECOMP_JSON` is a JSON object with `sc_coverage_plan`, `story_drafts`, and `decomposition_notes`. Validate:

1. `sc_coverage_plan` is an array with one entry per SC passed in. Every entry has `sc_id`, `sc_text`, `verdict`, `covering_story_ids`, `draft_ids` fields; `gap_summary` is present when `verdict` ∈ {`partial_coverage`, `uncovered`, `out_of_scope_for_stories`} — must match the agent's field-table condition so a regression that drops `gap_summary` on `uncovered` SCs is caught at validation time.
2. `story_drafts` is an array. Each draft has `temp_id` (matching the pattern `draft-N`), `title` (user-story-shaped), `priority` (integer 0–4), `description`, `done_definitions` (each ending with `← Satisfies: sc-N`), `depends_on`, `split_candidate`, and `escalation_policy`.
3. Every SC with verdict `uncovered` or `partial_coverage` is referenced by at least one draft (cross-check: the SC's `sc_id` appears in at least one DD's `← Satisfies: sc-N` annotation, and at least one `draft_id` for that SC is non-empty).
4. Every draft's `depends_on` references either an existing story id or another `temp_id` in this same response — no dangling references.

<!-- EMIT-PRECONDITIONS: gate_name=preplanning_story_decomposer_model_retry degradation_type=inferred_decision -->
**On `model_requirement_unmet`**: If the scratch payload carries `{"story_drafts": [], "sc_coverage_plan": [], "error": "model_requirement_unmet"}`, log `"Story decomposer model requirement unmet — re-dispatching with explicit model: opus"` and retry once via the fallback path (`general-purpose` + `model: "opus"` + inline prompt). If the retry also returns `model_requirement_unmet`, HALT preplanning with diagnostic: `"Story decomposition requires opus; configure the environment to allow opus dispatch and re-run /dso:preplanning."` Do NOT fall back to inline drafting. <!-- precondition-emit-ok: negation, HALT not degradation -->

**On schema validation failure**: HALT preplanning with diagnostic: `"Story decomposer returned malformed output; cannot proceed without verified drafts."` Do NOT fall back to inline drafting — inline drafting is the failure mode this phase exists to prevent.  <!-- precondition-emit-ok: negation — HALT, no degradation event -->
<!-- EMIT-PRECONDITIONS landmark above also covers this section per the within-10-lines rule. -->

**Why halt (not skip-and-continue) here, while Phase E falls through to Phase F on failure?** Story decomposition is a **correctness gate**: every subsequent phase consumes its output, and inline orchestrator drafting (the only available fallback) is the bug class this phase was introduced to eliminate. Phase E's adversarial review is a **quality gate** with a defined skip path — losing it degrades coverage but does not break downstream phases. The asymmetry is intentional.

### Persist the Decomposition Artifact

The full decomposition JSON is already stored in scratch under key `preplanning:step4:story-decomp-draft`. Post a one-line ticket comment on the epic for visibility:

```bash
.claude/scripts/dso ticket comment <epic-id> "Story decomposition: <N> drafts produced. Coverage: <fully> existing / <new_drafts> new / <oos> out-of-scope. Payload stored in scratch key preplanning:step4:story-decomp-draft."
```

After Phase H creates the story tickets from the drafts, clear the scratch key:

```bash
bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID" "preplanning:step4:story-decomp-draft"  # shim-exempt: sub-agent instruction block
```

### Feed Downstream Phases

- Phase C scans the union of (existing stories from Phase A) + (external-dep stories from Phase B) + (drafts from this phase). Drafts identified as `split_candidate: true` here are pre-flagged; Phase C may add more. Read drafts from `DECOMP_JSON` (already retrieved from scratch above).
- Phase E's red-team receives the same draft set and re-audits SC coverage at the cross-story level; the two audits are intentionally redundant — decomposition is the constructive step, the red team is the adversarial check. Pass `DECOMP_JSON` directly — do not re-read from scratch.
- Phase F's Walking Skeleton step uses the `priority` ordering produced here as its starting point. Read from `DECOMP_JSON`.
- Phase H Step 1 creates tickets from the drafts via `.claude/scripts/dso ticket create`, copying `title`, `description`, `done_definitions`, `considerations`, `depends_on`, `priority`, and `escalation_policy` into the ticket body. Read from `DECOMP_JSON`; clear scratch after all tickets are written.

---

## Phase C: Risk & Scope Scan (/dso:preplanning)

Scan all drafted stories (new drafts from the Story Decomposition phase, plus modified children from Phase A, plus external-dep stories from Phase B) as a batch to flag cross-cutting concerns that individual tasks would be too granular to catch. This is a lightweight analysis — no sub-agent dispatch, no scored review, no revision cycles.

### Concern Areas

| Area | Reviewer File | What to flag |
|------|--------------|--------------|
| Security | [docs/reviewers/security.md](docs/reviewers/security.md) | New endpoints, data exposure, auth boundaries |
| Performance | [docs/reviewers/performance.md](docs/reviewers/performance.md) | Large data processing, new queries, batch operations |
| Accessibility | [docs/reviewers/accessibility.md](docs/reviewers/accessibility.md) | New interactive pages, UI flows, form elements |
| Testing | [docs/reviewers/testing.md](docs/reviewers/testing.md) | New LLM interactions, external integrations, complex state |
| Reliability | [docs/reviewers/reliability.md](docs/reviewers/reliability.md) | New failure points, external dependencies, data integrity |
| Maintainability | [docs/reviewers/maintainability.md](docs/reviewers/maintainability.md) | Cross-cutting patterns, shared abstractions, documentation gaps |

Evaluate the full set of stories against all six areas. Examples of flags to raise:

- Security: "Story X exposes a new API — authentication coverage needed"
- Performance: "Story Y processes user uploads — consider batch size and timeout behavior"
- Accessibility: "Story Z adds a new interactive page — WCAG 2.1 AA compliance required"
- Testing: "Stories X and Y introduce a new LLM interaction — ensure mock-compatible interface"
- Reliability: "Story W depends on an external API — consider graceful degradation"
- Maintainability: "Stories X and Z both need similar data validation — consider a shared pattern"

### Output

Produce a **Risk Register** — a flat list of one-line flags, each referencing the affected story IDs:

```
| # | Area | Stories | Concern |
|---|------|---------|---------|
| 1 | Testing | X, Y | New LLM interaction — ensure mock-compatible interface |
| 2 | Performance | Y | Large file processing — consider timeout behavior |
| 3 | Accessibility | Z | New interactive page — WCAG 2.1 AA compliance |
```

Flags are added to the affected stories' descriptions as **Considerations** — context for `/dso:implementation-plan` to incorporate into task-level acceptance criteria. They are not hard requirements at the story level.

### Split Candidates

While scanning, flag stories where scope risk is high — stories where the minimum functional goal (walking skeleton) and the ideal implementation diverge significantly. Common indicators:

- Significant UI work where design may propose an ambitious overhaul
- New architectural patterns where a simpler interim approach could deliver value first
- New infrastructure or integrations where a lightweight version proves the concept

Mark these stories as **split candidates**. Phase F evaluates whether a Foundation/Enhancement split actually makes sense (see "Foundation/Enhancement Splitting" below).

---

## Phase D: Integration Research (/dso:preplanning)

After story decomposition and risk scanning, research integration capabilities for stories that involve external tools or services. This step surfaces verified constraints while the user is engaged and can redirect.

### Qualification

A story qualifies for integration research if it references any of:
- Third-party CLI tools
- External APIs/services
- CI/CD workflow changes
- Infrastructure provisioning
- Data format migrations
- Authentication/credential flows

### Research Process

Follow the shared research procedure in `prompts/research-process.md` (single authoritative source — covers researchFindings dedup, the WebSearch-and-verify steps, per-command contract check for CLI tools, REPLAN_ESCALATE emission, and graceful degradation). This phase is the pre-slicing trigger for that procedure. Track `feasibility_cycle_count` (state variable exposed for planning-intelligence log consumption) per the shared procedure. # precondition-emit-ok

### Skip Condition

<!-- EMIT-PRECONDITIONS: gate_name=preplanning_integration_research degradation_type=unresolved_question -->
If no stories in the plan qualify for integration research, log: "No stories with external integration signals — skipping integration research." and proceed to Phase E.

---

## Phase E: Adversarial Review (branch — ≥3 stories; skipped under --lightweight)

<!-- EMIT-PRECONDITIONS: gate_name=preplanning_adversarial_review degradation_type=unresolved_question -->
**Trigger**: Phase C completed and the story map has ≥ 3 stories. If fewer, log `"Adversarial review skipped: fewer than 3 stories (<N> stories)."` and proceed directly to Phase F. Skipped entirely under `--lightweight` (lightweight mode does not create stories).

**Load**: `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/prompts/phase-e-adversarial-review.md` and follow it. The phase dispatches `dso:red-team-reviewer` (opus, passed explicitly via `model: "opus"`) with `mode: story_review` to (a) audit that every epic Success Criterion is fully covered by the collective story Done Definitions and (b) perform cross-story gap analysis. The red team returns a mandatory `sc_coverage_summary` block plus a `findings` array tagged with the 8-value `taxonomy_category` enum (including `sc_coverage_gap`). `dso:blue-team-filter` (sonnet) then triages the findings; surviving findings are applied per the Finding Type table (`new_story`, `modify_done_definition`, `add_dependency`, `add_consideration`, `escalate_to_epic`); the full exchange — `sc_coverage_summary` + red/blue findings — is persisted to `$ARTIFACTS_DIR/adversarial-review-<epic-id>.json`; and `REPLAN_ESCALATE: brainstorm` is emitted when a finding escalates to the epic and `sprint.max_replan_cycles` has not been exhausted.

**Re-dispatch loop (b345 block — Phase E remediation loop protocol)**

When `dso:blue-team-filter` returns non-empty findings, the orchestrator enters a remediation loop governed by the shared protocol below. Source `MAX_CYCLES` from `get_max_remediation_cycles()` in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` before entering the loop.

**Per-cycle declaration**: At the start of every remediation cycle, emit exactly:
`Current cycle: N of MAX_CYCLES`
where `N` is the 1-based cycle counter and `MAX_CYCLES` is the resolved maximum. This line is required before any findings, deltas, or token emissions within that cycle.

**Oscillation-check hard gate (cycle >= 2)**: On any cycle where `N >= 2`, the orchestrator MUST invoke `/dso:oscillation-check` (Skill) before proceeding with findings analysis. Skipping this gate requires an explicit `OSCILLATION_CHECK_SKIPPED: <reason>` ticket comment capturing the rationale; no other skip reason is permitted.

**Mid-loop success exit**: If `dso:blue-team-filter` returns empty findings on any cycle (before reaching `MAX_CYCLES`), the loop exits immediately and Phase E proceeds to Phase F. No terminal token is emitted on success.

**HALT-vs-REPLAN exclusivity check**: `REPLAN_ESCALATE` MUST be emitted IFF `cycle_count == MAX_CYCLES AND findings non-empty`. No other condition may emit `REPLAN_ESCALATE`. All other terminal states use a different token — human-input required → `HALT_FOR_USER`; oscillation detected → `OSCILLATION_HALT`; illegal state transition → `PROTOCOL_ERROR`. Emitting `REPLAN_ESCALATE` under any other condition, or emitting it together with `PROTOCOL_ERROR`, is itself a `PROTOCOL_ERROR`.

**Terminal REPLAN_ESCALATE**: On cycle `MAX_CYCLES` with findings still non-empty, emit (per the canonical `${CLAUDE_PLUGIN_ROOT}/docs/contracts/replan-escalate-signal.md` colon-space prefix):
`REPLAN_ESCALATE: brainstorm EXPLANATION:<explanation text>`
The upstream for preplanning Phase E is `brainstorm` (per the upstream enum in Section 6 of the protocol doc). Emit this as a standalone ticket comment so the orchestrator's parent session can detect and route the escalation. The literal prefix `REPLAN_ESCALATE: ` (colon followed by a single space) and the `EXPLANATION:` field label are fixed by contract — do not vary them.

**PROTOCOL_ERROR on invariant violation**: Any illegal state transition — emitting `REPLAN_ESCALATE` when `cycle_count < MAX_CYCLES`, emitting multiple terminal tokens, or violating the HALT-vs-REPLAN exclusivity invariant — MUST emit `PROTOCOL_ERROR` and halt remediation immediately.

See: `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md`

**Per-cycle artifact append (084d/83d4 block — cycle recorder)**

After each cycle's re-dispatch and review, atomically append a `cycles[]` entry to the adversarial-review artifact using the writer:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/append_review_cycle.py" \  # shim-exempt: sub-agent instruction block
  --artifact "$ARTIFACTS_DIR/adversarial-review-<epic-id>.json" \
  --n <cycle-number> \
  --draft-hash <sha256 of DELTA OUTPUT block> \
  --findings-count <int> \
  --verdict <pass|fail|escalate>
```

After the append, emit exactly ONE ticket comment per cycle that references the artifact path:

```bash
.claude/scripts/dso ticket comment <ticket-id> "Remediation cycle <n> recorded at $ARTIFACTS_DIR/adversarial-review-<epic-id>.json"
```

**Single-comment policy (SC5)**: The ticket comment references the artifact path and does NOT duplicate the cycle body — cycle entries live in the artifact's `cycles[]` array, not in ticket comments. One comment per cycle; no further detail in the comment body.

---

## Refusal Gate: External Dependencies Block Check (/dso:preplanning)

**Skip this gate when `EXTERNAL_DEP_BLOCK_ENABLED=false`.**

Before proceeding to Phase F story decomposition, check whether the parent epic's External Dependencies block adequately covers any externally-shaped Success Criteria.

### When to fire

This gate fires when ALL of the following are true:
- `planning.external_dependency_block_enabled` is on (set during Phase B flag check)
- The epic has Success Criteria that are externally-shaped (their outcomes are observable only in deployed or external contexts — e.g., "users can log in with OAuth", "emails are delivered", "the API responds to external callers")

### Gate check

1. Identify externally-shaped SCs from the epic's Success Criteria list (SCs whose pass/fail depends on an external system, credential, or deployed environment).
2. For each externally-shaped SC, check whether the parent epic's `## External Dependencies` block contains an entry covering that dependency.
3. If ANY externally-shaped SC has no matching block entry (block is missing or the relevant entry is absent or incomplete per the schema in `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`):
   - **HALT decomposition.** Do not proceed to Phase F.
   - Emit the following diagnostic, naming the specific SC(s) without block coverage:
     > "Preplanning cannot decompose this epic: the following success criteria are externally-shaped but have no corresponding entry in the External Dependencies block: [list of SC names]. Run `/dso:brainstorm <epic-id>` to capture the dependency information, then retry `/dso:preplanning`."
4. If all externally-shaped SCs have valid block entries (or there are no externally-shaped SCs): proceed to Phase F normally.

### Behavioral testing note

SKILL.md is a non-executable LLM instruction file. The structural tests verify only that this section heading exists. Behavioral correctness of the refusal logic is probabilistic per Rule 5 (behavioral-testing-standard.md).

---

## Phase F: Walking Skeleton & Vertical Slicing (/dso:preplanning)

### Step 1: Identify the Walking Skeleton (/dso:preplanning)

The Walking Skeleton is the absolute minimum end-to-end path required to prove the technical concept.

Ask: "What is the simplest possible flow that demonstrates this feature works?"

**Prioritize these stories first** - they unblock all downstream work.

### Step 2: Apply INVEST Framework (/dso:preplanning)

Each story must satisfy **INVEST** — Independent, Negotiable, Valuable, Estimable, Small (one sub-agent session), Testable. For any story that fails one principle: add dependencies/split (I), remove implementation details (N), combine with others (V), add context (E), split (S), or add specific acceptance criteria (T).

### Step 3: Vertical Slicing (/dso:preplanning)

Focus on functional "slices" of value, not horizontal technical layers.

**Good** (vertical slice):
- "User can upload a PDF and see extraction results"

**Bad** (horizontal layer):
- "Create database schema for documents"
- "Build document upload API"
- "Add frontend upload component"

The vertical slice includes all layers necessary to deliver value.

### Step 4: Foundation/Enhancement Splitting (/dso:preplanning)

For each story flagged as a **split candidate** in Phase C, evaluate whether splitting delivers better outcomes than keeping it as a single story.

**The question**: "Does the minimum that delivers the functional goal differ significantly from the ideal experience or architecture?"

- **Foundation**: Delivers the functional goal and proves the concept. This IS the walking skeleton slice for the story — it may use simpler approaches, existing patterns, or existing components.
- **Enhancement**: Invests in the ideal experience — better UX, proper architecture, performance optimization. Depends on Foundation.

**Split if**:
- The Foundation alone delivers user value (it's a complete vertical slice)
- The Enhancement represents a meaningful scope increase (not just polish)
- Combining both would make the story too large for a single agent session

**Don't split if**:
- The "Foundation" wouldn't deliver value without the "Enhancement"
- The scope difference is marginal
- The story is already small enough

**Examples**:

| Story | Foundation | Enhancement |
|-------|-----------|-------------|
| "User can review extracted rules" | Review page with approve/reject using existing table component | Custom review interface with inline editing, bulk actions, and keyboard shortcuts |
| "System stores extraction results" | Persist results in existing job table with JSON column | Dedicated results table with normalization, indexing, and query optimization |
| "User can export reviewed rules as Rego" | Download button that generates Rego file | Export wizard with format options, preview, and validation |

For each split:
- Create both stories as children of the epic
- Foundation gets higher priority than Enhancement
- Add dependency: `.claude/scripts/dso ticket link <enhancement-id> <foundation-id> depends_on`
- Both trace to the same epic criterion

**Note**: `dso:ui-designer` has its own Pragmatic Scope Splitter (Phase 3 Step 10) that may trigger UI-specific splits during design. If preplanning already split a story, the design agent works within the Foundation story's scope. **Enforcement**: the splitRole guard in `ui-designer-dispatch-protocol.md` Section 5 enforces this precedence rule — agent `scope_split_proposals` are skipped entirely when a `splitRole: Foundation` or `splitRole: Enhancement` marker is detected on the story.

---

## Phase G: Story-Level Research (/dso:preplanning)

After Phase F completes story slicing and splitting, perform targeted research for stories where decomposition has revealed knowledge gaps. This phase fires per-story and is distinct from Phase D (Integration Research): Phase D fires for stories with external integration signals (third-party tools, APIs); Phase G fires for any decomposition gap regardless of whether an external integration is involved.

### Trigger Conditions

A story qualifies for story-level research if any of the following apply:

- **Undocumented API behavior**: The story depends on an external API or internal interface whose behavior is undocumented, ambiguous, or not verified in the epic context.
- **Assumed data format**: The story assumes a data format, schema, or protocol not described in the epic context (e.g., the exact shape of a webhook payload or file format encoding).
- **Low agent confidence**: Agent confidence on a key implementation decision is low — the approach is unclear, multiple conflicting patterns exist, or the story references technology the agent is uncertain about.

When a story qualifies, follow the Research Process defined in `prompts/research-process.md`. Record findings in the story spec under a **Research Notes** section, noting the trigger condition, query summary, source URLs, and key insight for each gap. If research resolves the gap, update the story's done definition or considerations. If research surfaces new risks, flag the story as high-risk for Phase H review.

### Graceful Degradation

<!-- EMIT-PRECONDITIONS: gate_name=preplanning_story_research degradation_type=inferred_decision -->
If WebSearch or WebFetch fails or is unavailable, continue without research rather than blocking the workflow. Log: `"Story-level research skipped for <story-id>: WebSearch/WebFetch unavailable."` and proceed to Phase H.

### Skip Condition

If no stories qualify under the trigger conditions above, log: `"No stories with decomposition gaps — skipping story-level research."` and proceed to Phase H.

---

## Phase H: Verification & Traceability (/dso:preplanning)

### Step 1: Create/Modify Stories in Tickets (/dso:preplanning)

For new stories, create the ticket then immediately write the full story body into the ticket file:

```bash
# Assemble the story body from the Story Decomposition artifact and downstream phases:
# - Title, Description, Done Definitions, depends_on, priority, escalation_policy:
#     copied verbatim from the matching draft in story-decomposition-<epic-id>.json
# - Considerations: merge the draft's `considerations` with any new flags raised by
#     Phase C (Risk & Scope Scan), Phase D (Integration Research), and Phase E
#     (Adversarial Review) for this story
# - Foundation/Enhancement: if Phase F split the draft, the `splitRole` field is set
#     on the resulting tickets per Phase F Step 4
# Never assemble the body from session memory — always source from the artifact and
# the recorded phase outputs (bug class: inline drafting summarized SCs and DDs past).

STORY_ID=$(.claude/scripts/dso ticket create story "As a [persona], [goal]" --parent=<epic-id> --priority=<priority> -d "$(cat <<'DESCRIPTION'
## Description

**What**: <what the feature or change is>
**Why**: <how this advances the epic's vision>
**Scope**:
- IN: <items explicitly in scope>
- OUT: <items explicitly out of scope>

## Done Definitions

- When this story is complete, <observable outcome 1>
  ← Satisfies: sc-N  (sc-N: "<quoted epic criterion>")
- When this story is complete, <observable outcome 2>
  ← Satisfies: sc-N  (sc-N: "<quoted epic criterion>")

The `sc-N` form is the stable SC identifier assigned in the Story Decomposition phase
artifact (story-decomposition-<epic-id>.json) — copy it verbatim from the draft's
`done_definitions` strings. The parenthetical preserves human-readable context for the
ticket reader. Machine-parsing downstream (SC contradiction check, completion verifier)
keys off `sc-N`, not the quoted text.

## Closure Checks
- (items routed from verifiable-sc-check.md option (c) — durable end-state intent that is not session-verifiable)

## Considerations

- [<Area>] <concern from Risk & Scope Scan>

## Escalation Policy

**Escalation policy**: <verbatim escalation policy text from Phase A Step 2>
DESCRIPTION
)" | tail -1)
```

Omit the `## Escalation Policy` section if the user selected **Autonomous** in Phase A Step 2. The ticket must never be left as a bare title — always include the structured body at creation time.

For modified stories, use `.claude/scripts/dso ticket comment <existing-id> "<updated content>"` to record changes.

For stories to delete:
```bash
.claude/scripts/dso ticket transition <id> open closed
```

### Step 1b: Write Verify Commands (intent-fidelity-pipeline Phase 2)

After creating each story ticket in Step 1, write the DD-level verify commands from the story-decomposer's `verify_commands` output:

```bash
.claude/scripts/dso ticket set-verify-commands "$STORY_ID" '<verify_commands_json_array>'
```

Where `<verify_commands_json_array>` is the `verify_commands` array from the decomposer's draft for this story. Each entry has `{"dd_id": "dd-N", "dd_text": "<DD text>", "command": "<executable command>"}`.

This writes a structured `VERIFY_COMMANDS` event on the ticket, consumed by `pre-verifier-execute.sh` during sprint Phase F to produce execution traces for the completion verifier.

If the decomposer's output does not include `verify_commands` for a story (backward compatibility with pre-Phase-2 decompositions), skip this step for that story — `pre-verifier-execute.sh` handles missing verify commands gracefully.

### Step 2: Story Structure Requirements (/dso:preplanning)

Each story must contain:

#### Title
Format: `As a [User/Developer/PO], [goal]`
Example: "As a compliance officer, I can see which policies apply to a document"

#### Description
Include:
- **What**: The feature or change
- **Why**: How this advances the epic's vision
- **Scope**: What's explicitly in and out of this story

Do NOT include: specific file paths, technical implementation details, error codes, or testing requirements. Those belong in `/dso:implementation-plan`.

#### Done Definitions
Observable outcomes that bridge the epic's vision to task-level acceptance criteria. Each definition must be:

- **Observable**: Describes what a user sees, does, or what the system does — not internal implementation
- **Measurable**: `/dso:implementation-plan` can decompose it into tasks with specific `Verify:` commands
- **Traceable**: Links upward to an epic criterion

Format:
```
Done Definitions:
- When this story is complete, [observable outcome 1]
  ← Satisfies: sc-N  (sc-N: "[quoted epic criterion]")
- When this story is complete, [observable outcome 2]
  ← Satisfies: sc-N  (sc-N: "[quoted epic criterion]")
```

The `sc-N` identifier is assigned by the Story Decomposition phase and recorded
in the artifact `story-decomposition-<epic-id>.json`. Downstream machine parsing
(SC contradiction check, completion verifier) keys off `sc-N`; the parenthetical
quoted text is for human readers only.

For done definitions that link to a `## Closure Checks` item rather than an epic Success Criterion, use the alternate form:
```
  ← Validates Closure Check: "<quoted closure check text>"
```
`← Satisfies:` points to `## Success Criteria` items in the epic; `← Validates Closure Check:` points to `## Closure Checks` items. Both forms are accepted traceability annotations — use whichever matches the upstream artifact the DD is satisfying.

Example:
```
Done Definitions:
- When this story is complete, a user can view all extracted rules
  for a document, mark individual rules as approved or rejected,
  and see a summary count of pending reviews
  ← Satisfies: sc-3  (sc-3: "Users can review extracted rules before export")
- When this story is complete, reviewed rules persist across sessions
  and are visible when the user returns to the same document
  ← Satisfies: sc-4  (sc-4: "Review state is preserved")
```

Example with Closure Check traceability:
```
Done Definitions:
- When this story is complete, the export summary always lists
  which closure checks were verified during preplanning
  ← Validates Closure Check: "Each epic's closure checks are traceable to a done definition"
```

**Good** done definitions (observable outcomes):
- "A user can upload a document and see its classification within 30 seconds"
- "The system processes documents up to 100 pages without timeout"
- "Reviewed rules appear in the exported Rego output"

**Bad** done definitions (implementation details):
- "The upload endpoint returns a 202 with a job ID"
- "Classification results are stored in the job_results JSON column"
- "The ReviewService calls the ExportService with the approved rule IDs"

#### SC Contradiction Check

After drafting all done definitions, cross-check each DD against the epic SC it claims to satisfy (`← Satisfies:`). A done definition **contradicts** its SC when the DD's observable outcome, if fully achieved, would leave the SC unsatisfied. Common contradiction patterns:

- **Bypass annotation**: DD plans to "annotate" or "exclude" items from the SC's measurement rather than resolving them (e.g., SC says "zero matches" but DD plans to annotate exceptions)
- **Partial coverage**: DD addresses only a subset of the SC's scope without noting the remainder
- **Scope narrowing**: DD redefines the SC's scope to be narrower than what the SC specifies

If a contradiction is found:
1. Revise the DD to align with the SC — the SC is authoritative (it was approved by the user in brainstorm)
2. If the SC itself is wrong or too strict, flag it for the user: `"SC '<criterion>' may be too strict for this decomposition — <reason>. Revise the SC, or confirm the current SC should be met as written?"`
3. Do NOT proceed with stories whose DDs contradict their SCs — this produces plans that are structurally guaranteed to fail the completion verifier.

**Note**: A done definition annotated with `← Validates Closure Check: "<text>"` is a valid traceability link to the `## Closure Checks` section — it is NOT an orphaned annotation and must NOT be flagged as a contradiction. The `← Validates Closure Check:` form is an accepted traceability link form alongside `← Satisfies:`; both are structurally correct and the SC Contradiction Check applies only to DDs using `← Satisfies:`.

#### TDD Done-of-Done Requirement

Code-change stories (stories that produce or modify source code) must include **'unit tests written and passing for all new or modified logic'** as a Done Definition. This is a unit test DoD requirement applied at the story level.

Documentation, research, and other non-code stories are exempt from this requirement — their Done Definitions focus on observable outcomes rather than test coverage.

#### DD Lexicon Check

Before finalizing each story, check each done definition for precision vocabulary and compound requirements:

```bash
for _DD in "${_DONE_DEFINITIONS[@]}"; do
    _LEXICON_RESULT=$(echo "$_DD" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-dd-lexicon.sh")  # shim-exempt: internal orchestration script
    _LEXICON_EXIT=$?
    if [[ $_LEXICON_EXIT -ne 0 ]]; then
        echo "DD LEXICON VIOLATION: $_LEXICON_RESULT"
        echo "Split or revise: '$_DD'"
        # halt — do not finalize this story
        exit 1
    fi
done
```

A **compound** violation (type `compound`) means the DD contains ` AND ` joining two requirements — split into two separate done definitions. A **vague** violation (type `vague`) means the DD uses imprecise language (e.g., `properly`, `correctly`, `should`) — replace with observable, measurable language.

#### Spec-Fidelity Check

Before finalizing each story, verify PIL criteria against written done definitions:

```bash
# Write PIL criteria and story DDs to temp files
_PIL_TMP=$(mktemp /tmp/pil-criteria.XXXXXX)
_DD_TMP=$(mktemp /tmp/story-dds.XXXXXX)
# Populate _PIL_TMP with {"criteria": [...]} JSON from the PIL for this story
# Populate _DD_TMP with one done-definition per line
bash "${CLAUDE_PLUGIN_ROOT}/scripts/spec-fidelity-check.sh" \  # shim-exempt: internal orchestration script
    --pil-json="$_PIL_TMP" \
    --story-dds="$_DD_TMP"
if [[ $? -ne 0 ]]; then
    echo "FIDELITY_FAIL: PIL field dropped or mutated in story done definitions"
    # halt — show diff to user, do NOT auto-correct
fi
rm -f "$_PIL_TMP" "$_DD_TMP"
```

A PIL criterion is considered matched when ≥80% of its words appear in any DD line (near-match). If a criterion has no match, the script emits JSON `{"type":"drop","pil_text":"<criterion>","dd_matches":[]}` on stderr and exits 1. **Do not auto-correct** — surface the mismatch to the user and halt story finalization.

#### Considerations
Notes from the Risk & Scope Scan (Phase C). These provide context for `/dso:implementation-plan` to incorporate into task-level acceptance criteria:

```
Considerations:
- [Performance] Large file processing — consider timeout behavior
- [Testing] New LLM interaction — ensure mock-compatible interface
- [Accessibility] New interactive page — WCAG 2.1 AA compliance required
```

#### Escalation Policy

Include the policy selected in Phase A Step 2. Use the exact text for each label:

| Label | Text to include verbatim |
|-------|--------------------------|
| Autonomous | **Escalation policy**: Proceed with best judgment. Make and document reasonable assumptions. Do not escalate for uncertainty — use your best assessment of the intent and move forward. |
| Escalate when blocked | **Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating. |
| Escalate unless confident | **Escalation policy**: Escalate to the user whenever you do not have high confidence in your understanding of the work, approach, or intent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess. |

Omit this section entirely if the user selected **Autonomous** — the absence of a policy section signals unrestricted autonomy.

#### Dependencies
Add blocking relationships:
```bash
.claude/scripts/dso ticket link <story-id> <blocking-story-id> depends_on
```

### Documentation Update Story

After all implementation stories are drafted, **decide whether a documentation update story is warranted** by running the gates in `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/doc-router.md`. The story is **not** unconditional. Default to **no story** unless at least one router gate fires.

**Skip the doc story (no router gate fires) when**: the epic is purely internal refactor, bug fix, or test work; user-visible behavior, public APIs, conventions, top-level commands, and every-session rules are unchanged. Document the skip rationale in the epic's preplanning summary (e.g., "doc-router: no gate fired — internal refactor only").

**Create the doc story (at least one gate fires) with these properties**:

- **Updates existing docs only** — do not create new documentation files unless a router gate explicitly directs to a new ADR (Gate 4) or the change introduces a contract that requires a new contract doc.
- **Default targets, in order of preference** (set by `doc-router.md` gates, NOT by author intuition):
  - **Gate 1 — skill-scoped change** → `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/SKILL.md` or skill-local prompt.
  - **Gate 2 — extends an existing reference doc** → that doc (`HOOKS-REFERENCE.md`, `AGENTS.md`, `WORKTREE-GUIDE.md`, `CONFIGURATION-REFERENCE.md`, `CI-INTEGRATION.md`, `ticket-cli-reference.md`, `contracts/`, `KNOWN-ISSUES.md`).
  - **Gate 3 — onboarding/user-facing** → `INSTALL.md`, `README.md`, or `docs/user/`.
  - **Gate 4 — decision rationale** → new ADR in `docs/adr/`.
  - **Gate 5 — strictly every-session, not skill-scoped, not enforceable as a hook, ≤ 2 lines** → CLAUDE.md, **but only as a `CLAUDE_MD_SUGGESTED_CHANGE` report**; the sub-agent must NOT write CLAUDE.md directly. The orchestrator surfaces the report to the user for approval before any CLAUDE.md edit lands.
- **CLAUDE.md is not a default target.** Authoring a doc story whose primary target is CLAUDE.md is an anti-pattern; the router prefers SKILL.md / reference docs / ADRs and only escalates to CLAUDE.md when Gate 5 strictly holds. See CLAUDE.md `invariant:claude-md-purpose` (bloat criteria a–d).
- **Depends on**: all implementation stories (runs last).
- **Title format**: "Update project docs to reflect [epic summary]".
- **Style guide**: if `.claude/docs/DOCUMENTATION-GUIDE.md` exists, follow it for formatting and structure.

When creating the documentation update story via `.claude/scripts/dso ticket create`, attach the router and style references so sub-agents find them in the ticket payload:
```bash
.claude/scripts/dso ticket comment <story-id> "Apply ${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/doc-router.md gates before writing. CLAUDE.md edits require a CLAUDE_MD_SUGGESTED_CHANGE report — do not edit CLAUDE.md directly. If .claude/docs/DOCUMENTATION-GUIDE.md exists, follow it for formatting."
```

**Acceptance criterion** for the doc story: the completion report MUST include the `DOC_ROUTER_ATTESTATION` block (see `doc-router.md`), and any `CLAUDE_MD_SUGGESTED_CHANGE` reports MUST be surfaced to the user before the story closes.

### TDD Test Story Requirements (/dso:preplanning)

After all implementation stories are drafted and the documentation update story is planned, evaluate whether the epic requires dedicated TDD test stories. A TDD test story is a story whose sole purpose is to write failing tests (RED) that implementation stories must make pass (GREEN).

#### When to Create TDD Test Stories

Infer the epic type from its context and title:

| Epic Type | TDD Story Required | Story Title Format |
|-----------|-------------------|--------------------|
| **User-facing epic** (LLM-inferred: epic adds or changes user-visible features, pages, flows, or interactions) | Yes — create an **E2E test story** | `Write failing E2E tests for [feature]` |
| **External-API epic** (LLM-inferred: epic integrates with an external service or third-party API) | Yes — create an **integration test story** | `Write failing integration tests for [feature]` |
| **Internal tooling epic** (LLM-inferred: epic modifies internal skills, hooks, scripts, or infrastructure) | No — unit testing is handled within each implementation story's `/dso:implementation-plan`; this is the **internal epic exemption** |  |

For epics that span multiple types (e.g., both user-facing and external-API), create one TDD story per applicable type.

#### Dependency Ordering for TDD Test Stories

TDD test stories have a specific dependency structure that differs from other stories:

- The **TDD test story's `depends_on` list must contain no implementation story IDs** from the same epic — the test story has no blockers and must be created first.
- **All implementation stories in the epic must depend on the TDD test story**: run `.claude/scripts/dso ticket link <impl-story-id> <test-story-id> depends_on` for each implementation story so that implementation cannot begin until tests exist.
- The documentation update story does NOT depend on the TDD test story (it depends on implementation stories as usual).

#### RED Acceptance Criteria

Every TDD test story must include the following acceptance criterion:

```
Tests must be run and confirmed failing (RED) before any implementation story begins.
The failing run result must be recorded in a story note:
  .claude/scripts/dso ticket comment <test-story-id> "RED confirmed: <test output summary>"
```

This RED acceptance criteria ensures the TDD test story's tests are observed to fail before implementation begins, not written alongside or after implementation.

#### Exemptions

- **Documentation and research stories** are exempt from TDD story requirements — they have no associated test stories and do not depend on any TDD test story.
- If an epic is **SIMPLE** (single story, no external dependencies) and the story already contains unit test acceptance criteria, a separate TDD test story may be omitted. Document the rationale.

### Step 3: Present Story Dashboard (/dso:preplanning)

**[CP5 non-interactive]** If `PREPLANNING_INTERACTIVE=false`: suppress dashboard presentation; skip the table and full story descriptions below and proceed to Step 4.

Display the epic ID prominently at the top so it can be referenced in follow-up commands:

```
Story dashboard for Epic [epic-id]: [Title]
```

Display a summary table:

| ID | Title | Priority | Status | Blocks | Split | Satisfies Criterion |
|----|-------|----------|--------|--------|-------|---------------------|
| xxx-126 | As a user... | P1 | pending | xxx-127 | Foundation | Epic criterion 1 |
| xxx-127 | As a user... | P2 | pending | - | Enhancement of xxx-126 | Epic criterion 1 |
| xxx-128 | As a dev... | P1 | pending | - | - | Epic criterion 2 |

Then, below the table, display each story's full description so the user can review scope, done definitions, and considerations before approving:

```
### xxx-126: As a user, I can upload a document and see its classification

**What**: [description]
**Why**: [rationale]
**Scope**: IN: [...] | OUT: [...]

**Done Definitions**:
- When this story is complete, [outcome 1]
  ← Satisfies: sc-N  (sc-N: "[epic criterion]")

**Considerations**:
- [Area] concern

---
[repeat for each story]
```

### Step 4: Validate Dependencies (/dso:preplanning)

After creating all stories and dependencies:
```bash
.claude/scripts/dso validate-issues.sh
```

If score < 5, fix issues before presenting to user.

### Step 5: Final Review Prompt (/dso:preplanning)

**[CP6 non-interactive]** If `PREPLANNING_INTERACTIVE=false`: skip the approval gate (no `AskUserQuestion`), treat the plan as approved, and continue to Step 6, Step 7, and Step 8.

Present the plan to the user with:

```
I've created a story map for Epic [ID]: [Title]

Summary:
- [N] new stories created
- [M] existing stories modified
- [K] stories removed
- Walking Skeleton: [list of IDs in critical path]

Next Steps:
1. Review the story dashboard above
2. Confirm priorities and dependencies make sense
```

Use `AskUserQuestion` to get user approval:
- Question: "The story map above captures the full plan for this epic. Do you approve?"
- Options: ["Approve — finalize and proceed", "Request changes"]

If the user requests changes, iterate on the plan and re-present. Once the user selects "Approve — finalize and proceed", immediately continue to Step 6, Step 7, and Step 8 without pausing for additional input — approval is the signal to proceed, not a stopping point.

### Step 6: Write Planning Context to Epic Ticket (/dso:preplanning)

Write the accumulated context as a structured comment on the epic ticket so that `/dso:implementation-plan` can load richer context when planning individual stories from this epic, regardless of which session or environment runs next.

**Schema version**: The `schema_version` integer field (current value: `2`) is used by consumers for forward/backward compatibility — bump it whenever the payload structure changes in a non-additive way. Consumers reading an unfamiliar `schema_version` should fall back to defensive parsing rather than failing.

**Validate the PIL payload** (if loading a prior `PREPLANNING_CONTEXT:` comment): If a prior `PREPLANNING_CONTEXT:` comment exists on the epic, validate it before merging its data:
```bash
echo "$_PREPLANNING_CONTEXT_JSON" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/validate-pil-handoff.sh"  # shim-exempt: internal orchestration script
if [[ $? -ne 0 ]]; then
    # Fail-open: log validation error but continue with planning
    echo "PIL_VALIDATION_ERROR: PREPLANNING_CONTEXT failed schema validation — treating as absent"
    # Clear the context and proceed with full Input Analysis
fi
```
<!-- EMIT-PRECONDITIONS: gate_name=preplanning_pil_handoff_validation degradation_type=inferred_decision -->
Validation failure is non-blocking — treat the invalid payload as absent and continue with full preplanning. This prevents a corrupt or stale PIL from silently poisoning downstream story decomposition.

**Merging prior research findings (RESEARCH_FINDINGS:)**: Before writing the new `PREPLANNING_CONTEXT:` comment, scan the epic's ticket comments for the most recent `RESEARCH_FINDINGS:` comment (a JSON array of `{capability, status, source, skill_name, timestamp}` entries written by upstream skills like brainstorm or prior preplanning runs). Parse it and merge into the `researchFindings` array of the new context payload.
<!-- EMIT-PRECONDITIONS: gate_name=preplanning_research_findings_merge degradation_type=inferred_decision -->
Treat a missing or corrupt `RESEARCH_FINDINGS:` comment as an empty array (fail-open — never block the write). This compounds research across pipeline stages so downstream skills (implementation-plan, sprint) can deduplicate WebSearch calls.

**Command** (use Python subprocess to avoid shell ARG_MAX limits for large payloads). This write is an optional cache — if the ticket CLI call fails, log a warning and continue; do not abort the phase:
```python
import json, subprocess
payload = json.dumps(<context-dict>, separators=(",",":"))
body = "PREPLANNING_CONTEXT: " + payload
result = subprocess.run(
    [".claude/scripts/dso", "ticket", "comment", "<epic-id>", body],
    check=False
)
if result.returncode != 0:
    print("WARNING: Failed to write PREPLANNING_CONTEXT comment to epic ticket — continuing without cache write")
```

> **Known limitation**: For extremely large epic contexts (unlikely in practice), the actual ARG_MAX constraint boundary is `ticket-comment.sh`, which passes the comment body as a shell argument to its internal `python3 -c` invocation. The Python subprocess call in this skill avoids ARG_MAX at the *outer* shell level, but a body >~500KB could still hit the kernel limit inside `ticket-comment.sh`. A proper fix would write the payload to a temp file and pass the path instead of the body directly. A proper fix would pass the body via a temp file instead of a shell argument. Typical epic contexts are 10–50KB and well within limits.

Serialize the JSON payload to a single minified line (no whitespace between keys/values). If `/dso:preplanning` runs again on the same epic, write a new comment — `/dso:implementation-plan` uses the last `PREPLANNING_CONTEXT:` comment in the array.

**Schema** (version 1, schema_version 2):
```json
{
  "version": 1,
  "schema_version": 2,
  "epicId": "<epic-id>",
  "generatedAt": "<ISO-8601 timestamp>",
  "generatedBy": "preplanning",
  "epic": {
    "title": "...",
    "description": "...",
    "successCriteria": ["..."]
  },
  "researchFindings": [
    {
      "capability": "<short capability description>",
      "status": "verified|partially_verified|unverified|contradicted",
      "source": "<URL or citation>",
      "skill_name": "preplanning|implementation-plan|brainstorm|...",
      "timestamp": "<ISO-8601 timestamp>"
    }
  ],
  "stories": [
    {
      "id": "<story-id>",
      "title": "...",
      "description": "...",
      "priority": 2,
      "classification": "new|reuse|modify",
      "walkingSkeleton": true,
      "hasWireframe": false,
      "doneDefinitions": ["When this story is complete, ..."],
      "considerations": ["[Performance] Large file processing — consider timeout behavior"],
      "scopeSplitCandidate": false,
      "splitRole": "foundation|enhancement|null",
      "splitPairId": "<paired-story-id or null>",
      "blockedBy": ["<blocking-id>"],
      "satisfiesCriterion": "quoted epic criterion"
    }
  ],
  "storyDashboard": {
    "totalStories": 5,
    "uiStories": 2,
    "criticalPath": ["<id-a>", "<id-b>", "<id-c>"]
  }
}
```

**Content to include**:
- **Epic data**: title, description, success criteria from the loaded epic
- **All stories**: IDs, titles, descriptions, priorities, classifications (from Phase A reconciliation), walking skeleton flags (from Phase F), done definitions and considerations (from Phase C Risk & Scope Scan), split role and pair info (from Phase F Step 4), dependency links, and traceability lines (from Phase H Step 2)
- **Story dashboard**: total story count, UI story count, critical path order
- **`generatedAt`**: Current ISO-8601 timestamp for staleness detection

> **TTL note for consumers**: The `generatedAt` timestamp enables staleness detection. Consumers should treat `PREPLANNING_CONTEXT` comments older than 7 days as potentially stale and re-invoke `/dso:preplanning` to refresh.

Log: `"Planning context written to epic ticket <epic-id> as PREPLANNING_CONTEXT comment"`

### Step 7: Design Wireframes for UI Stories (/dso:preplanning)

After the user approves the story map, dispatch `dso:ui-designer` for **any
story that involves UI changes**. The agent determines whether new components,
layouts, or wireframes are actually needed — your job is only to identify
candidates and dispatch them.

A story is a candidate if it:
- Mentions user-facing screens, pages, views, or components
- Includes frontend routes, forms, dashboards, or visual elements
- Has success criteria describing what a user **sees** or **interacts with**
- Modifies existing UI behavior, templates, or JavaScript interactions

Stories that are purely backend, infrastructure, testing-only, or documentation do NOT qualify.

**Skip if**: No stories in the plan involve UI changes. Document this: "No UI stories identified — skipping wireframe phase."

#### Dispatch Protocol

**Before the loop**: Read the inline dispatch protocol once using the Read tool:
`skills/preplanning/prompts/ui-designer-dispatch-protocol.md`

**For each qualifying story**, follow the six protocol steps in order:
1. Input payload construction and session file initialization
2. Agent dispatch via the Agent tool — `subagent_type: "dso:ui-designer"` (model defaults: sonnet); fall back to `subagent_type: "general-purpose"` with `model: "sonnet"` and `agents/ui-designer.md` content read inline only if the named type is unregistered
3. CACHE_MISSING retry loop (2 retry attempts; up to 3 total CACHE_MISSING
   returns before the retry cap is exceeded)
4. Review loop (orchestrator-managed: invoke `/dso:review-protocol` on design
   artifacts; max 3 cycles; REVIEW_PASS → tag `design:approved` and proceed;
   REVIEW_FAIL → re-dispatch ui-designer with feedback; at max cycles:
   interactive → ask user; non-interactive → emit INTERACTIVITY_DEFERRED,
   tag `design:pending_review`, and proceed)
4b. Design MD additions surfacing (check `design_md_additions` in payload; if
    non-null: interactive → `AskUserQuestion` approve/decline → approve invokes
    `write-design-md-additions.sh`, decline tags `design:tokens_pending`;
    non-interactive → emit INTERACTIVITY_DEFERRED, tag `design:tokens_pending`)
5. Scope-split handling (interactive or INTERACTIVITY_DEFERRED)
6. Session file updates (`processedStories` and `siblingDesigns`)

**NESTING PROHIBITION**: Dispatch `dso:ui-designer` via the **Agent tool only**.
Do NOT use the Skill tool — that would create illegal Skill-tool nesting
(preplanning → Skill → ui-designer) which causes
`[Tool result missing due to internal error]` failures.

Parse the agent return value for the `UI_DESIGNER_PAYLOAD:` prefix and extract
the JSON object that follows. Route all subsequent decisions (tagging, scope
splits, session file updates) based on that object's fields.

**Order**: Process stories in dependency order (stories with no blockers first,
then stories that depend on them). This ensures base wireframes exist before
dependent designs reference them.

### Step 8: Sync Tickets (/dso:preplanning)

After wireframe phase completes (or is skipped), confirm all ticket state is
up to date and report completion.

---

## Lightweight Mode (branch — `--lightweight` flag only)

**Trigger**: `/dso:preplanning` invoked with `--lightweight`. Lightweight mode produces an enriched epic description (done definitions + scope + considerations) without decomposing the epic into stories.

**Load**: `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/prompts/lightweight-mode.md` and follow it. It skips Phase A Steps 3–5, skips Phase E entirely, runs an abbreviated Phase C, escalates with `result: "ESCALATED"` on any qualitative COMPLEX override, otherwise writes the `PREPLANNING_CONTEXT_LIGHTWEIGHT:` ticket comment (separate key to preserve any full `PREPLANNING_CONTEXT:` comment) and returns `result: "ENRICHED"`.

---

## Guardrails

### Epic Deps Must Not Contain Children (Critical)

**Never run `.claude/scripts/dso ticket link <epic-id> <story-id> depends_on`** — this adds the story as a dependency of the epic, causing the epic to self-block in `ticket list-epics` (bug w21-3w8y).

- `.claude/scripts/dso ticket link <story-id> <blocking-story-id> depends_on` — correct: story depends on another story
- `.claude/scripts/dso ticket link <epic-id> <child-story-id> depends_on` — **WRONG**: child added as epic blocker

Epic children are linked via `--parent=<epic-id>` at creation time. That parent field is how the epic knows what work to do. Adding a child as a dep means the epic will show as BLOCKED until the child is closed — which is backwards. Only add external dependencies (tickets from other epics/projects) to an epic's deps.

### No "How"
Focus on requirements, constraints, and outcomes. Avoid dictating specific implementation code or library choices unless mandated by the Architecture Board.

**Good**: "System must validate email format before storing"
**Bad**: "Use the `email-validator` library with pattern `^[\w.-]+@[\w.-]+\.\w+$`"

### Ticket Integrity
Check for existing items before creating new ones to prevent backlog pollution. Always run Phase A reconciliation before creating stories.

### Story-Level Fidelity
Stories should be detailed enough that `/dso:implementation-plan` can decompose them without further human clarification. Include:
- Clear scope boundaries (what's in, what's explicitly out)
- Concrete behavioral examples (what the user sees or experiences)
- Measurable done definitions (observable outcomes, not technical criteria)
- Considerations from the Risk & Scope Scan (context, not requirements)

Do NOT include: file paths, code snippets, database schemas, API response formats, or testing strategies. Those are `/dso:implementation-plan` concerns.

#### Verify Scoping Assumptions

After writing the Scope section for each story, verify every "OUT" assertion that claims something already exists or is handled elsewhere:

1. For each OUT statement that makes a factual claim (e.g., "existing plugin skills already serve this purpose", "the API already supports this"), write a `Verify:` command that confirms the assertion
2. Run the command. If it fails, the assumption is wrong — either move the item to IN scope or add a dependency on the story that will create it
3. Document verified assumptions inline: `OUT: [item] — Verified: [command] returned exit 0`

**Why this matters**: False preconditions encoded as scoping decisions are invisible to downstream validation. A story that says "OUT: Creating X — X already exists" will pass all structural checks even when X does not exist, because no task was created to build it and no AC was written to verify it.

---

## Quick Reference

| Phase | Key Actions | Tools |
|-------|-------------|-------|
| A: Reconciliation | Load epic; classify complexity (Step 1.5, skipped if `--lightweight`) — SIMPLE → `/dso:implementation-plan`, MODERATE → lightweight, COMPLEX → full; audit children, clarify scope | `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket deps`, `dso:complexity-evaluator` (haiku, tier_schema=SIMPLE) |
| B: External Dependencies Reading (flag-gated) | Read epic's External Dependencies block, generate `manual:awaiting_user` stories for `user_manual` entries. Schema: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md` | `.claude/scripts/dso ticket tag` |
| Story Decomposition | Dispatch `dso:story-decomposer` (opus) to draft new vertical-slice stories with SC-tied DDs; persist artifact; never draft inline | `Task` (opus story-decomposer), `${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh` (`get_artifacts_dir`), `.claude/scripts/dso ticket comment` |
| C: Risk & Scope Scan | Flag cross-cutting concerns, identify split candidates across the union of existing + external-dep + newly-drafted stories | Lightweight analysis (no sub-agents) |
| D: Integration Research (pre-slicing) | Verify external integrations via WebSearch | `WebSearch` |
| E: Adversarial Review | Red team attack on story map, blue team filter findings (skip if < 3 stories) | `Task` (opus red team, sonnet blue team) |
| Refusal Gate | Halt if externally-shaped SCs lack External Dependencies block coverage | (gate, no tools) |
| F: Walking Skeleton | Prioritize critical path, apply INVEST, Foundation/Enhancement splits | Priority analysis, `.claude/scripts/dso ticket link` |
| G: Story-Level Research (post-slicing) | Research per-story decomposition gaps | `WebSearch`, `WebFetch` |
| H: Verification | Create stories, link criteria, validate, wireframe UI stories | `.claude/scripts/dso ticket create`, `.claude/scripts/dso ticket link`, `.claude/scripts/dso ticket comment`, `validate-issues.sh`, `dso:ui-designer` (via Agent tool), `.claude/scripts/dso ticket tag`/`.claude/scripts/dso ticket untag` |

## Example: Reconciliation + Story Creation

See `docs/example-reconciliation.md` for a worked example covering reconciliation, Risk & Scope Scan, and Foundation/Enhancement story creation.

---

### Preconditions Exit Emit (/dso:preplanning)

[Instructions: Before the skill exits, record preplanning PRECONDITIONS event:
Run: `.claude/scripts/dso preconditions-record.sh --ticket-id <epic_id> --gate-name preplanning_complete --session-id <session_id> --tier minimal`
Self-verify: run preconditions-validator.sh --event-file=<just-written-file>; if fails emit WARN but do not block.
This validator reads only minimal-tier fields. Future standard/deep additions are ignored (depth-agnostic forward-compat contract).]

