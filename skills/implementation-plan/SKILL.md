---
name: implementation-plan
description: Use when a user story or simple epic needs to be broken into atomic, TDD-driven implementation tasks with architectural review, or when planning how to implement a specific ticket item
user-invocable: true
---

# Implementation Plan: Atomic Task Generation

Generate a production-safe implementation plan for a User Story by decomposing it into atomic, TDD-driven tasks with correct dependencies. Prioritize understanding over assumptions — resolve ambiguity before planning.

> **Worktree Compatible**: All commands use dynamic path resolution and work from any worktree.

## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/lockpick-workflow}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)
```

Resolution order: See `lockpick-workflow/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — replaces `make test-unit-only` in acceptance criteria templates generated during Step 3 (Task Drafting)
- `LINT_CMD` — replaces `make lint` in acceptance criteria templates
- `FORMAT_CHECK_CMD` — replaces `make format-check` in acceptance criteria templates

**Supports dryrun mode.** Use `/dryrun /implementation-plan` to preview without changes.

## Usage

```
/implementation-plan                  # Interactive story selection
/implementation-plan <story-id>       # Plan specific user story
/implementation-plan <epic-id>        # Plan simple epic directly (when routed by /sprint)
```

## Arguments

- `<story-id>` or `<epic-id>` (optional): The ticket item to decompose. Accepts stories (creates tasks under the story) or epics (creates tasks directly under the epic). If omitted, presents an interactive list of open stories.

## Progress Checklist

> **TodoWrite rule**: Only create `TodoWrite` items from this checklist when `/implementation-plan` is invoked **standalone** (directly by the user). When invoked from `/sprint`, do NOT call `TodoWrite` — `/sprint` owns the `TodoWrite` list and calling it here will wipe the active sprint checklist. Track progress through inline notes instead.

Copy and track as you work (standalone only):

```
Progress:
- [ ] Step 1: Contextual Discovery (story loaded, context gathered, ambiguities resolved, cross-cutting detection done — layers: _, interfaces: _)
- [ ] Step 2: Architectural Review via /review-protocol (passed / skipped — no new pattern)
- [ ] Step 3: Task Drafting (tasks drafted with E2E + docs coverage)
- [ ] Step 4: Plan Review via /review-protocol (all dimensions: 5, iteration: _/3)
- [ ] Step 5: Task Creation (tasks created, deps added, health validated)
```

## Process Overview

```
Flow: S1 (Discovery) → [ambiguities?] → Yes: Clarify with user → S1 (loop)
  → No: [evaluator output provided?]
    → Yes: Sanity-check evaluator counts → Apply escalation rule
    → No: [cross-cutting? ≥3 layers OR ≥5 interfaces]
      → Yes: FORCE S2 (Arch Review) regardless of new-pattern flag
      → No: [new pattern needed?]
        → Yes: S2 (Arch Review) → [pass] S3 | [fail, iter<3] Revise → S2 | [fail, iter=3] Fallback → S3
        → No: S3 (Task Drafting) → S4 (Plan Review)
          → [score=5] S5 (Task Creation)
          → [score<5, iter<3] Revise → S4
          → [score<5, iter=3] Present plan with remaining issues
```

---

## Step 1: Contextual Discovery (/implementation-plan)

### Select Story

If `<story-id>` was not provided:
1. Run `tk ready` to show open, unblocked stories
2. If none, fall back to `tk blocked` and `tk closed` to understand state
3. If no open stories exist, report and exit
4. Present stories to the user and get selection

Load the story:
```bash
tk show <story-id>
```

If the story is not found, report the error and exit.

### Epic Type Detection

After loading the item with `tk show`, check the `type` field in the output:

- **If `type` is `epic`**: Enter **epic-direct mode**:
  - The epic's done definitions serve as acceptance criteria source (same role as story done definitions)
  - Skip "load parent epic for context" in Input Analysis (the epic IS the context)
  - Tasks will be created as direct children of the epic (not children of a story)
  - Skip the Context File Check below (context files are keyed by parent epic, but there is no parent)
  - Proceed directly to **Architectural Alignment**
  - In Step 5 (Task Creation), use `--parent=<epic-id>` (if supported) instead of `--parent=<story-id>`

