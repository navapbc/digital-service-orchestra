---
name: preplanning
description: Use when decomposing a ticket epic into prioritized user stories with measurable done definitions, or when auditing and reconciling existing epic children before implementation
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:preplanning cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

## SKILL_ENTER Breadcrumb

At the very start of execution (immediately after passing the SUB-AGENT-GUARD check), emit the SKILL_ENTER breadcrumb:

```bash
_DSO_TRACE_SESSION_ID="${DSO_TRACE_SESSION_ID:-$(date +%s%N 2>/dev/null || date +%s)}"
_DSO_TRACE_SKILL_FILE="${CLAUDE_PLUGIN_ROOT}/skills/preplanning/SKILL.md"
_DSO_TRACE_FILE_SIZE=$(wc -c < "${_DSO_TRACE_SKILL_FILE}" 2>/dev/null || echo "null")
_DSO_TRACE_DEPTH="${DSO_TRACE_NESTING_DEPTH:-1}"
_DSO_TRACE_START_MS=$(date +%s%3N 2>/dev/null || echo "null")
_DSO_TRACE_SESSION_ORDINAL="${DSO_TRACE_SESSION_ORDINAL:-1}"
_DSO_TRACE_CUMULATIVE_BYTES="${DSO_TRACE_CUMULATIVE_BYTES:-null}"
echo "{\"type\":\"SKILL_ENTER\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)\",\"skill_name\":\"preplanning\",\"nesting_depth\":${_DSO_TRACE_DEPTH},\"skill_file_size\":${_DSO_TRACE_FILE_SIZE},\"tool_call_count\":null,\"elapsed_ms\":null,\"session_ordinal\":${_DSO_TRACE_SESSION_ORDINAL},\"cumulative_bytes\":${_DSO_TRACE_CUMULATIVE_BYTES},\"termination_directive\":null,\"user_interaction_count\":0}" >> "/tmp/dso-skill-trace-${_DSO_TRACE_SESSION_ID}.log" || true
```

## Startup Configuration

Immediately after the SKILL_ENTER breadcrumb, read the interactive mode flag:

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

This skill implements a five-phase process to transform epics into implementable stories:

1. **Context Reconciliation & Discovery** - Audit existing work and clarify scope
2. **Risk & Scope Scan** - Flag cross-cutting concerns and split candidates
2.5. **Adversarial Review** - Red/blue team review for cross-story blind spots (3+ stories only)
3. **Walking Skeleton & Vertical Slicing** - Prioritize the minimum viable path, split where needed
4. **Verification & Traceability** - Present the plan and link to epic criteria

**Lightweight mode** (`--lightweight`): Runs an abbreviated subset — Phase 1 Step 1, Phase 2 (abbreviated), and writes done definitions directly to the epic. Skips Phases 2.5, 3-4. Returns `ENRICHED` or `ESCALATED`.

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

This is a presence-based check — only block when the tag IS present. Existing epics without the tags field are NOT blocked. If ticket show fails, treat the tag as absent and proceed (fail-open).

---

### Preconditions Entry Gate (/dso:preplanning)

[Instructions for the LLM: Before Phase 1 Step 1, validate that a brainstorm PRECONDITIONS event exists.
Run: `.claude/scripts/dso preconditions-validator.sh <epic_id> brainstorm_complete [--event-file=<path if known>]`
(or use preconditions-record.sh invocation from brainstorm; fail-open if script not found)
If exit 0: continue. If exit 1: BLOCK with PRECONDITIONS_GATE_BLOCKED diagnostic.
If exit 2 (not found): BLOCK with "Run /dso:brainstorm first" message.
Fail-open: if preconditions-validator.sh itself is not found (command not found), emit WARN and continue.
This gate is depth-agnostic — unknown fields in the event are ignored, not rejected.]

---

## Phase 1: Context Reconciliation & Discovery (/dso:preplanning)

### Step 1: Select and Load Epic (/dso:preplanning)

If `<epic-id>` was not provided:

**Non-interactive gate (CP1)**: If `PREPLANNING_INTERACTIVE=false` and no `<epic-id>` argument was provided:
- Log: `INTERACTIVITY_DEFERRED: preplanning.interactive=false — no epic-id provided. Invoke with /dso:preplanning <epic-id> to run non-interactively.`
- Exit with error (do not proceed).

1. Run `.claude/scripts/dso ticket list` then filter results to epics only (filter JSON output where `ticket_type == 'epic'`)
2. If no open epics exist, report and exit
3. Present epics to the user (if more than 5, show first 5 with option to see more)
4. Get user selection

Load the epic:
```bash
.claude/scripts/dso ticket show <epic-id>
```

### Step 1b: Select Escalation Policy (/dso:preplanning)

