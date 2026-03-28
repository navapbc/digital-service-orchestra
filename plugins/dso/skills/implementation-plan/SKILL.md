---
name: implementation-plan
description: Use when a user story or simple epic needs to be broken into atomic, TDD-driven implementation tasks with architectural review, or when planning how to implement a specific ticket item
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:implementation-plan cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Implementation Plan: Atomic Task Generation

Generate a production-safe implementation plan for a User Story by decomposing it into atomic, TDD-driven tasks with correct dependencies. Prioritize understanding over assumptions — resolve ambiguity before planning.


## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — replaces `make test-unit-only` in acceptance criteria templates generated during Step 3 (Task Drafting)
- `LINT_CMD` — replaces `make lint` in acceptance criteria templates
- `FORMAT_CHECK_CMD` — replaces `make format-check` in acceptance criteria templates

**Supports dryrun mode.** Use `/dso:dryrun /dso:implementation-plan` to preview without changes.

## Usage

```
/dso:implementation-plan                  # Interactive story selection
/dso:implementation-plan <story-id>       # Plan specific user story
/dso:implementation-plan <epic-id>        # Plan simple epic directly (when routed by /dso:sprint)
```

## Arguments

- `<story-id>` or `<epic-id>` (optional): The ticket item to decompose. Accepts stories (creates tasks under the story) or epics (creates tasks directly under the epic). If omitted, presents an interactive list of open stories.

## Progress Checklist

> **Task tracking rule**: Only create `TaskCreate` items from this checklist when `/dso:implementation-plan` is invoked **standalone** (directly by the user). When invoked from `/dso:sprint`, do NOT call `TaskCreate` — `/dso:sprint` owns the task list and calling it here will add noise to the active sprint task list. Track progress through inline notes instead.

Copy and track as you work (standalone only):

```
Progress:
- [ ] Step 1: Contextual Discovery (story loaded, context gathered, ambiguities resolved, cross-cutting detection done — layers: _, interfaces: _)
- [ ] Step 2: Architectural Review via REVIEW-PROTOCOL-WORKFLOW.md inline (passed / skipped — no new pattern)
- [ ] Step 3: Task Drafting (tasks drafted with E2E + docs coverage)
- [ ] Step 4: Plan Review via REVIEW-PROTOCOL-WORKFLOW.md inline (all dimensions: 5, iteration: _/3)
- [ ] Step 5: Task Creation (tasks created, deps added, health validated)
- [ ] Step 6: Gap Analysis (COMPLEX: opus sub-agent dispatched, findings processed; TRIVIAL: skipped)
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
  → S5 complete → [evaluator says TRIVIAL?]
    → Yes: Skip S6, present summary
    → No: S6 (Gap Analysis) → parse findings → create tasks / amend ACs → present summary
      → [S6 fails/times out] Log warning → present summary (non-blocking)
```

---

## Step 1: Contextual Discovery (/dso:implementation-plan)

### Select Story

If `<story-id>` was not provided:
1. Run `.claude/scripts/dso ticket list` to show open, unblocked stories
2. If none, fall back to `.claude/scripts/dso ticket list` to understand state
3. If no open stories exist, report and exit
4. Present stories to the user and get selection

Load the story:
```bash
.claude/scripts/dso ticket show <story-id>
```

If the story is not found, report the error and exit.

### Epic Type Detection

After loading the item with `.claude/scripts/dso ticket show`, check the `type` field in the output:

- **If `type` is `epic`**: Enter **epic-direct mode**:
  - The epic's done definitions serve as acceptance criteria source (same role as story done definitions)
  - Skip "load parent epic for context" in Input Analysis (the epic IS the context)
  - Tasks will be created as direct children of the epic (not children of a story)
  - Skip the Context File Check below (context files are keyed by parent epic, but there is no parent)
  - Proceed directly to **Architectural Alignment**
  - In Step 5 (Task Creation), use `--parent=<epic-id>` (if supported) instead of `--parent=<story-id>`

- **If `type` is not `epic`** (task, story, etc.): Continue with the existing flow below (Context File Check → Input Analysis → etc.)

### Context File Check

After loading the story with `.claude/scripts/dso ticket show <story-id>`, check for a preplanning context file:

1. Extract the parent epic ID from the story's `parent` field
2. Check for `/tmp/preplanning-context-<parent-epic-id>.json`
3. If found AND `generatedAt` is within the last 24 hours:
   - Load epic data from the context file (skip `.claude/scripts/dso ticket show <parent-epic-id>`)
   - Load sibling stories from the context file (skip `.claude/scripts/dso ticket deps` + per-sibling `.claude/scripts/dso ticket show`)
   - Carry forward: review findings, walking skeleton flags, classifications, traceability lines, story dashboard
   - Log: `"Context loaded from preplanning — skipping redundant epic/sibling fetch"`
   - **Skip the Input Analysis section below** and proceed directly to Architectural Alignment
4. If not found OR stale (>24 hours):
   - Proceed with normal Input Analysis below (no change to current behavior)

### Input Analysis

Load the story and its parent epic for full context:

```bash
.claude/scripts/dso ticket show <story-id>
# Extract parent ID from the 'parent' field, then:
.claude/scripts/dso ticket show <parent-epic-id>
# Review sibling stories for context:
.claude/scripts/dso ticket deps <parent-epic-id>
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

If complexity-evaluator output was provided (when invoked from `/dso:sprint`):

1. **Reuse evaluator findings** — use `layers_touched` count and `interfaces_affected` count directly
2. **Sanity-check** — verify the evaluator's layer/interface counts against the story context gathered in Architectural Alignment. If the counts seem wrong (e.g., evaluator missed a layer), note the discrepancy and proceed with corrected counts
3. **Apply escalation rule** below using the verified counts
4. **Skip** the full "How to detect cross-cutting changes" analysis (tracing data/control flow, grepping for interfaces)

If no evaluator output (standalone `/dso:implementation-plan` invocation):
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

## Step 2: Consistency & Architectural Review (/dso:implementation-plan)

Determine if the implementation requires a new architectural pattern or a modification to an existing one. If not, skip to Step 3.

### Architectural Review via Review Protocol Workflow

If a pattern change is proposed, read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md` inline with:

- **subject**: "Architectural Pattern: {pattern name}"
- **artifact**: The proposed pattern description plus relevant architecture docs and existing patterns found in Step 1
- **pass_threshold**: 4
- **start_stage**: 1
- **perspectives**: Read from reviewer files in `docs/reviewers/architectural/`:
  - [docs/reviewers/architectural/best-practices.md](docs/reviewers/architectural/best-practices.md) — perspective: `"Best Practices"`
  - [docs/reviewers/architectural/project-alignment.md](docs/reviewers/architectural/project-alignment.md) — perspective: `"Project Alignment"`
  - [docs/reviewers/architectural/justification.md](docs/reviewers/architectural/justification.md) — perspective: `"Justification"`

### Fallback

If the review fails after autonomous resolution (`review.max_resolution_attempts` fix/defend attempts, default: 5) and user escalation, revert to existing patterns and note the unresolved concern for the user. If no existing pattern solves the story, halt and consult the user.

---

## Step 3: Atomic Task Drafting (/dso:implementation-plan)

Draft tasks that **collectively fulfill all success criteria** of the User Story. If a new pattern was approved in Step 2, include consistency tasks.

### Directives

* **TDD First:** Every task must specify a concrete failing test to write first.
* **Stability:** Each task must leave the codebase in a deployable, green state.
  Tasks must never require being committed together — each task is an independent
  atomic unit that can be committed, pushed, and deployed on its own. If a task
  would leave the codebase broken without another task also being committed, the
  tasks must be restructured (merged or reordered) until each is independently green.
  A task that deploys an inert feature (e.g., a guard that reads files no one writes yet)
  is acceptable — inert is not broken. The key test: after committing only this task,
  do all tests pass and is the system deployable?
* **Acceptance Criteria:** Every task must include acceptance criteria passed via `-d/--description`
  at creation time, composed from the template library
  (`${CLAUDE_PLUGIN_ROOT}/docs/ACCEPTANCE-CRITERIA-LIBRARY.md`).
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

### File Impact Enumeration

Before drafting tasks, enumerate all files affected by the story. This produces an auditable **file impact table** that maps each source file to its change action, associated tests, and test classification. The table drives task type selection in TDD Task Structure below.

#### Step-by-step

1. **List affected source files** — Use Glob and Grep to identify every file the story touches. Start from the story's entry points and trace through all layers.