- **If `type` is not `epic`** (task, story, etc.): Continue with the existing flow below (Context File Check → Input Analysis → etc.)

### Context File Check

After loading the story with `tk show <story-id>`, check for a preplanning context file:

1. Extract the parent epic ID from the story's `parent` field
2. Check for `/tmp/preplanning-context-<parent-epic-id>.json`
3. If found AND `generatedAt` is within the last 24 hours:
   - Load epic data from the context file (skip `tk show <parent-epic-id>`)
   - Load sibling stories from the context file (skip `tk dep tree` + per-sibling `tk show`)
   - Carry forward: review findings, walking skeleton flags, classifications, traceability lines, story dashboard
   - Log: `"Context loaded from preplanning — skipping redundant epic/sibling fetch"`
   - **Skip the Input Analysis section below** and proceed directly to Architectural Alignment
4. If not found OR stale (>24 hours):
   - Proceed with normal Input Analysis below (no change to current behavior)

### Input Analysis

Load the story and its parent epic for full context:

```bash
tk show <story-id>
# Extract parent ID from the 'parent' field, then:
tk show <parent-epic-id>
# Review sibling stories for context:
tk dep tree <parent-epic-id>
```

If no parent epic exists, proceed with story context alone but note the limited context.

### Architectural Alignment

Search for architecture docs and existing patterns:
- Glob for `docs/**/*.md` and `.claude/docs/**/*.md`
- Grep for "system context", "architecture", "standardization", "ADR"
- Glob for `docs/adr/**/*.md` to find existing Architecture Decision Records

### Ambiguity Scan

**Curiosity before planning.** After gathering context, actively scan for ambiguity. A plan built on assumptions is worse than no plan.

Check for these signals:

| Signal | Example | Action |
|--------|---------|--------|
| **Undefined scope boundaries** | "improve performance" — of what? by how much? | Ask for measurable criteria |
| **Implicit acceptance criteria** | "user can upload files" — what types? size limits? | Ask for constraints |
| **Conflicting signals** | Epic says X, story says Y, codebase does Z | Surface the conflict |
| **Missing persona** | "as a user" — admin or end-user? | Ask which role |
| **Unstated constraints** | API story with no mention of auth or rate limiting | Ask if intentionally omitted |
| **Ambiguous priority** | Multiple criteria, unclear what's essential vs. nice-to-have | Ask for priority ranking |

**How to ask:**
- Batch all questions in a single message (not one at a time)
- Separate into **blocking** ("cannot plan without this") and **defaultable** ("I'll assume X unless you say otherwise")
- Never ask about things clearly inferrable from the codebase or parent epic

**If no ambiguities found**, proceed to Cross-Cutting Change Detection.

### Cross-Cutting Change Detection

#### Evaluator Shortcut

If complexity-evaluator output was provided (when invoked from `/sprint`):

1. **Reuse evaluator findings** — use `layers_touched` count and `interfaces_affected` count directly
2. **Sanity-check** — verify the evaluator's layer/interface counts against the story context gathered in Architectural Alignment. If the counts seem wrong (e.g., evaluator missed a layer), note the discrepancy and proceed with corrected counts
3. **Apply escalation rule** below using the verified counts
4. **Skip** the full "How to detect cross-cutting changes" analysis (tracing data/control flow, grepping for interfaces)

If no evaluator output (standalone `/implementation-plan` invocation):
- Perform full cross-cutting analysis as defined below (no change)

After resolving ambiguities (or if none exist), assess whether the change cuts across multiple architectural layers before deciding whether to escalate to Step 2.

**Why this matters:** Changes that appear simple in isolation often ripple across the stack in ways that require full architectural review. Estimating such tasks as SIMPLE leads to underestimation, missed interfaces, and brittle plans.