**Non-interactive default (CP2)**: If `PREPLANNING_INTERACTIVE=false`:
- Use default escalation policy: **"Escalate when blocked"** (skip `AskUserQuestion`).
- Set `{escalation_policy_label}` = `"Escalate when blocked"` and `{escalation_policy_text}` = the full text for that label (see table in Phase 4 Step 2).
- Continue to the next step without presenting any question.

Use `AskUserQuestion` to ask the user which escalation policy should apply to all stories in this epic. Skip this step in `--lightweight` mode.

- **Question**: "Which escalation policy should agents apply when working on stories in this epic?"
- **Header**: "Escalation"
- **Options**:
  1. **Autonomous** — Agents proceed with best judgment at all times. Reasonable assumptions are made and documented. No escalation for uncertainty.
  2. **Escalate when blocked** — Agents proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. All assumptions made without escalating are documented.
  3. **Escalate unless confident** — Agents escalate whenever high confidence is absent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

Store the selected policy label and its full text as `{escalation_policy_label}` and `{escalation_policy_text}` for use in Phase 4 Step 2.

### Lightweight Mode Gate (/dso:preplanning)

If `--lightweight` was passed: run Phase 1 Step 1 only, skip Step 1b, run abbreviated Phase 2, skip Phases 2.5 and 3-4, write done definitions to epic, return ENRICHED or ESCALATED per the Lightweight Mode Appendix below.

If `--lightweight` was NOT passed, continue to Phase 1 Step 2 as normal.

Source the planning flag helper now to determine whether External Dependencies processing is enabled:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh"
```

If `is_external_dep_block_enabled` returns exit 1 (flag absent or `false`), set `EXTERNAL_DEP_BLOCK_ENABLED=false` — Phase 1.5 will be skipped. When the function returns exit 0, set `EXTERNAL_DEP_BLOCK_ENABLED=true`.

### Step 2: Audit Existing Children (/dso:preplanning)

Gather all existing child items:
```bash
.claude/scripts/dso ticket deps <epic-id>
```

For each child, run `.claude/scripts/dso ticket show <child-id>` to read full details.

### Step 3: Reconcile Existing Work (/dso:preplanning)

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

**Non-interactive exit (CP3)**: If `PREPLANNING_INTERACTIVE=false` and scope clarification is required (boundaries are unclear or existing tasks conflict):
- Log: `INTERACTIVITY_DEFERRED: preplanning.interactive=false — scope clarification required. Re-run /dso:preplanning <epic-id> interactively to resolve.`
- Exit with error (do not proceed).

### Step 4: Document Reconciliation Plan (/dso:preplanning)

Before creating new stories, present a reconciliation summary:

| Child ID | Title | Status | Recommendation | Rationale |
|----------|-------|--------|----------------|-----------|
| xxx-123 | ... | pending | Reuse | Aligns with Epic criterion 1 |
| xxx-124 | ... | in_progress | Modify | Needs updated success criteria |
| xxx-125 | ... | pending | Delete | Redundant with new story approach |

**Non-interactive auto-apply (CP4)**: If `PREPLANNING_INTERACTIVE=false`:
- Auto-apply reconciliation changes (skip `AskUserQuestion` confirmation).
- **In-progress guard**: Do NOT auto-apply Delete recommendations for any child story with status `in_progress`. Skip those deletions and log a warning for each: `"Skipping Delete for in_progress story <id> — manual review required."`
- Continue to story creation without user confirmation.

Use `AskUserQuestion` to get user approval before proceeding:
- Question: "The reconciliation plan above summarizes how existing children will be handled. Do you approve this plan?"
- Options: ["Approve — proceed with story creation", "Request changes"]

If the user requests changes, iterate on the reconciliation plan and re-present.

---

## Phase 1.5: External Dependencies Block Reading (/dso:preplanning)

**Skip this phase when `EXTERNAL_DEP_BLOCK_ENABLED=false`.**

### Purpose

After auditing existing children (Step 2), read the parent epic's `## External Dependencies` block (conforming to `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`) and generate the corresponding child stories.

### Reading the Block

Parse the epic's description field for a YAML block under the `## External Dependencies` heading. If no block exists, skip this phase entirely and proceed to Phase 2.

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
- Create a standard automation story as a child of the epic (same Phase 4 story creation flow).
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

## Phase 2: Risk & Scope Scan (/dso:preplanning)

Scan all drafted stories (new and modified) as a batch to flag cross-cutting concerns that individual tasks would be too granular to catch. This is a lightweight analysis — no sub-agent dispatch, no scored review, no revision cycles.

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

Mark these stories as **split candidates**. Phase 3 evaluates whether a Foundation/Enhancement split actually makes sense (see "Foundation/Enhancement Splitting" below).

---

## Phase 2.25: Integration Research (/dso:preplanning)