2. **Find associated tests for each source file** — For each source file, locate its test counterpart using one of two methods:
   - **Fuzzy match** (preferred): source the fuzzy-match library and call `fuzzy_find_associated_tests`:
     ```bash
     source plugins/dso/hooks/lib/fuzzy-match.sh
     fuzzy_find_associated_tests <src_file> <repo_root>
     ```
   - **`.test-index` lookup**: check whether the source file has an explicit entry in `.test-index` at the repo root (format: `source/path.ext: test/path1.ext, test/path2.ext`).
   - Combine both — results from `fuzzy_find_associated_tests` and `.test-index` are unioned.

3. **Classify each test** based on what the story does to the source file:

   | Source change action | Test classification |
   |---------------------|---------------------|
   | `create` (new source file) | `needs-creation` — write a new test file |
   | `modify` (behavior change) | `needs-modification` — update existing test(s) to assert new behavior |
   | `remove` (source deleted) | `needs-removal` — remove or prune tests that verify the deleted behavior |
   | `modify` (no behavior change, e.g., refactor) | `still-valid` — existing tests remain correct without changes |

4. **Build the file impact table**:

   | Source file | Action | Associated tests | Test classification |
   |-------------|--------|-----------------|---------------------|
   | `src/foo.py` | modify | `tests/test_foo.py` | needs-modification |
   | `src/bar.py` | create | *(none yet)* | needs-creation |
   | `src/legacy.py` | remove | `tests/test_legacy.py` | needs-removal |
   | `src/util.py` | modify | `tests/test_util.py` | still-valid |

Use this table to determine which TDD task types to create (see TDD Task Structure below). Files classified `still-valid` require no test task. Files classified `needs-modification` require a **modify-existing-test** RED task. Files classified `needs-removal` require a **remove-test** task. Files classified `needs-creation` require a **create-test** RED task (the existing flow).

### TDD Task Structure

**Behavioral content** is defined as code that contains conditional logic, data transformation, or decision points — any code where the output varies based on inputs or state. Every task whose implementation adds or modifies behavioral content must have a preceding **RED test task** as a declared dependency before any implementation task.

**A RED test may be modifying existing tests, not only creating new test files.** When a story changes existing behavior, the RED test edits an existing test file to assert the new expected behavior — it does not necessarily create a new test file. Tests are behavioral specifications — when behavior changes, the specification must be updated. Modifying existing tests is a first-class RED-phase activity, not a special case.

#### TDD task types

Use the file impact table from File Impact Enumeration to select the correct task type for each source file:

**1. Create-test task** (source action: `create`, classification: `needs-creation`)
- Write a new test file asserting the expected behavior of the new source file
- Standard RED-first flow; implementation task depends on this create-test task

**2. Modify-existing-test task** (source action: `modify`, classification: `needs-modification`)
- Update an existing test to assert the new expected behavior after the source change
- This is a RED test task: the modified test must fail (RED) before the implementation runs
- The task must name the specific existing test file to modify and describe which assertions change
- Implementation task depends on this modify-existing-test task

**3. Remove-test task** (source action: `remove`, classification: `needs-removal`)
- Remove test cases or entire test files that verify behavior being deleted from the source
- Removing tests for deleted behavior keeps the test suite honest and prevents dead-code assertions
- This task may run before or in parallel with the source removal task (no behavioral assertion to run RED)
- If only some cases within a test file need removal, describe the specific cases to delete

A RED test task:
- Writes a failing test that asserts the expected behavior
- Must fail (RED) before the implementation task runs
- Is a standalone task in the plan, not embedded in the implementation task description
- Uses `TEST_CMD` (resolved from `commands.test` in workflow-config) as the verify command
- **Must be a behavioral test** — see Behavioral Test Requirement below

#### Behavioral Test Requirement

RED tests must verify **behavior** (what the code does), not **presence** (that specific code text exists in a source file). A test that greps a source file for a function name, string pattern, or implementation detail is a **change-detector test** — it passes when the code is written and fails when it's deleted, regardless of whether the code actually works.

**A valid RED test must do at least one of:**
- Execute the code under test and assert on its output, exit code, or side effects
- Create test fixtures (files, repos, mock services) and verify the code handles them correctly
- Import a module/function and call it with inputs, asserting the return value

