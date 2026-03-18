---
name: preplanning
description: Use when decomposing a ticket epic into prioritized user stories with measurable done definitions, or when auditing and reconciling existing epic children before implementation
user-invocable: true
allowed-tools:
  - AskUserQuestion
---

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

## Phase 1: Context Reconciliation & Discovery (/dso:preplanning)

### Step 1: Select and Load Epic (/dso:preplanning)

If `<epic-id>` was not provided:
1. Run `tk ready` then filter results to epics only (cross-reference with `grep -l '^type: epic' .tickets/*.md`)
2. If no open epics exist, report and exit
3. Present epics to the user (if more than 5, show first 5 with option to see more)
4. Get user selection

Load the epic:
```bash
tk show <epic-id>
```

### Step 1b: Select Escalation Policy (/dso:preplanning)

Use `AskUserQuestion` to ask the user which escalation policy should apply to all stories in this epic. Skip this step in `--lightweight` mode.

- **Question**: "Which escalation policy should agents apply when working on stories in this epic?"
- **Header**: "Escalation"
- **Options**:
  1. **Autonomous** — Agents proceed with best judgment at all times. Reasonable assumptions are made and documented. No escalation for uncertainty.
  2. **Escalate when blocked** — Agents proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. All assumptions made without escalating are documented.
  3. **Escalate unless confident** — Agents escalate whenever high confidence is absent. "High confidence" means clear evidence from the codebase or ticket context — not inference or reasonable assumption. When in doubt, stop and ask rather than guess.

Store the selected policy label and its full text as `{escalation_policy_label}` and `{escalation_policy_text}` for use in Phase 4 Step 2.

### Lightweight Mode Gate (/dso:preplanning)

If `--lightweight` was passed:

1. **Skip Steps 2-4** of Phase 1 (no children to reconcile)
2. **Skip Phase 2.5** (Adversarial Review) entirely — lightweight mode does not create stories, so cross-story analysis is not applicable
3. Proceed to **Phase 2 (abbreviated)**: Run the Risk & Scope Scan but with these modifications:
   - **Run** the Concern Areas scan (Security, Performance, Accessibility, Testing, Reliability, Maintainability)
   - **Run** the qualitative override check from the epic complexity evaluator (multiple personas, UI + backend, new DB migration, foundation/enhancement candidate, external integration)
   - **Skip** split-candidate identification (no stories to split)
3. **If any COMPLEX qualitative override is discovered** that the evaluator missed:
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
4. **If no overrides discovered**, proceed to write done definitions:
   - Update the epic description with:
     - **Done Definitions**: Observable outcomes from the epic description, formatted the same way as story-level done definitions (see Phase 4 Step 2)
     - **Scope**: What's in and what's explicitly out
     - **Considerations**: Flags from the abbreviated risk scan
   - Write the preplanning context file to `/tmp/preplanning-context-<epic-id>.json` (same schema as Phase 4 Step 5a, but with an empty `stories` array)
   - Return:
     ```json
     {
       "result": "ENRICHED",
       "epicId": "<epic-id>",
       "doneDefinitions": ["<list of done definitions written>"],
       "considerations": ["<list of considerations>"]
     }
     ```

If `--lightweight` was NOT passed, continue to Phase 1 Step 2 as normal.

### Step 2: Audit Existing Children (/dso:preplanning)

Gather all existing child items:
```bash
tk dep tree <epic-id>
```

For each child, run `tk show <child-id>` to read full details.

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

### Step 4: Document Reconciliation Plan (/dso:preplanning)

Before creating new stories, present a reconciliation summary:

| Child ID | Title | Status | Recommendation | Rationale |
|----------|-------|--------|----------------|-----------|
| xxx-123 | ... | pending | Reuse | Aligns with Epic criterion 1 |
| xxx-124 | ... | in_progress | Modify | Needs updated success criteria |
| xxx-125 | ... | pending | Delete | Redundant with new story approach |

Use `AskUserQuestion` to get user approval before proceeding:
- Question: "The reconciliation plan above summarizes how existing children will be handled. Do you approve this plan?"
- Options: ["Approve — proceed with story creation", "Request changes"]