After story decomposition and risk scanning, research integration capabilities for stories that involve external tools or services. This step surfaces verified constraints while the user is engaged and can redirect.

### Qualification

A story qualifies for integration research if it references any of:
- Third-party CLI tools
- External APIs/services
- CI/CD workflow changes
- Infrastructure provisioning
- Data format migrations
- Authentication/credential flows

### Research Process (shared)

**Pre-flight: deduplicate against `researchFindings`**. Before issuing any WebSearch call for a qualifying story's capability, check the merged `researchFindings` array (loaded from the epic's last `RESEARCH_FINDINGS:` ticket comment per Step 5a) for a matching `capability` entry:

- `verified` → skip WebSearch entirely for this capability and reuse the prior `source` citation directly. (Skipping verified entries avoids redundant network calls and accelerates preplanning when upstream skills have already established the constraint.)
- `partially_verified` → run a light WebSearch (1 spot-check query) to confirm the prior finding still holds.
- `unverified` or `contradicted` → run full WebSearch verification as described below.
- Empty array (no prior findings) → run full WebSearch verification for every qualifying capability.

After research, append new entries (or upgrade existing entries) to `researchFindings` with the latest `status`, `source`, `skill_name: "preplanning"`, and current `timestamp` so downstream consumers benefit from the same dedup.

For each qualifying story:

1. Use WebSearch to find known-working code that uses the specific integration or topic. Search GitHub for repositories that import or call the tool/API.
2. Verify specific capabilities claimed or implied by the story scope. Check official documentation against what the story requires.
3. Add findings to the story's Considerations as **Verified Constraints**:
   ```
   - [Integration] Verified: <tool> supports <capability> (source: <URL>)
   - [Integration] NOT verified: <tool> does not appear to support <capability>
   ```
4. If no sandbox or test environment is available for integration testing, flag this to the user during preplanning: "No sandbox available for <tool> — integration testing will require a live environment."
5. If research finds no verified code or capabilities for a story's integration, emit `REPLAN_ESCALATE: brainstorm` with explanation of the unresolved gap. Sprint's replan machinery routes this signal. Track the current iteration in `feasibility_cycle_count` (state variable exposed for planning-intelligence log consumption).

### Skip Condition

If no stories in the plan qualify for integration research, log: "No stories with external integration signals — skipping integration research." and proceed to Phase 2.5.

---

## Phase 2.5: Adversarial Review (/dso:preplanning)

### Threshold Gate

**Skip this phase if fewer than 3 stories exist** after Phase 2 completes. Adversarial review adds value only when there are enough stories for cross-story interactions to matter. If skipped, log: `"Adversarial review skipped: fewer than 3 stories (<N> stories)."` and proceed directly to Phase 3.

### Step 1: Red Team Dispatch (/dso:preplanning)

Read `agents/red-team-reviewer.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "opus"`. (`dso:red-team-reviewer` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types.) The agent definition contains the full review prompt including the 6-category taxonomy and Consumer Enumeration directive. Pass the following as task arguments:

- `{epic-title}`: Epic title from Phase 1
- `{epic-description}`: Epic description from Phase 1
- `{story-map}`: All stories with their done definitions, considerations, and dependencies (formatted from Phase 2 output)
- `{risk-register}`: Risk Register table from Phase 2
- `{dependency-graph}`: Dependency graph from `.claude/scripts/dso ticket deps <epic-id>`

The red team sub-agent returns a JSON `findings` array. Parse the response and validate it contains well-formed JSON with the expected schema (array of objects with `type`, `target_story_id`, `title`, `description`, `rationale`, `taxonomy_category` fields).

**Fallback — two-path protocol**:
- **Agent unavailable** (dispatch fails with "Unknown agent" or similar): Read `agents/red-team-reviewer.md` inline and re-dispatch as a general-purpose agent using that content as the prompt. Do NOT perform the review inline — the agent must do it.
- **Execution failure** (timeout, malformed output, or fails to produce valid JSON): Log a warning `"Red team review failed: <reason>. Skipping adversarial review, proceeding to Phase 3."` and skip directly to Phase 3.

### Step 2: Blue Team Dispatch (/dso:preplanning)

If the red team returns a non-empty findings array, read `agents/blue-team-filter.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "sonnet"`. (`dso:blue-team-filter` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types.) Pass the following as task arguments:

- `{epic-title}`: Same as red team
- `{epic-description}`: Same as red team
- `{story-map}`: Same as red team
- `{red-team-findings}`: The raw JSON findings array from the red team sub-agent

The blue team sub-agent returns a filtered JSON object with `findings` (accepted) and `rejected` arrays.

**If red team returned zero findings**: Skip the blue team dispatch entirely. Log: `"Red team found no cross-story gaps. Skipping blue team filter."` and proceed to Phase 3.