#### How to detect cross-cutting changes

Using the story description and the codebase context gathered in Architectural Alignment:

1. **Trace the data/control flow** from the story's entry point to its deepest dependency:
   - Identify every architectural layer the change touches (e.g., route → service → model → DB, or route → agent → LLM provider → formatter → output node)
   - Count the distinct layers: **≥ 3 layers = cross-cutting threshold met**

2. **Count interfaces/classes that need updates:**
   - Grep/Glob for classes, abstract base types, Protocol definitions, and public method signatures that the story requires changing
   - Count distinct files or classes requiring edits: **≥ 5 interfaces/classes = cross-cutting threshold met**

> **Architectural layers for this project** (each counts as one layer):
> Route/Blueprint → Service/DocumentProcessor → Agent/Node → LLM Provider/Client → Formatter → DB/SQLAlchemy Model → Migration

#### Escalation rule

| Condition | Action |
|-----------|--------|
| ≥ 3 architectural layers touched | Force Step 2 (Architectural Review) — mark as **CROSS-CUTTING** |
| ≥ 5 interfaces/classes need updates | Force Step 2 (Architectural Review) — mark as **CROSS-CUTTING** |
| Both thresholds met | Force Step 2, note both signals in the review subject |
| Neither threshold met | Proceed to the new-pattern check as normal |

**When escalating**, annotate the Step 2 subject line:
```
"Architectural Pattern: {pattern name} [CROSS-CUTTING — {N} layers / {M} interfaces]"
```

This annotation tells the Step 2 reviewer why a full review was triggered even if no new pattern is proposed.

**If no cross-cutting signals found**, proceed to Step 2 only if a new pattern is needed; otherwise skip to Step 3.

---

## Step 2: Consistency & Architectural Review (/implementation-plan)

Determine if the implementation requires a new architectural pattern or a modification to an existing one. If not, skip to Step 3.

### Architectural Review via `/review-protocol`

If a pattern change is proposed, invoke `/review-protocol` with:

- **subject**: "Architectural Pattern: {pattern name}"
- **artifact**: The proposed pattern description plus relevant architecture docs and existing patterns found in Step 1
- **pass_threshold**: 4
- **start_stage**: 1
- **perspectives**: Read from reviewer files in `docs/reviewers/architectural/`:
  - [docs/reviewers/architectural/best-practices.md](docs/reviewers/architectural/best-practices.md) — perspective: `"Best Practices"`
  - [docs/reviewers/architectural/project-alignment.md](docs/reviewers/architectural/project-alignment.md) — perspective: `"Project Alignment"`
  - [docs/reviewers/architectural/justification.md](docs/reviewers/architectural/justification.md) — perspective: `"Justification"`

### Fallback

If the review fails after autonomous resolution (2 fix/defend attempts) and user escalation, revert to existing patterns and note the unresolved concern for the user. If no existing pattern solves the story, halt and consult the user.

---

## Step 3: Atomic Task Drafting (/implementation-plan)

Draft tasks that **collectively fulfill all success criteria** of the User Story. If a new pattern was approved in Step 2, include consistency tasks.

### Directives

* **TDD First:** Every task must specify a concrete failing test to write first.
* **Stability:** Each task must leave the codebase in a deployable, green state.
* **Acceptance Criteria:** Every task must include acceptance criteria set via the
  `--acceptance` flag, composed from the template library (`.claude/docs/ACCEPTANCE-CRITERIA-LIBRARY.md`).
  Read the library once at the start of Step 3. For each task:
  1. Start with Universal Criteria (always included)
  2. Select applicable category blocks based on task type
  3. Fill in parameterized slots ({path}, {ClassName}, {N}, etc.)
  4. Add task-specific criteria not covered by templates
  5. Every criterion must include a `Verify:` command that returns exit 0 on pass
* **Sequential Order:**
    1. **Data Model Updates:** Backward compatible (nullable fields, defaults).
    2. **API/Service Updates:** Backward compatible (API versioning or optional parameters).
    3. **UI/Frontend Updates:** Consume the new API/version.
    4. **Cleanup:** Remove legacy fields, deprecated API versions, or bridge code.