If the user requests changes, iterate on the reconciliation plan and re-present.

---

## Phase 2: Risk & Scope Scan (/dso:preplanning)

Scan all drafted stories (new and modified) as a batch to flag cross-cutting concerns that individual tasks would be too granular to catch. This is a lightweight analysis — no sub-agent dispatch, no scored review, no revision cycles.

### Concern Areas

Read [docs/review-criteria.md](docs/review-criteria.md) for the full list of
reviewers and their focus areas. The six concern areas are:

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

## Phase 2.5: Adversarial Review (/dso:preplanning)

### Threshold Gate

**Skip this phase if fewer than 3 stories exist** after Phase 2 completes. Adversarial review adds value only when there are enough stories for cross-story interactions to matter. If skipped, log: `"Adversarial review skipped: fewer than 3 stories (<N> stories)."` and proceed directly to Phase 3.

### Step 1: Red Team Dispatch (/dso:preplanning)

Dispatch an **opus** sub-agent using the red team prompt template. Fill all placeholders from Phase 2 output:

- **Prompt template**: `prompts/red-team-review.md` (relative to this skill directory)
- **Placeholders**:
  - `{epic-title}`: Epic title from Phase 1
  - `{epic-description}`: Epic description from Phase 1
  - `{story-map}`: All stories with their done definitions, considerations, and dependencies (formatted from Phase 2 output)
  - `{risk-register}`: Risk Register table from Phase 2
  - `{dependency-graph}`: Dependency graph from `tk dep tree <epic-id>`

The red team sub-agent returns a JSON `findings` array. Parse the response and validate it contains well-formed JSON with the expected schema (array of objects with `type`, `target_story_id`, `title`, `description`, `rationale`, `taxonomy_category` fields).

**Fallback**: If the red team sub-agent times out, returns malformed output, or fails to produce valid JSON, log a warning: `"Red team review failed: <reason>. Skipping adversarial review, proceeding to Phase 3."` and skip directly to Phase 3.

### Step 2: Blue Team Dispatch (/dso:preplanning)

If the red team returns a non-empty findings array, dispatch a **sonnet** sub-agent using the blue team prompt template:

- **Prompt template**: `prompts/blue-team-review.md` (relative to this skill directory)
- **Placeholders**:
  - `{epic-title}`: Same as red team
  - `{epic-description}`: Same as red team
  - `{story-map}`: Same as red team
  - `{red-team-findings}`: The raw JSON findings array from the red team sub-agent

The blue team sub-agent returns a filtered JSON object with `findings` (accepted) and `rejected` arrays.

**If red team returned zero findings**: Skip the blue team dispatch entirely. Log: `"Red team found no cross-story gaps. Skipping blue team filter."` and proceed to Phase 3.

**Partial failure**: If the red team succeeds but the blue team fails (timeout, malformed output, or error), **discard all unfiltered findings** and proceed to Phase 3. Do NOT apply unfiltered red team findings -- the blue team filter exists to prevent false positives from polluting the story map. Log: `"Blue team filter failed: <reason>. Discarding unfiltered red team findings, proceeding to Phase 3."`

### Step 3: Apply Surviving Findings (/dso:preplanning)

Parse the blue team's accepted findings and apply each one based on its `type`:

| Finding Type | Action |
|-------------|--------|
| `new_story` | Create a new story: `tk create "<title>" -t story --parent=<epic-id>`. Add the finding's description and rationale to the story description. Add appropriate done definitions and considerations. |
| `modify_done_definition` | Edit the target story's ticket file (`.tickets/<target_story_id>.md`) to add or modify done definitions per the finding's description. |
| `add_dependency` | Add the dependency: `tk dep <target_story_id> <dependency_id>` (extract dependency ID from the finding's description). |
| `add_consideration` | Edit the target story's ticket file to append the consideration to its Considerations section. |

Log a summary after applying findings:
```
Adversarial review complete:
- Red team findings: <N> total
- Blue team filtered: <M> rejected, <K> accepted
- Applied: <A> new stories, <B> modified done definitions, <C> new dependencies, <D> new considerations
```

### Step 4: Continue to Phase 3

Proceed to Phase 3 (Walking Skeleton & Vertical Slicing) with the updated story map. New stories from adversarial review are included in the walking skeleton analysis.

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
- Add dependency: `tk dep <enhancement-id> <foundation-id>`
- Both trace to the same epic criterion

**Note**: `/dso:design-wireframe` has its own Pragmatic Scope Splitter (Step 10) that may trigger UI-specific splits during design. If preplanning already split a story, the design agent works within the Foundation story's scope.

---

## Phase 4: Verification & Traceability (/dso:preplanning)

### Step 1: Create/Modify Stories in Tickets (/dso:preplanning)

For new stories, use `--parent` at creation time to get the ID, then immediately write the full story body to the ticket file:

```bash
# Step 1: create and capture ID
STORY_ID=$(tk create "As a [persona], [goal]" -t story -p <priority> --parent=<epic-id>)

# Step 2: write the full structured body to the ticket file
# Use the Write or Edit tool to set the content below the frontmatter
# Include: Description (what/why/scope), Done Definitions, Considerations, Escalation Policy
```

Write the story body using the story structure defined in Step 2 below. The ticket file is `.tickets/<story-id>.md`. Preserve the YAML frontmatter (lines 1–N ending with `---`) and replace everything after it with the structured markdown body.

For modified stories, edit `.tickets/<existing-id>.md` directly to update the title heading and body sections.

For stories to delete:
```bash
tk close <id>
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
tk dep <story-id> <blocking-story-id>
```

### Documentation Update Story

After all implementation stories are drafted, create one final story to update project documentation. This story:

- **Updates existing docs only** — do not create new documentation files or patterns
- **Targets**: `CLAUDE.md` (architecture section, quick reference), `DESIGN_NOTES.md`, ADRs, `KNOWN-ISSUES.md`, or other docs that already exist and would become stale after the epic is complete
- **Scope**: Concise updates that ensure future agents have accurate awareness of the project state (new routes, changed patterns, updated commands, removed features)
- **Style guide**: Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting, structure, and conventions when writing documentation updates
- **Depends on**: All implementation stories (runs last)
- **Title format**: "Update project docs to reflect [epic summary]"
- **Skip if**: The epic makes no changes that would affect existing documentation (document rationale)

When creating the documentation update story via `tk create`, add a note with the guide reference so sub-agents find it in their ticket payload:
```bash
tk add-note <story-id> "Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions."
```

### Step 3: Present Story Dashboard (/dso:preplanning)

Display a summary table:

| ID | Title | Priority | Status | Blocks | Split | Satisfies Criterion |
|----|-------|----------|--------|--------|-------|---------------------|
| xxx-126 | As a user... | P1 | pending | xxx-127 | Foundation | Epic criterion 1 |
| xxx-127 | As a user... | P2 | pending | - | Enhancement of xxx-126 | Epic criterion 1 |
| xxx-128 | As a dev... | P1 | pending | - | - | Epic criterion 2 |

### Step 4: Validate Dependencies (/dso:preplanning)

After creating all stories and dependencies:
```bash
$(git rev-parse --show-toplevel)/scripts/validate-issues.sh
```

If score < 5, fix issues before presenting to user.

### Step 5: Final Review Prompt (/dso:preplanning)

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
3. Approve to sync to tickets, or request adjustments

Does this plan fully capture your vision and the necessary technical safeguards? Should we adjust any priorities before I finalize this in the ticket system?
```

Use `AskUserQuestion` to get user approval:
- Question: "The story map above captures the full plan for this epic. Do you approve?"
- Options: ["Approve — finalize and proceed", "Request changes"]

If the user requests changes, iterate on the plan and re-present. Once the user selects "Approve — finalize and proceed", immediately continue to Step 5a, Step 6, and Step 7 without pausing for additional input — approval is the signal to proceed, not a stopping point.

### Step 5a: Write Planning Context File (/dso:preplanning)

Write the accumulated context to `/tmp/preplanning-context-<epic-id>.json` so that `/dso:implementation-plan` can load richer context when planning individual stories from this epic.

**File path**: `/tmp/preplanning-context-<epic-id>.json`

**Schema** (version 1):
```json
{
  "version": 1,
  "epicId": "<epic-id>",
  "generatedAt": "<ISO-8601 timestamp>",
  "generatedBy": "preplanning",
  "epic": {
    "title": "...",
    "description": "...",
    "successCriteria": ["..."]
  },
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

Write the file using the Write tool. If `/dso:preplanning` runs again on the same epic, the file is overwritten (newer context wins).

Log: `"Planning context written to /tmp/preplanning-context-<epic-id>.json"`

### Step 6: Design Wireframes for UI Stories (/dso:preplanning)

After the user approves the story map, invoke `/dso:design-wireframe` for **any story that involves UI changes**. The `/dso:design-wireframe` skill will determine whether new UI components, layouts, or wireframes are actually needed — your job is only to identify candidates and pass them through.

A story is a candidate if it:
- Mentions user-facing screens, pages, views, or components
- Includes frontend routes, forms, dashboards, or visual elements
- Has success criteria describing what a user **sees** or **interacts with**
- Modifies existing UI behavior, templates, or JavaScript interactions

Stories that are purely backend, infrastructure, testing-only, or documentation do NOT qualify.

**Skip if**: No stories in the plan involve UI changes. Document this: "No UI stories identified — skipping wireframe phase."

#### Wireframe Session File Lifecycle

When multiple UI stories need wireframes, create a **session file** to avoid
redundant reads across serial `/dso:design-wireframe` invocations.

**Before the first wireframe invocation**:

1. Read `DESIGN_NOTES.md` content (if it exists).
2. Create `/tmp/wireframe-session-<epic-id>.json`:
   ```json
   {
     "version": 1,
     "epicId": "<epic-id>",
     "createdAt": "<ISO-8601 timestamp>",
     "designNotes": {
       "exists": true,
       "content": "<full DESIGN_NOTES.md content or null if missing>"
     },
     "processedStories": [],
     "siblingDesigns": []
   }
   ```
3. Log: `"Created wireframe session file for epic <epic-id> with <N> UI stories
   to process."`

**For each qualifying story**, invoke `/dso:design-wireframe`:

```
/dso:design-wireframe <story-id>
```

**After each `/dso:design-wireframe` completes**:

1. Read the design manifest path from the story's `design` field:
   `tk show <story-id>`
2. Append the story to the session file's `processedStories` array:
   ```json
   {
     "storyId": "<story-id>",
     "designManifestPath": "<path from design field>",
     "completedAt": "<ISO-8601 timestamp>"
   }
   ```
3. Append the manifest path to the `siblingDesigns` array (for subsequent
   invocations to read without re-scanning).
4. Log: `"Updated wireframe session: <N>/<total> stories processed."`

**Order**: Process stories in dependency order (stories with no blockers first,
then stories that depend on them). This ensures base wireframes exist before
dependent designs reference them.

### Step 7: Sync Tickets (/dso:preplanning)

After wireframe phase completes (or is skipped), confirm all ticket state is
up to date and report completion.

---

## Guardrails

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
| 1: Reconciliation | Audit children, clarify scope | `tk show`, `tk dep tree` |
| 2: Risk & Scope Scan | Flag cross-cutting concerns, identify split candidates | Lightweight analysis (no sub-agents) |
| 2.5: Adversarial Review | Red team attack on story map, blue team filter findings (skip if < 3 stories) | `Task` (opus red team, sonnet blue team) |
| 3: Walking Skeleton | Prioritize critical path, apply INVEST, Foundation/Enhancement splits | Priority analysis, `tk dep` |
| 4: Verification | Create stories, link criteria, validate, wireframe UI stories | `tk create`, `tk dep`, `.tickets/<id>.md` editing, `validate-issues.sh`, `/dso:design-wireframe` |

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