**Partial failure — two-path protocol**:
- **Agent unavailable** (dispatch fails with "Unknown agent" or similar): Read `agents/blue-team-filter.md` inline and re-dispatch as a general-purpose agent using that content as the prompt. Do NOT perform the filtering inline — the agent must do it; inline filtering by the orchestrator defeats the purpose of the impartial blue team.
- **Execution failure** (timeout, malformed output, or error): **Discard all unfiltered findings** and proceed to Phase 3. Do NOT apply unfiltered red team findings — the blue team filter exists to prevent false positives from polluting the story map. Log: `"Blue team filter failed: <reason>. Discarding unfiltered red team findings, proceeding to Phase 3."`

### Step 3: Apply Surviving Findings (/dso:preplanning)

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

### Step 3.5: Persist Adversarial Review Exchange (/dso:preplanning)

After processing blue team findings, persist the full exchange for post-mortem analysis:

1. Parse the blue team agent's output for the `artifact_path` field. If present, it points to the persisted JSON file at `$ARTIFACTS_DIR/adversarial-review-<epic-id>.json`
2. If `artifact_path` is present, add a one-line ticket comment referencing the artifact:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Adversarial review: <N> findings, <M> accepted. Full exchange: <artifact_path>"
   ```
3. **If `artifact_path` is absent** (agent failed to persist, or returned malformed output): log a warning `"Adversarial review artifact not persisted — blue team agent did not return artifact_path"` and continue. Artifact persistence failure is non-blocking.
4. This artifact is available for future post-mortem analysis but is not surfaced in normal `ticket show` output

### Step 4: Continue to Phase 3

Proceed to Phase 3 (Walking Skeleton & Vertical Slicing) with the updated story map. New stories from adversarial review are included in the walking skeleton analysis.

---

## Refusal Gate: External Dependencies Block Check (/dso:preplanning)

**Skip this gate when `EXTERNAL_DEP_BLOCK_ENABLED=false`.**

Before proceeding to Phase 3 story decomposition, check whether the parent epic's External Dependencies block adequately covers any externally-shaped Success Criteria.

### When to fire

This gate fires when ALL of the following are true:
- `planning.external_dependency_block_enabled` is on (set during Phase 1.5 flag check)
- The epic has Success Criteria that are externally-shaped (their outcomes are observable only in deployed or external contexts — e.g., "users can log in with OAuth", "emails are delivered", "the API responds to external callers")

### Gate check

1. Identify externally-shaped SCs from the epic's Success Criteria list (SCs whose pass/fail depends on an external system, credential, or deployed environment).
2. For each externally-shaped SC, check whether the parent epic's `## External Dependencies` block contains an entry covering that dependency.
3. If ANY externally-shaped SC has no matching block entry (block is missing or the relevant entry is absent or incomplete per the schema in `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`):
   - **HALT decomposition.** Do not proceed to Phase 3.
   - Emit the following diagnostic, naming the specific SC(s) without block coverage:
     > "Preplanning cannot decompose this epic: the following success criteria are externally-shaped but have no corresponding entry in the External Dependencies block: [list of SC names]. Run `/dso:brainstorm <epic-id>` to capture the dependency information, then retry `/dso:preplanning`."
4. If all externally-shaped SCs have valid block entries (or there are no externally-shaped SCs): proceed to Phase 3 normally.

### Behavioral testing note

SKILL.md is a non-executable LLM instruction file. The structural tests verify only that this section heading exists. Behavioral correctness of the refusal logic is probabilistic per Rule 5 (behavioral-testing-standard.md).

---

## Phase 3: Walking Skeleton & Vertical Slicing (/dso:preplanning)

### Step 1: Identify the Walking Skeleton (/dso:preplanning)

The Walking Skeleton is the absolute minimum end-to-end path required to prove the technical concept.

Ask: "What is the simplest possible flow that demonstrates this feature works?"

**Prioritize these stories first** - they unblock all downstream work.

### Step 2: Apply INVEST Framework (/dso:preplanning)

Ensure each story follows **INVEST** principles:

| Principle | Question | Fix if No |
|-----------|----------|----------|
| **I**ndependent | Can this be built without waiting on other stories? | Add dependencies or split |
| **N**egotiable | Is the "how" flexible, not dictated? | Remove implementation details |
| **V**aluable | Does this deliver user/business value? | Combine with other stories |
| **E**stimable | Can an agent estimate effort? | Add more context |
| **S**mall | Can this be completed in one sub-agent session? | Split into smaller stories |
| **T**estable | Are success criteria measurable? | Add specific acceptance criteria |

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

For each story flagged as a **split candidate** in Phase 2, evaluate whether splitting delivers better outcomes than keeping it as a single story.

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

## Phase 3.5: Story-Level Research (/dso:preplanning)