### E2E Testing Requirement

If the story introduces or modifies user-facing behavior, API endpoints, or cross-component flows, include a dedicated E2E test task:

- **New user flows**: E2E test(s) covering happy path and key error states
- **Modified flows**: Update existing E2E tests; add new tests for new paths
- **API-only changes**: E2E tests if the change affects responses consumed by frontend or external clients
- Place in `tests/e2e/` following existing conventions
- E2E task depends on all implementation tasks (runs last)

If purely internal (no behavior change), document why E2E coverage is not needed.

### Documentation Updates

If the story introduces or modifies patterns, conventions, or significant technical decisions, include a documentation task:

- **New pattern** approved in Step 2 → Create or update ADR in `docs/adr/`
- **Modified pattern** → Update the relevant ADR with rationale
- **New conventions** → Update Standardization Guide or relevant docs
- **New integration/dependency** → Document in architecture docs
- **Config changes** → Update environment or deployment docs

The doc task should depend on implementation tasks and reference Step 2 feedback if applicable.

If no documentation updates needed, note the rationale (e.g., "No new patterns; existing ADRs remain accurate").

---

## Step 4: Implementation Plan Review (/implementation-plan)

Read [docs/review-criteria.md](docs/review-criteria.md) for the full reviewer
table, launch instructions, score aggregation rules, and conflict detection guidance.

Invoke `/review-protocol` to evaluate the plan:

- **subject**: "Implementation Plan for: {story title}"
- **artifact**: The user story (title + full description) plus the numbered task list with titles, descriptions, TDD requirements, and dependencies
- **pass_threshold**: 5 (this plan must be safe for unsupervised agent execution)
- **start_stage**: 1
- **perspectives**: Read from reviewer files in `docs/reviewers/plan/`:
  - [docs/reviewers/plan/task-design.md](docs/reviewers/plan/task-design.md) — perspective: `"Task Design"`
  - [docs/reviewers/plan/safety.md](docs/reviewers/plan/safety.md) — perspective: `"Safety"`
  - [docs/reviewers/plan/dependencies.md](docs/reviewers/plan/dependencies.md) — perspective: `"Dependencies"`
  - [docs/reviewers/plan/completeness.md](docs/reviewers/plan/completeness.md) — perspective: `"Completeness"`

### Optimization

The plan **must** achieve all dimension scores of **5**. `/review-protocol`'s revision protocol handles the iteration loop (max 3 cycles). After 3 attempts, present the plan at its current score with remaining issues to the user for judgment.

---

## Step 5: Task Creation (/implementation-plan)

Once the plan is approved (Score: 5 or user-approved), create tasks in the ticket system.

### Create Tasks

For each task in the plan:

```bash
# Full creation with description and parent in one command:
tk create "{task title}" -t task -p {priority} --parent=<story-id> -d "{description with TDD requirement and acceptance criteria}"

# Full creation with parent and description in one command:
TASK_ID=$(tk create "{task title}" -t task -p {priority} --parent=<story-id> -d "{detailed description}")
```

**Prefer `tk create`** with all flags in one command. For multi-line descriptions, use heredoc syntax with `-d`.

If `tk create` fails, retry once. If still failing, report the error.

### Task Content Requirements

Each task must include:

| Field | Content |
|-------|---------|
| **Title** | Concise and atomic |
| **Description** | Implementation steps, file paths, constraints |
| **TDD Requirement** | Specific failing test to write first |
| **Acceptance Criteria** | Set via `--acceptance` flag (see format below) |

**Acceptance criteria format** (set via `tk create --acceptance="..."` at creation time, or edit `.tickets/<id>.md` directly to add/update):