**Structural tests are acceptable ONLY for these categories:**
- **Negative constraints** ("must NOT contain X") — e.g., no hardcoded paths after a migration, no relative paths in hook libs. These protect against regression to a known-bad state.
- **Metadata/schema validation** — e.g., skill frontmatter has required fields, config file has required keys. These verify structure that has no executable behavior.
- **Syntax checks** — `bash -n`, `python -m py_compile`, JSON schema validation. These verify the code is parseable.
- **File existence/permissions** — `test -f`, `test -x`. These verify deployment prerequisites.

**Structural tests are NOT acceptable for:**
- Asserting that a function name appears in a source file (use: call the function)
- Asserting that a string appears near another string via `sed -n` range extraction (use: create the scenario and verify the behavior)
- Counting `grep -c` matches as a proxy for "feature is implemented" (use: exercise the feature)
- Verifying a script handles edge cases by grepping for the edge case code (use: create the edge case input and verify the output)

When the TDD task description specifies the RED test, it must include a **test approach** sentence explaining what the test executes and what output/behavior it asserts. If the test approach describes grepping a source file, the task must be revised to describe a behavioral assertion instead.

#### Unit Test Exemption Criteria

A task may omit the RED test task dependency (unit test level) only if **all** of the following apply:

1. The code has **no conditional logic** — it is purely structural (e.g., a class definition with no branching)
2. Any test written for it would be a **change-detector test** — a test that only asserts the code exists, not that it behaves correctly
3. The task is **infrastructure-boundary-only** — it touches only configuration wiring, dependency injection setup, or module registration with no business logic

All three criteria must be documented as a **justification requirement** in the task description, and the plan reviewer must validate the exemption during Step 4 review.

#### Integration Test Task Rule

For tasks that cross an external boundary (database, external API, message queue, file system), include a dedicated **integration test task** that verifies the boundary interaction end-to-end. The integration test task does not require a RED-first dependency — it may be written after the implementation task.

An integration test task may be omitted only if one of the following applies:

1. **existing coverage** — an existing integration test already exercises this boundary in a way that would fail if the task's behavior were broken
2. **no test environment** — the external boundary is unavailable in CI and no suitable mock or contract test is feasible

Either exemption requires a justification requirement documented in the task description and validated by the plan reviewer in Step 4.

### Test Filename Conventions (Fuzzy-Match Compatibility)

The tech-stack-agnostic test gate associates source files with their tests using **fuzzy matching**: the source file's basename is normalized (all non-alphanumeric characters stripped, lowercased) and then checked as a substring against normalized test file basenames.

**Examples of compatible test filenames** (auto-detected by fuzzy match):

| Source file | Compatible test filenames |
|-------------|--------------------------|
| `bump_version.py` | `test_bump_version.py`, `test_bumpversion.py` |
| `bump-version.sh` | `test-bump-version.sh`, `test_bumpversion_unit.sh` |
| `auth_service.py` | `test_auth_service.py`, `auth_service_test.go` |
| `parser.ts` | `parser.test.ts`, `parser.spec.ts` |

**Rule**: When proposing a test filename in a task, verify it would be caught by the fuzzy match algorithm:
1. Normalize the source basename: strip all non-`[a-z0-9]` characters, lowercase everything (e.g., `bump-version.sh` → `bumpversionsh`)
2. Normalize the proposed test basename the same way (e.g., `test-bump-version.sh` → `testbumpversionsh`)
3. Confirm the normalized source string appears as a **substring** of the normalized test string

**If the proposed test filename would NOT be caught by fuzzy match** (e.g., the test is named after a behavior or feature rather than the source file — e.g., `test_retry_logic.py` for `connection_handler.py`), the task's acceptance criteria **must include a `.test-index` entry** as an explicit criterion:

```
- [ ] `.test-index` entry added mapping `<source-file>` to `<test-file>`
  Verify: grep -q '<source-file>' $(git rev-parse --show-toplevel)/.test-index
```

Add this `.test-index` entry requirement as an acceptance criterion and note in the task description that the test name does not follow fuzzy-matchable conventions. The `.test-index` file is the authorized fallback for unconventional test names and must be present before commit or the test gate will produce a false negative.

**Common Mistake**: Naming a test after what it tests (behavior) rather than what file it tests (source). Always check that the source filename's normalized form is a substring of the normalized test filename.

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
- **Style guide**: Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting, structure, and conventions when writing any documentation updates