After Phase 3 completes story slicing and splitting, perform targeted research for stories where decomposition has revealed knowledge gaps. This phase fires per-story and is distinct from Phase 2.25 (Integration Research): Phase 2.25 fires for stories with external integration signals (third-party tools, APIs); Phase 3.5 fires for any decomposition gap regardless of whether an external integration is involved.

### Trigger Conditions

A story qualifies for story-level research if any of the following apply:

- **Undocumented API behavior**: The story depends on an external API or internal interface whose behavior is undocumented, ambiguous, or not verified in the epic context.
- **Assumed data format**: The story assumes a data format, schema, or protocol not described in the epic context (e.g., the exact shape of a webhook payload or file format encoding).
- **Low agent confidence**: Agent confidence on a key implementation decision is low — the approach is unclear, multiple conflicting patterns exist, or the story references technology the agent is uncertain about.

When a story qualifies, follow the Research Process defined in Phase 2.25. Record findings in the story spec under a **Research Notes** section, noting the trigger condition, query summary, source URLs, and key insight for each gap. If research resolves the gap, update the story's done definition or considerations. If research surfaces new risks, flag the story as high-risk for Phase 4 review.

### Graceful Degradation

If WebSearch or WebFetch fails or is unavailable, continue without research rather than blocking the workflow. Log: `"Story-level research skipped for <story-id>: WebSearch/WebFetch unavailable."` and proceed to Phase 4.

### Skip Condition

If no stories qualify under the trigger conditions above, log: `"No stories with decomposition gaps — skipping story-level research."` and proceed to Phase 4.

---

## Phase 4: Verification & Traceability (/dso:preplanning)

### Step 1: Create/Modify Stories in Tickets (/dso:preplanning)

For new stories, create the ticket then immediately write the full story body into the ticket file:

```bash
# Assemble the story body from earlier phases and create the ticket in one command:
# - Description: What/Why/Scope from Phase 2 analysis
# - Done Definitions: assembled during Phase 3
# - Considerations: flags from Phase 2 Risk & Scope Scan
# - Escalation Policy: selected in Phase 1 Step 1b (omit if Autonomous)

STORY_ID=$(.claude/scripts/dso ticket create story "As a [persona], [goal]" --parent=<epic-id> --priority=<priority> -d "$(cat <<'DESCRIPTION'
## Description

**What**: <what the feature or change is>
**Why**: <how this advances the epic's vision>
**Scope**:
- IN: <items explicitly in scope>
- OUT: <items explicitly out of scope>

## Done Definitions

- When this story is complete, <observable outcome 1>
  ← Satisfies: "<quoted epic criterion>"
- When this story is complete, <observable outcome 2>
  ← Satisfies: "<quoted epic criterion>"

## Considerations

- [<Area>] <concern from Risk & Scope Scan>

## Escalation Policy

**Escalation policy**: <verbatim escalation policy text from Phase 1 Step 1b>
DESCRIPTION
)")
```

Omit the `## Escalation Policy` section if the user selected **Autonomous** in Phase 1 Step 1b. The ticket must never be left as a bare title — always include the structured body at creation time.

For modified stories, use `.claude/scripts/dso ticket comment <existing-id> "<updated content>"` to record changes.

For stories to delete:
```bash
.claude/scripts/dso ticket transition <id> open closed
```

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
  ← Satisfies: "[quoted epic criterion]"
- When this story is complete, [observable outcome 2]
  ← Satisfies: "[quoted epic criterion]"
```

Example:
```
Done Definitions:
- When this story is complete, a user can view all extracted rules
  for a document, mark individual rules as approved or rejected,
  and see a summary count of pending reviews
  ← Satisfies: "Users can review extracted rules before export"
- When this story is complete, reviewed rules persist across sessions
  and are visible when the user returns to the same document
  ← Satisfies: "Review state is preserved"
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
3. Do NOT proceed with stories whose DDs contradict their SCs — this produces plans that are structurally guaranteed to fail the completion verifier (c734-2e8c).

#### TDD Done-of-Done Requirement

Code-change stories (stories that produce or modify source code) must include **'unit tests written and passing for all new or modified logic'** as a Done Definition. This is a unit test DoD requirement applied at the story level.

Documentation, research, and other non-code stories are exempt from this requirement — their Done Definitions focus on observable outcomes rather than test coverage.

#### Considerations
Notes from the Risk & Scope Scan (Phase 2). These provide context for `/dso:implementation-plan` to incorporate into task-level acceptance criteria:

```
Considerations:
- [Performance] Large file processing — consider timeout behavior
- [Testing] New LLM interaction — ensure mock-compatible interface
- [Accessibility] New interactive page — WCAG 2.1 AA compliance required
```

#### Escalation Policy

Include the policy selected in Phase 1 Step 1b. Use the exact text for each label:

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

