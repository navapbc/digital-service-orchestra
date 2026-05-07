---
name: preplanning
description: Use when breaking down an epic into user stories, story splitting, backlog grooming, defining acceptance criteria, or auditing and reconciling existing epic children before implementation. Decomposes the epic into prioritized vertical-slice user stories, drafts measurable done definitions per story, identifies dependencies, runs an adversarial red-team review pass, dispatches a UI designer for UI stories, and writes the story tickets to the tracker. Trigger phrases include 'break down this epic', 'split into stories', 'story splitting', 'backlog grooming', 'write user stories', 'define acceptance criteria', 'plan the epic', 'decompose the epic', 'reconcile epic children'.
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

- **Phase A**: Reconciliation — audit existing work, clarify scope
- **Phase B**: External Dependencies Reading (flag-gated) — read epic's External Dependencies block, generate manual:awaiting_user stories
- **Phase C**: Risk & Scope Scan — flag cross-cutting concerns, identify split candidates
- **Phase D**: Integration Research — verify external integrations pre-slicing
- **Phase E**: Adversarial Review — red/blue team review for cross-story blind spots (3+ stories only)
- **Refusal Gate**: External Dependencies coverage check (flag-gated) — halt if externally-shaped SCs lack block coverage
- **Phase F**: Walking Skeleton & Vertical Slicing — prioritize minimum viable path, Foundation/Enhancement splits
- **Phase G**: Story-Level Research — research per-story decomposition gaps post-slicing
- **Phase H**: Verification & Traceability — create stories, link criteria, validate, wireframe UI stories

**Lightweight mode** (`--lightweight`): runs an abbreviated subset (Phase A Step 1, abbreviated Phase C); see Lightweight Mode Appendix for the authoritative spec. Returns `ENRICHED` or `ESCALATED`.

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

## UI Probes Deferred Gate

Before proceeding, check if the epic has a `ui_probes:deferred` tag:

1. Run `.claude/scripts/dso ticket show <epic-id>` and check the `tags` field
2. If `ui_probes:deferred` is present in the tags array: **HALT immediately**. Output:
   "This epic has unresolved UX probe gaps from a non-interactive brainstorm run. Re-run `/dso:brainstorm <epic-id>` interactively to complete the UX probe questions, then retry `/dso:preplanning`."
   Do NOT produce any planning output.
3. If `ui_probes:deferred` is NOT present (or tags field is empty/absent): proceed normally.

This is a presence-based check — only block when the tag IS present. Existing epics without the tags field are NOT blocked. If ticket show fails, treat the tag as absent and proceed (fail-open).

---

### Preconditions Entry Gate (/dso:preplanning)

<!-- Schema reference: docs/designs/stage-boundary-preconditions/ -->

[Instructions for the LLM: Before Phase A Step 1, validate that a brainstorm PRECONDITIONS event exists.
Run: `.claude/scripts/dso preconditions-validator.sh <epic_id> brainstorm_complete [--event-file=<path if known>]`
(or use preconditions-record.sh invocation from brainstorm; fail-open if script not found)
If exit 0: continue. If exit 1: BLOCK with PRECONDITIONS_GATE_BLOCKED diagnostic.
If exit 2 (not found): BLOCK with "Run /dso:brainstorm first" message.
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

## Phase C: Risk & Scope Scan (/dso:preplanning)

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

Follow the shared research procedure in `prompts/research-process.md` (single authoritative source — covers researchFindings dedup, the WebSearch-and-verify steps, REPLAN_ESCALATE emission, and graceful degradation). This phase is the pre-slicing trigger for that procedure.

### Skip Condition

If no stories in the plan qualify for integration research, log: "No stories with external integration signals — skipping integration research." and proceed to Phase E.

---

## Phase E: Adversarial Review (branch — ≥3 stories; skipped under --lightweight)

**Trigger**: Phase C completed and the story map has ≥ 3 stories. If fewer, log `"Adversarial review skipped: fewer than 3 stories (<N> stories)."` and proceed directly to Phase F. Skipped entirely under `--lightweight` (lightweight mode does not create stories).

**Load**: `${CLAUDE_PLUGIN_ROOT}/skills/preplanning/prompts/phase-e-adversarial-review.md` and follow it. The phase dispatches `dso:red-team-reviewer` (opus) with `mode: story_review` for cross-story gap analysis, then `dso:blue-team-filter` (sonnet) to triage findings; applies surviving findings per a 5-row Finding Type table (`new_story`, `modify_done_definition`, `add_dependency`, `add_consideration`, `escalate_to_epic`); persists the full red/blue exchange to `$ARTIFACTS_DIR/adversarial-review-<epic-id>.json`; and emits `REPLAN_ESCALATE: brainstorm` when a finding escalates to the epic and `sprint.max_replan_cycles` has not been exhausted.

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

If WebSearch or WebFetch fails or is unavailable, continue without research rather than blocking the workflow. Log: `"Story-level research skipped for <story-id>: WebSearch/WebFetch unavailable."` and proceed to Phase H.

### Skip Condition

If no stories qualify under the trigger conditions above, log: `"No stories with decomposition gaps — skipping story-level research."` and proceed to Phase H.

---

## Phase H: Verification & Traceability (/dso:preplanning)

### Step 1: Create/Modify Stories in Tickets (/dso:preplanning)

For new stories, create the ticket then immediately write the full story body into the ticket file:

```bash
# Assemble the story body from earlier phases and create the ticket in one command:
# - Description: What/Why/Scope from Phase C analysis
# - Done Definitions: assembled during Phase F
# - Considerations: flags from Phase C Risk & Scope Scan
# - Escalation Policy: selected in Phase A Step 2 (omit if Autonomous)

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
- **CLAUDE.md is not a default target.** Authoring a doc story whose primary target is CLAUDE.md is an anti-pattern; the router prefers SKILL.md / reference docs / ADRs and only escalates to CLAUDE.md when Gate 5 strictly holds. See CLAUDE.md Architectural Invariant #2 (bloat criteria a–d).
- **Depends on**: all implementation stories (runs last).
- **Title format**: "Update project docs to reflect [epic summary]".
- **Style guide**: follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting and structure.

When creating the documentation update story via `.claude/scripts/dso ticket create`, attach the router and style references so sub-agents find them in the ticket payload:
```bash
.claude/scripts/dso ticket comment <story-id> "Apply ${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/doc-router.md gates before writing. CLAUDE.md edits require a CLAUDE_MD_SUGGESTED_CHANGE report — do not edit CLAUDE.md directly. Follow .claude/docs/DOCUMENTATION-GUIDE.md for formatting."
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
- If an epic is **TRIVIAL** (single story, no external dependencies) and the story already contains unit test acceptance criteria, a separate TDD test story may be omitted. Document the rationale.

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
| A: Reconciliation | Audit children, clarify scope | `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket deps` |
| B: External Dependencies Reading (flag-gated) | Read epic's External Dependencies block, generate `manual:awaiting_user` stories for `user_manual` entries. Schema: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md` | `.claude/scripts/dso ticket tag` |
| C: Risk & Scope Scan | Flag cross-cutting concerns, identify split candidates | Lightweight analysis (no sub-agents) |
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