The doc task should depend on implementation tasks and reference Step 2 feedback if applicable.

If no documentation updates needed, note the rationale (e.g., "No new patterns; existing ADRs remain accurate").

### Contract Detection Pass

After file impact analysis in Step 3 and before finalizing the task list, run a contract detection pass to identify cross-component interfaces that need explicit contracts.

#### When to Run

Run this pass when file impact includes two or more components. Skip only for purely internal, single-component changes.

#### V1 Detection Heuristics

Check for two signal patterns in the file impact list:

**Pattern A — Signal emit/parse pairs:**
A contract is needed when file impact includes a component that produces structured output (lines containing `STATUS:`, `RESULT:`, or `REPORT:` markers that another component must parse) AND another component that parse/consume that signal. Look for: one file that will emit a signal, and another that will parse that signal or parse signal output.

**Pattern B — Orchestrator/sub-agent report schema:**
A contract is needed when file impact includes a skill or orchestrator dispatching sub-agents AND a definition of the expected return format (CONTRACT_REPORT or contract report schema). When a dispatcher and a report schema are both in scope, the interface between them requires a contract artifact.

#### Contract Artifact

For each detected interface, create a contract document:

```
plugins/dso/docs/contracts/<interface-name>.md
```

Contract document sections:
- **Signal Name**: Identifier for the interface (e.g., `CONTRACT_REPORT`)
- **Emitter**: Component/file that produces the output
- **Parser**: Component/file that consumes the output
- **Fields**: Structured field list with types and required/optional status
- **Example**: Representative payload or output block

#### Cross-Story Deduplication

Before creating a contract task, check for an existing contract task in the epic:

```bash
.claude/scripts/dso ticket deps <parent-epic-id>
```

Scan the output for any existing task whose title contains `Contract:` and the same interface name. If an existing contract task is found, wire the implementation tasks as dependents of that existing contract task — do not create a duplicate. If no existing contract task is found, create one:

```bash
.claude/scripts/dso ticket create task "Contract: <interface-name> signal emit/parse interface" --parent=<parent-epic-id> --priority=2
```

#### Contract Task as First Dependency

The contract task must be declared as a dependency of all implementation tasks that touch either side of the interface — both the emitter side and the parser side. This ensures the interface is specified before either side is implemented.

---

## Step 4: Implementation Plan Review (/dso:implementation-plan)