After all implementation stories are drafted, create one final story to update project documentation. This story:

- **Updates existing docs only** — do not create new documentation files or patterns
- **Targets**: `CLAUDE.md` (architecture section, quick reference), `.claude/design-notes.md`, ADRs, `KNOWN-ISSUES.md`, or other docs that already exist and would become stale after the epic is complete
- **Scope**: Concise updates that ensure future agents have accurate awareness of the project state (new routes, changed patterns, updated commands, removed features)
- **Style guide**: Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting, structure, and conventions when writing documentation updates
- **Depends on**: All implementation stories (runs last)
- **Title format**: "Update project docs to reflect [epic summary]"
- **Skip if**: The epic makes no changes that would affect existing documentation (document rationale)

When creating the documentation update story via `.claude/scripts/dso ticket create`, add a note with the guide reference so sub-agents find it in their ticket payload:
```bash
.claude/scripts/dso ticket comment <story-id> "Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions."
```

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
- If an epic is **TRIVIAL** (single story, no external dependencies) and the story already contains unit test acceptance criteria, a separate TDD test story may be omitted. Document the rationale.

### Step 3: Present Story Dashboard (/dso:preplanning)

**Non-interactive suppress (CP5)**: If `PREPLANNING_INTERACTIVE=false`:
- Suppress dashboard presentation (continue silently without presenting the dashboard to the user).
- Skip the table and full story descriptions below; proceed directly to Step 4.

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
  ← Satisfies: "[epic criterion]"

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

**Non-interactive skip (CP6)**: If `PREPLANNING_INTERACTIVE=false`:
- Skip the approval gate (proceed automatically without `AskUserQuestion`).
- Treat the plan as approved and continue immediately to Step 5a, Step 6, and Step 7.

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

If the user requests changes, iterate on the plan and re-present. Once the user selects "Approve — finalize and proceed", immediately continue to Step 5a, Step 6, and Step 7 without pausing for additional input — approval is the signal to proceed, not a stopping point.

### Step 5a: Write Planning Context to Epic Ticket (/dso:preplanning)

Write the accumulated context as a structured comment on the epic ticket so that `/dso:implementation-plan` can load richer context when planning individual stories from this epic, regardless of which session or environment runs next.

**Schema version**: The `schema_version` integer field (current value: `2`) is used by consumers for forward/backward compatibility — bump it whenever the payload structure changes in a non-additive way. Consumers reading an unfamiliar `schema_version` should fall back to defensive parsing rather than failing.

**Merging prior research findings (RESEARCH_FINDINGS:)**: Before writing the new `PREPLANNING_CONTEXT:` comment, scan the epic's ticket comments for the most recent `RESEARCH_FINDINGS:` comment (a JSON array of `{capability, status, source, skill_name, timestamp}` entries written by upstream skills like brainstorm or prior preplanning runs). Parse it and merge into the `researchFindings` array of the new context payload. Treat a missing or corrupt `RESEARCH_FINDINGS:` comment as an empty array (fail-open — never block the write). This compounds research across pipeline stages so downstream skills (implementation-plan, sprint) can deduplicate WebSearch calls.

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

Serialize the JSON payload to a single minified line (no whitespace between keys/values) and write it as a ticket comment. If `/dso:preplanning` runs again on the same epic, write a new comment — `/dso:implementation-plan` will use the last `PREPLANNING_CONTEXT:` comment in the array.

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
- **All stories**: IDs, titles, descriptions, priorities, classifications (from Phase 1 reconciliation), walking skeleton flags (from Phase 3), done definitions and considerations (from Phase 2 Risk & Scope Scan), split role and pair info (from Phase 3 Step 4), dependency links, and traceability lines (from Phase 4 Step 2)
- **Story dashboard**: total story count, UI story count, critical path order
- **`generatedAt`**: Current ISO-8601 timestamp for staleness detection

Write the context as a ticket comment using `.claude/scripts/dso ticket comment`. If `/dso:preplanning` runs again on the same epic, write a new comment — `/dso:implementation-plan` uses the last `PREPLANNING_CONTEXT:` comment in the array.

> **TTL note for consumers**: The `generatedAt` timestamp enables staleness detection. Consumers should treat `PREPLANNING_CONTEXT` comments older than 7 days as potentially stale — epic scope, story priorities, or dependency structures may have changed since generation. When consuming a stale context, re-invoke `/dso:preplanning` to refresh it rather than relying on outdated data.

Log: `"Planning context written to epic ticket <epic-id> as PREPLANNING_CONTEXT comment"`

### Step 6: Design Wireframes for UI Stories (/dso:preplanning)

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
2. Agent dispatch via the Agent tool (read `agents/ui-designer.md` inline, use `subagent_type: "general-purpose"` with `model: "sonnet"` — `dso:ui-designer` is an agent file identifier, NOT a valid `subagent_type` value)
3. CACHE_MISSING retry loop (2 retry attempts; up to 3 total CACHE_MISSING
   returns before the retry cap is exceeded)