```bash
# At creation time:
tk create "{title}" -t task --acceptance="- [ ] \`make test-unit-only\` passes (exit 0)
  Verify: cd \$(git rev-parse --show-toplevel)/app && make test-unit-only
- [ ] \`make lint\` passes (exit 0)
  Verify: cd \$(git rev-parse --show-toplevel)/app && make lint
- [ ] \`make format-check\` passes (exit 0)
  Verify: cd \$(git rev-parse --show-toplevel)/app && make format-check
- [ ] {task-specific criterion 1}
  Verify: {command that returns exit 0 on pass}
- [ ] {task-specific criterion 2}
  Verify: {command}"
```

Universal criteria (test, lint, format) are always the first three lines.
Task-specific criteria follow, drawn from the template library and customized.
The `ACCEPTANCE CRITERIA` section appears as a separate section in `tk show` output.

### Add Dependencies

```bash
tk dep <downstream-task> <upstream-task>
```

Follow the sequential order from Step 3:
1. Data model tasks first (no blockers)
2. API/service tasks depend on data model tasks
3. UI tasks depend on API/service tasks
4. E2E test task depends on all implementation tasks
5. Documentation task depends on implementation tasks it documents
6. Cleanup tasks depend on all implementation + E2E tasks

### Validate Ticket Health

```bash
$(git rev-parse --show-toplevel)/scripts/validate-issues.sh
```

If validation fails, fix dependency issues before presenting the summary.

### Present Summary

Run `tk ready` (filtered by story) to confirm which tasks are immediately workable.

Output a summary table:

| ID | Title | Priority | Depends On | TDD Test |
|----|-------|----------|------------|----------|
| xxx-001 | Add nullable field... | P1 | - | test_field_exists_and_nullable |
| xxx-002 | Implement service... | P1 | xxx-001 | test_service_returns_expected |

Output a **File Impact Summary** — a consolidated list of every file touched across all tasks:

| File | Action | Task(s) |
|------|--------|---------|
| `src/models/user.py` | Edit | xxx-001 |
| `src/services/auth.py` | Create | xxx-002 |
| `tests/unit/test_auth.py` | Create | xxx-002 |
| `src/routes/legacy_login.py` | Remove | xxx-004 |

Actions: **Create**, **Edit**, or **Remove**. If multiple tasks touch the same file, list all task IDs — this signals overlap for `/batch-overlap-check`.

Report:
- Total tasks created
- File impact summary (above)
- Dependency graph (`tk dep tree <story-id>`)
- Ready tasks (`tk ready` filtered by story)
- Whether documentation/E2E tasks were included and why

**Stop and wait for user instructions** — do not begin implementing any tasks.

---

## Quick Reference

| Step | Purpose | Key Commands |
|------|---------|--------------|
| 1 | Contextual Discovery | `tk show`, `tk dep tree`, Glob/Grep, clarify ambiguities, cross-cutting detection |
| 2 | Architectural Review | `/review-protocol` (>= 4, max 3 iterations); forced if cross-cutting detected |
| 3 | Atomic Task Drafting | TDD-first, sequential order, E2E + docs coverage |
| 4 | Plan Review | `/review-protocol` (all dims = 5, max 3 iterations) |
| 5 | Task Creation | `tk create`, `tk dep`, `validate-issues.sh`, `tk ready` |

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Planning on assumptions | Run the ambiguity scan; ask before drafting |
| Tasks too large (multi-concern) | Split until each task has one testable outcome |
| Missing backward compatibility | Add migration/bridge step before breaking changes |
| E2E tests forgotten | Always evaluate; document rationale if skipped |
| No ADR for new patterns | Step 2 approval = ADR needed. Include doc task. |
| Implicit dependencies | Make all task ordering explicit via `tk dep` |
| Skipping plan review | Always run Step 4 — unreviewed plans miss edge cases |
| Infinite refinement loops | Max 3 iterations, then escalate to user |
| Skipping cross-cutting detection | Count layers and interfaces before deciding to skip Step 2 — a "simple" change touching route → service → agent → provider is already cross-cutting |
| Cross-cutting but no pattern change | Cross-cutting threshold overrides the new-pattern check — Step 2 is still required |