Read [docs/review-criteria.md](docs/review-criteria.md) for the full reviewer
table, launch instructions, score aggregation rules, and conflict detection guidance.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md` inline to evaluate the plan:

- **subject**: "Implementation Plan for: {story title}"
- **artifact**: The user story (title + full description) plus the numbered task list with titles, descriptions, TDD requirements, and dependencies
- **pass_threshold**: 5 (this plan must be safe for unsupervised agent execution)
- **start_stage**: 1
- **perspectives**: Read from reviewer files in `docs/reviewers/plan/`:
  - [docs/reviewers/plan/task-design.md](docs/reviewers/plan/task-design.md) — perspective: `"Task Design"`
  - [docs/reviewers/plan/tdd.md](docs/reviewers/plan/tdd.md) — perspective: `"TDD"`
  - [docs/reviewers/plan/safety.md](docs/reviewers/plan/safety.md) — perspective: `"Safety"`
  - [docs/reviewers/plan/dependencies.md](docs/reviewers/plan/dependencies.md) — perspective: `"Dependencies"`
  - [docs/reviewers/plan/completeness.md](docs/reviewers/plan/completeness.md) — perspective: `"Completeness"`

### Optimization

The plan **must** achieve all dimension scores of **5**. The review protocol workflow's revision protocol handles the iteration loop (max 3 cycles). After 3 attempts, present the plan at its current score with remaining issues to the user for judgment.

---

## Step 5: Task Creation (/dso:implementation-plan)

Once the plan is approved (Score: 5 or user-approved), create tasks in the ticket system.

### Create Tasks

For each task in the plan:

```bash
# Create a task with parent and priority:
TASK_ID=$(.claude/scripts/dso ticket create task "{task title}" --parent=<story-id> --priority={priority})
```

If `.claude/scripts/dso ticket create` fails, retry once. If still failing, report the error.

### Task Content Requirements

Each task must include:

| Field | Content |
|-------|---------|
| **Title** | Concise and atomic |
| **Description** | Implementation steps, file paths, constraints |
| **TDD Requirement** | Specific failing test to write first |
| **Acceptance Criteria** | Included via `-d/--description` at creation time (see format below) |

**Acceptance criteria format** (pass via `-d` at creation time):

```bash
# Create the task with acceptance criteria included in description
TASK_ID=$(.claude/scripts/dso ticket create task "{title}" --parent=<story-id> --priority=2 -d "$(cat <<'DESCRIPTION'
## Acceptance Criteria
- [ ] `make test-unit-only` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make test-unit-only
- [ ] `make lint` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make lint
- [ ] `make format-check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel)/app && make format-check
- [ ] {task-specific criterion 1}
  Verify: {command that returns exit 0 on pass}
- [ ] {task-specific criterion 2}
  Verify: {command}
DESCRIPTION
)")
```

Universal criteria (test, lint, format) are always the first three lines.
Task-specific criteria follow, drawn from the template library and customized.

### Add Dependencies

```bash
.claude/scripts/dso ticket link <downstream-task> <upstream-task> depends_on
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
.claude/scripts/dso validate-issues.sh
```

If validation fails, fix dependency issues before presenting the summary.

### Present Summary

Run `.claude/scripts/dso ticket list` (filtered by story) to confirm which tasks are immediately workable.

Output the parent epic/story ID prominently at the top of the summary so it can be referenced in follow-up commands:

```
Implementation plan for [epic/story ID]: [Title]
```

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

Actions: **Create**, **Edit**, or **Remove**. If multiple tasks touch the same file, list all task IDs — this signals overlap for `/dso:batch-overlap-check`.

Report:
- Total tasks created
- File impact summary (above)
- Dependency graph (`.claude/scripts/dso ticket deps <story-id>`)
- Ready tasks (`.claude/scripts/dso ticket list` filtered by story)
- Whether documentation/E2E tasks were included and why

**When invoked interactively (user-initiated)**: Stop and wait for user instructions — do not begin implementing any tasks.

**When invoked from `/dso:sprint` (via Skill tool)**: Do NOT stop. Continue immediately to Step 6 (Gap Analysis) and then output the STATUS protocol (see Output Protocol below).

---

## Step 6: Gap Analysis (/dso:implementation-plan)

Review the complete task list for design gaps that would compound during sub-agent execution. This step dispatches an opus sub-agent to analyze the plan against a structured gap taxonomy.

### TRIVIAL Skip Gate

Check the story's complexity classification. When invoked from `/dso:sprint`, the parent story may have a `COMPLEXITY_CLASSIFICATION: COMPLEX` comment (written by sprint's evaluator). Check via `.claude/scripts/dso ticket show <story-id>` and grep for `COMPLEXITY_CLASSIFICATION`:

- **If `COMPLEXITY_CLASSIFICATION: TRIVIAL`** (or the story is clearly simple from context): Skip gap analysis entirely. Log: `"Skipping gap analysis — story classified as TRIVIAL"`. Proceed directly to the final summary presentation.
- **If `COMPLEXITY_CLASSIFICATION: COMPLEX`** or **no classification found** (standalone invocation): Run gap analysis. The cost of an unnecessary gap analysis is low; the cost of a missed gap is high.

### Dispatch Opus Sub-Agent

For COMPLEX stories (or standalone invocations), dispatch an opus sub-agent via the Task tool using the prompt template at `prompts/gap-analysis.md`.

Fill the template placeholders with:

| Placeholder | Source |
|-------------|--------|
| `{story-title}` | Story title from `.claude/scripts/dso ticket show` |
| `{story-description}` | Story description from `.claude/scripts/dso ticket show` |
| `{task-list-with-descriptions}` | Full task list: titles, descriptions, TDD requirements, acceptance criteria |
| `{dependency-graph}` | Output from `.claude/scripts/dso ticket deps <story-id>` |
| `{file-impact-summary}` | File Impact Summary table from Step 5 |

### Parse Findings

Parse the JSON `findings` array from the sub-agent response. For each finding:

- **If `type: "new_task"`**: Create a new task via `.claude/scripts/dso ticket create` with the finding's title and description, parent set to the story, add dependency on the appropriate existing task(s), and add to the summary table.
- **If `type: "ac_amendment"`**: Use `.claude/scripts/dso ticket comment <target_task_id> "AC amendment: <description>"` to append the finding's description as an additional acceptance criterion.