4. Review loop (orchestrator-managed: invoke `/dso:review-protocol` on design
   artifacts; max 3 cycles; REVIEW_PASS → tag `design:approved` and proceed;
   REVIEW_FAIL → re-dispatch ui-designer with feedback; at max cycles:
   interactive → ask user; non-interactive → emit INTERACTIVITY_DEFERRED,
   tag `design:pending_review`, and proceed)
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

### Step 7: Sync Tickets (/dso:preplanning)

After wireframe phase completes (or is skipped), confirm all ticket state is
up to date and report completion.

---

## Appendix: Lightweight Mode Specification

When `--lightweight` is passed:

1. **Skip Steps 2-4** of Phase 1 (no children to reconcile)
2. **Skip Phase 2.5** (Adversarial Review) entirely — lightweight mode does not create stories, so cross-story analysis is not applicable
3. Proceed to **Phase 2 (abbreviated)**: Run the Risk & Scope Scan but with these modifications:
   - **Run** the Concern Areas scan (Security, Performance, Accessibility, Testing, Reliability, Maintainability)
   - **Run** the qualitative override check from the epic complexity evaluator (multiple personas, UI + backend, new DB migration, foundation/enhancement candidate, external integration)
   - **Skip** split-candidate identification (no stories to split)
4. **If any COMPLEX qualitative override is discovered** that the evaluator missed:
   - Do NOT write the preplanning context file
   - Do NOT modify the epic description
   - Return immediately:
     ```json
     {
       "result": "ESCALATED",
       "reason": "<override name>: <explanation>",
       "recommendation": "full_preplanning",
       "epicId": "<epic-id>"
     }
     ```
5. **If no overrides discovered**, proceed to write done definitions:
   - Update the epic description with:
     - **Done Definitions**: Observable outcomes from the epic description, formatted the same way as story-level done definitions (see Phase 4 Step 2)
     - **Scope**: What's in and what's explicitly out
     - **Considerations**: Flags from the abbreviated risk scan
   - Write the preplanning context to the epic ticket as a comment (same schema as Phase 4 Step 5a, but with an empty `stories` array) using Python subprocess to avoid ARG_MAX shell argument limits. This write is an optional cache — if it fails, log a warning and continue; do not abort the phase:
     ```python
     import json, subprocess
     payload = json.dumps(<context-dict>, separators=(",",":"))
     body = "PREPLANNING_CONTEXT_LIGHTWEIGHT: " + payload
     result = subprocess.run(
         [".claude/scripts/dso", "ticket", "comment", "<epic-id>", body],
         check=False
     )
     if result.returncode != 0:
         print("WARNING: Failed to write PREPLANNING_CONTEXT_LIGHTWEIGHT comment to epic ticket — continuing without cache write")
     ```
   Note: Lightweight mode uses the `PREPLANNING_CONTEXT_LIGHTWEIGHT:` key to avoid overwriting a full `PREPLANNING_CONTEXT:` comment. Consumers (e.g., `/dso:implementation-plan`) read `PREPLANNING_CONTEXT:` by default and only fall back to `PREPLANNING_CONTEXT_LIGHTWEIGHT:` if no full context exists.
   - Return:
     ```json
     {
       "result": "ENRICHED",
       "epicId": "<epic-id>",
       "doneDefinitions": ["<list of done definitions written>"],
       "considerations": ["<list of considerations>"]
     }
     ```

---

## Guardrails

### Epic Deps Must Not Contain Children (Critical)

**Never run `.claude/scripts/dso ticket link <epic-id> <story-id> depends_on`** — this adds the story as a dependency of the epic, causing the epic to self-block in `sprint-list-epics.sh` (bug w21-3w8y).

- `.claude/scripts/dso ticket link <story-id> <blocking-story-id> depends_on` — correct: story depends on another story
- `.claude/scripts/dso ticket link <epic-id> <child-story-id> depends_on` — **WRONG**: child added as epic blocker

Epic children are linked via `--parent=<epic-id>` at creation time. That parent field is how the epic knows what work to do. Adding a child as a dep means the epic will show as BLOCKED until the child is closed — which is backwards. Only add external dependencies (tickets from other epics/projects) to an epic's deps.

### No "How"
Focus on requirements, constraints, and outcomes. Avoid dictating specific implementation code or library choices unless mandated by the Architecture Board.

**Good**: "System must validate email format before storing"
**Bad**: "Use the `email-validator` library with pattern `^[\w.-]+@[\w.-]+\.\w+$`"

### Ticket Integrity
Check for existing items before creating new ones to prevent backlog pollution. Always run Phase 1 reconciliation before creating stories.

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
| 1: Reconciliation | Audit children, clarify scope | `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket deps` |
| 2: Risk & Scope Scan | Flag cross-cutting concerns, identify split candidates | Lightweight analysis (no sub-agents) |
| 2.5: Adversarial Review | Red team attack on story map, blue team filter findings (skip if < 3 stories) | `Task` (opus red team, sonnet blue team) |
| 3: Walking Skeleton | Prioritize critical path, apply INVEST, Foundation/Enhancement splits | Priority analysis, `.claude/scripts/dso ticket link` |
| 4: Verification | Create stories, link criteria, validate, wireframe UI stories | `.claude/scripts/dso ticket create`, `.claude/scripts/dso ticket link`, `.claude/scripts/dso ticket comment`, `validate-issues.sh`, `dso:ui-designer` (via Agent tool), `.claude/scripts/dso ticket tag`/`.claude/scripts/dso ticket untag` (design:approved on REVIEW_PASS; design:pending_review on deferred/failed review) |
| Flag-gated: external deps | When `planning.external_dependency_block_enabled=true`: reads External Dependencies block from epic, generates `manual:awaiting_user` stories for `user_manual` entries, refuses decomposition when block is missing. Schema: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md` | `.claude/scripts/dso ticket tag` |

## Example: Reconciliation + Story Creation

**Epic**: "Implement document classification pipeline"
**Epic Criterion**: "Users can upload a document and see its classification"

**Existing Child**: "Add database schema for documents" (status: pending)

**Reconciliation**:
- **Reuse?** No — this is a horizontal layer, not a vertical slice
- **Modify?** No — conflicts with vertical slicing approach
- **Delete?** Yes — will be absorbed into vertical story slices

**Risk & Scope Scan**:
- [Testing] New LLM classification interaction — ensure mock-compatible interface
- [Performance] Documents may be large (100+ pages) — consider processing timeouts
- [Accessibility] Upload and results pages are new UI — WCAG 2.1 AA required

**New Stories** (vertical slices):

**Story 1** (Foundation): "As a user, I can upload a document and see its classification"
- **Scope**: Upload flow, classification display, basic document types (PDF/Word)
- **Done Definitions**:
  - When complete, a user can upload a PDF or Word document and see its classified type within 30 seconds ← Satisfies: "Users can upload a document and see its classification"
  - When complete, the classification result persists and is visible when the user returns ← Satisfies: "Classification results are preserved"
- **Considerations**: [Testing] Mock-compatible LLM interface; [Performance] Processing timeout for large files

**Story 2** (Enhancement of Story 1): "As a user, I can see detailed classification confidence and sub-categories"
- **Scope**: Confidence scores, sub-category breakdown, classification explanation
- **Done Definitions**:
  - When complete, a user can see a confidence percentage and sub-categories for each classification ← Satisfies: "Users can understand why a document was classified a certain way"
- **Depends on**: Story 1

---

### Preconditions Exit Emit (/dso:preplanning)

[Instructions: Before the skill exits, record preplanning PRECONDITIONS event:
Run: `.claude/scripts/dso preconditions-record.sh --ticket-id <epic_id> --gate-name preplanning_complete --session-id <session_id> --tier minimal`
Self-verify: run preconditions-validator.sh --event-file=<just-written-file>; if fails emit WARN but do not block.
This validator reads only minimal-tier fields. Future standard/deep additions are ignored (depth-agnostic forward-compat contract).]

---

## SKILL_EXIT Breadcrumb

Before emitting final output or STATUS, emit the SKILL_EXIT breadcrumb:

```bash
_DSO_TRACE_END_MS=$(date +%s%3N 2>/dev/null || echo "null")
_DSO_TRACE_ELAPSED="null"
if [ "${_DSO_TRACE_START_MS}" != "null" ] && [ "${_DSO_TRACE_END_MS}" != "null" ]; then
  _DSO_TRACE_ELAPSED=$(( _DSO_TRACE_END_MS - _DSO_TRACE_START_MS ))
fi
echo "{\"type\":\"SKILL_EXIT\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)\",\"skill_name\":\"preplanning\",\"nesting_depth\":${_DSO_TRACE_DEPTH:-1},\"skill_file_size\":${_DSO_TRACE_FILE_SIZE:-null},\"tool_call_count\":null,\"elapsed_ms\":${_DSO_TRACE_ELAPSED},\"session_ordinal\":${_DSO_TRACE_SESSION_ORDINAL:-1},\"cumulative_bytes\":${_DSO_TRACE_CUMULATIVE_BYTES:-null},\"termination_directive\":false,\"user_interaction_count\":0}" >> "/tmp/dso-skill-trace-${_DSO_TRACE_SESSION_ID}.log" || true
```