### Fallback Behavior

If the sub-agent times out, returns malformed JSON, or fails for any reason:

1. Log a warning: `"Gap analysis sub-agent failed: <error> — continuing without gap findings"`
2. Do NOT block the implementation plan
3. Proceed to the summary presentation with a note that gap analysis was not completed

### Summary Update

After processing findings (or skipping/failing), update the summary output to include a **Gap Analysis Results** section:

| Outcome | Summary Line |
|---------|-------------|
| TRIVIAL skip | `Gap Analysis: Skipped (TRIVIAL classification)` |
| No gaps found | `Gap Analysis: Complete — no gaps found` |
| Gaps found | `Gap Analysis: {N} findings — {X} new tasks created, {Y} AC amendments` |
| Sub-agent failed | `Gap Analysis: Failed (non-blocking) — <error summary>` |

---

## Quick Reference

| Step | Purpose | Key Commands |
|------|---------|--------------|
| 1 | Contextual Discovery | `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket deps`, Glob/Grep, clarify ambiguities, cross-cutting detection |
| 2 | Architectural Review | `REVIEW-PROTOCOL-WORKFLOW.md` inline (>= 4, max 3 iterations); forced if cross-cutting detected |
| 3 | Atomic Task Drafting | TDD-first, sequential order, E2E + docs coverage |
| 4 | Plan Review | `REVIEW-PROTOCOL-WORKFLOW.md` inline (all dims = 5, max 3 iterations) |
| 5 | Task Creation | `.claude/scripts/dso ticket create`, `.claude/scripts/dso ticket link`, `validate-issues.sh`, `.claude/scripts/dso ticket list` |
| 6 | Gap Analysis | TRIVIAL skip gate, opus sub-agent via `prompts/gap-analysis.md`, parse findings |

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Planning on assumptions | Run the ambiguity scan; ask before drafting |
| Tasks too large (multi-concern) | Split until each task has one testable outcome |
| Missing backward compatibility | Add migration/bridge step before breaking changes |
| E2E tests forgotten | Always evaluate; document rationale if skipped |
| No ADR for new patterns | Step 2 approval = ADR needed. Include doc task. |
| Implicit dependencies | Make all task ordering explicit via `.claude/scripts/dso ticket link` |
| Skipping plan review | Always run Step 4 — unreviewed plans miss edge cases |
| Infinite refinement loops | Max 3 iterations, then escalate to user |
| Skipping cross-cutting detection | Count layers and interfaces before deciding to skip Step 2 — a "simple" change touching route → service → agent → provider is already cross-cutting |
| Cross-cutting but no pattern change | Cross-cutting threshold overrides the new-pattern check — Step 2 is still required |
| Skipping gap analysis for COMPLEX stories | Always run Step 6 for COMPLEX stories — missed gaps compound during sub-agent execution |
| Blocking on gap analysis failure | Gap analysis failure is non-blocking — log warning and continue |
| Tasks requiring co-commit | Every task must be independently committable and green. If Task B is broken without Task A in the same commit, merge them or reorder so each stands alone. Inert (does nothing yet) is fine; broken is not. |
| Test filename not fuzzy-matchable | Verify the normalized source basename is a substring of the normalized test basename. If not, require a `.test-index` entry in acceptance criteria — the test gate will produce a false negative without it. |

## Output Protocol (when invoked from /dso:sprint)

When invoked via Skill tool from `/dso:sprint`, output one of these STATUS lines as the final output so the sprint orchestrator can parse the result:

### On success (all tasks created, dependencies added, plan approved, gap analysis complete):

```
STATUS:complete TASKS:<comma-separated-task-ids> STORY:<story-or-epic-id>
```

### On ambiguity or blocker (cannot proceed without user input):

```
STATUS:blocked QUESTIONS:<json-array-of-question-objects>
```

Each question object must have two fields:
- `"text"`: the question string
- `"kind"`: either `"blocking"` (cannot plan without this) or `"defaultable"` (safe assumption exists — include the assumption in the text)

**Rules for question classification:**
- `"blocking"`: genuinely cannot draft tasks without this answer
- `"defaultable"`: safe assumption exists; include the assumption explicitly
- Never include questions clearly answerable from the codebase or parent epic
