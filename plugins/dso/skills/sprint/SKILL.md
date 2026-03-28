---
name: sprint
description: Execute Epic - Multi-Agent Orchestration
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:sprint cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Execute Epic: Multi-Agent Orchestration

Automate the full lifecycle of a ticket epic: task analysis, batched sub-agent execution, post-epic validation, and remediation loop.


## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
VALIDATE_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.validate)
VISUAL_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_visual)
E2E_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_e2e)
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — replaces `make test-unit-only` in post-batch and remediation validation
- `LINT_CMD` — replaces `make lint` in validation steps
- `VALIDATE_CMD` — replaces `scripts/validate.sh --ci` call in Phase 1
- `VISUAL_CMD` — replaces `make test-visual` in post-batch checks
- `E2E_CMD` — replaces `make test-e2e` in post-batch checks

## Usage

```
/dso:sprint                     # Interactive epic selection
/dso:sprint <epic-id>           # Execute specific epic
/dso:sprint <epic-id> --dry-run # Plan batches without executing
/dso:sprint <epic-id> --resume  # Resume interrupted epic
```

## Orchestration Flow

```
Flow: P1 (Init) → Preplanning Gate
  → [0 children/ambiguous] /dso:preplanning → P2
  → [children exist & clear] P2 (Task Analysis)
  P2 → [stories without impl tasks?] layer-stratify → parallel dispatch (≤3/layer) → STATUS:complete→tasks created | STATUS:blocked→ask user → Re-gather → P3
  P2 → [all have impl tasks] P3 (Batch Planning)
  P3 → [dry-run] Output plan & stop
  P3 → [execute] P4 (Pre-Batch) → P5 (Sub-Agent Launch) → P6 (Post-Batch)
  P6 → [context >=70%] /compact → P3 (proactive, safe — all work committed)
  P6 → [involuntary compaction detected] P9 (Graceful Shutdown)
  P6 → [more ready tasks] P3
  P6 → [all done] P7 (Validation)
  P7 → [score=5] P9 (Completion)
  P7 → [score<5] P8 (Remediation) → P3
```

---

## Phase 1: Initialization & Epic Selection (/dso:sprint)

### Create Pre-Loop Progress Checklist

Call `TaskCreate` for each of the following items before doing any other work. This shows the user what setup steps will be completed before batch execution begins:

```
[ ] Select and validate epic
[ ] Run validation gate (validate.sh --ci)
[ ] Epic complexity evaluation (SIMPLE / MODERATE / COMPLEX routing)
[ ] Preplanning gate (lightweight, full, or skip based on routing)
[ ] Gather tasks and build dependency graph
[ ] Implementation planning gate (run /dso:implementation-plan per story if needed — skipped for SIMPLE/MODERATE)
```

Mark each item `in_progress` via `TaskUpdate` when starting it and `completed` when done. Before the batch loop begins (Phase 3), complete all pre-loop tasks via `TaskUpdate(status='completed')`.

### Parse Arguments

- `<epic-id>`: The ticket epic to execute
- `--dry-run`: Output batch plan without executing any sub-agents
- `--resume`: Resume an interrupted epic (skip to Phase 3 with recovery)

### If No Epic ID Provided

1. Run the epic discovery script:
   ```bash
   .claude/scripts/dso sprint-list-epics.sh --all
   ```
   This outputs tab-separated lines in three categories:
   - `<id>\tP*\t<title>\t<child_count>[\tBLOCKING]` for in-progress epics (4 or 5 fields; `P*` replaces priority)
   - `<id>\tP<priority>\t<title>\t<child_count>[\tBLOCKING]` for unblocked open epics (4 or 5 fields)
   - `BLOCKED\t<id>\tP<priority>\t<title>\t<child_count>\t<blocker_ids>` for blocked ones (6 fields; with `--all`)

   The `<child_count>` field is the number of child tickets belonging to the epic. The optional 5th field `BLOCKING` appears on in-progress and unblocked epics that are dependencies of one or more blocked epics. The 6th field `<blocker_ids>` on blocked lines is a comma-separated list of open blocker epic IDs.

   Exit codes:
   - Exit code 1 → no open epics exist, report and exit
   - Exit code 2 → all open epics are blocked; display the BLOCKED-prefixed lines from stdout as context, then exit
2. Parse the output and print a numbered list to the user. Lines with `P*` are
   in-progress epics — number them first. Then number unblocked lines. Display
   blocked epics below as informational context, not as selectable options.
   Epics with a `BLOCKING` 5th field are blocking other epics — render them in
   **bold**. Blocked epic lines include a `<blocker_ids>` 6th field — render the
   blocker IDs after "blocked by:":
   ```
   In-progress epics:

     1. [P*] <title> (<epic-id>) — 5 children ← resumable
     2. **[P*] <title> (<epic-id>) — 3 children ← resumable, BLOCKING**

   Unblocked epics (sorted by priority):

     3. **[P0] <title> (<epic-id>) — 3 children**
     4. [P1] <title> (<epic-id>) — 7 children
     ...

   Blocked epics (not selectable):
     - [P2] <title> (<epic-id>) — 2 children — blocked by: <blocker-id-1>, <blocker-id-2>
   ```
3. Ask the user: "Enter the number or epic ID to execute:" and wait for their text input
4. Map the user's response (number or epic ID) back to the corresponding epic and proceed

### Validate Epic

1. Run `.claude/scripts/dso ticket show <epic-id>` — confirm it is type `epic` and status is `open` or `in_progress`
2. Run `.claude/scripts/dso ticket deps <epic-id>` — if 100% complete, skip to Phase 7 (validation)
3. Mark epic in-progress: `.claude/scripts/dso ticket transition <epic-id> in_progress`
4. Mark the **Select and validate epic** todo item `completed`.

### Context Efficiency Rules

**Status checks**: Use `.claude/scripts/dso issue-summary.sh <id>` or `.claude/scripts/dso ticket list` for orchestrator status checks (is it done? what's blocking?). Reserve full `.claude/scripts/dso ticket show <id>` only when sub-agents need to read their complete task context.

**Ticket-as-prompt**: Sub-agents read their own task context via `.claude/scripts/dso ticket show` instead of receiving it inline. Before dispatch, run the quality gate:
```bash
.claude/scripts/dso issue-quality-check.sh <id>
```
- **Exit 0** (quality pass): Use the ticket-as-prompt template (`task-execution.md`) — sub-agent reads its own context
- **Exit 1** (too sparse): Fall back to inline prompt — orchestrator runs `.claude/scripts/dso ticket show <id>` and includes output in the Task prompt

**Writing quality ticket**: When creating tasks for sub-agent execution, include:
- Concrete file paths (`src/`, `tests/`)
- Acceptance criteria with keywords: "must", "should", "Given/When/Then"
- A `## File Impact` or `### Files to modify` section listing source and test files
- At least 5 lines of description
This ensures `issue-quality-check.sh` passes and sub-agents can self-serve their ticket context.

**File impact enrichment**: The quality gate now also checks for a file impact section. If a ticket is missing one, run `.claude/scripts/dso enrich-file-impact.sh <id>` to auto-generate it using a haiku model call. Use `--dry-run` to preview without modifying. Gracefully degrades if `ANTHROPIC_API_KEY` is unset.

### If `--resume` Flag

1. Run `.claude/scripts/dso ticket list` and filter for in-progress tasks under `<epic-id>` for interrupted tasks
2. For each in-progress task, run `.claude/scripts/dso ticket show <id>` and parse its notes for CHECKPOINT lines
3. Apply checkpoint resume rules:
   - **CHECKPOINT 6/6 ✓** — task is fully done; fast-close: verify files exist, then `.claude/scripts/dso ticket transition <id> open closed --reason="Fixed: <summary>"`
   - **CHECKPOINT 5/6 ✓** — near-complete; fast-close: spot-check files and close without re-execution
   - **CHECKPOINT 3/6 ✓ or 4/6 ✓** — partial progress; re-dispatch with resume context: include the highest checkpoint note in the sub-agent prompt so it can continue from that substep
   - **CHECKPOINT 1/6 ✓ or 2/6 ✓** — early progress only; revert to open with `.claude/scripts/dso ticket transition <id> open` for full re-execution
   - **No CHECKPOINT lines or malformed CHECKPOINT lines** — revert to open: `.claude/scripts/dso ticket transition <id> open`
4. Fallback rule: if CHECKPOINT lines are present but ambiguous (missing ✓, duplicate numbers, non-sequential), treat as malformed → revert to open
5. Proceed to Phase 3

### Run Validation Gate

Before running `validate.sh --ci`, check if a validation state file already exists for this worktree session. If it does, reuse it rather than re-running validation.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREE_NAME=$(basename "$REPO_ROOT")
STATE_FILE="/tmp/lockpick-test-artifacts-${WORKTREE_NAME}/status"

if [ -f "$STATE_FILE" ]; then
  echo "Validation state file found at $STATE_FILE — reusing existing result."
  cat "$STATE_FILE"
else
  .claude/scripts/dso validate.sh --ci
fi
```

This avoids redundant re-runs when the validation was already executed earlier in the same session (e.g., manually before invoking `/dso:sprint`, or during a previous phase).

**Bash timeout**: Use `timeout: 600000` (10 minutes — the TaskOutput hard cap). The smart CI wait in validate.sh can poll for up to 15 minutes, but the TaskOutput tool caps at 600000ms; use `|| true` and check the state file for CI results if the call times out.

**If validation fails**:
- **Single bug/test failure**: Invoke `/dso:fix-bug` with the failing test output — it classifies the bug, selects the appropriate investigation path, and fixes it with TDD discipline.
- **Multiple failures or unclear root cause**: Dispatch an `error-debugging:error-detective` sub-agent (model: `sonnet`) with the validation output to diagnose and fix the specific failing categories. Do NOT invoke `/dso:debug-everything` — it is a separate workflow that resolves all project bugs, not just sprint-scoped failures.
- Do NOT proceed to the Preplanning Gate until validation passes.

### Preplanning Gate

After the epic is validated and counters are initialized, check whether the epic is ready for execution or needs decomposition first.

#### Step 1: Check for Existing Children (/dso:sprint)

```bash
.claude/scripts/dso ticket deps <epic-id>
```

Count the number of child tasks returned.

- **If children exist**: proceed to Step 2a (Existing Children Readiness Check)
- **If zero children**: proceed to Step 2b (Epic Complexity Evaluation)

#### Step 2a: Existing Children Readiness Check (/dso:sprint)

This is the existing readiness check — unchanged. It applies only when the epic already has children.

**Trigger `/dso:preplanning` (full mode) if ANY of the following are true:**

| Condition | How to Detect |
|-----------|--------------|
| **Ambiguous tasks** | Any child task description lacks concrete success criteria (no Gherkin-style `Given/When/Then`, no bullet-list acceptance criteria, and no specific file paths or measurable outcomes) |
| **Vague epic description** | Epic description is fewer than 3 sentences AND has no success criteria section |
| **All children are epics/features** | Children are high-level containers, not implementable tasks |

**Ambiguity heuristic**: A task is considered ambiguous if its description:
- Contains no testable acceptance criteria (no `Given/When/Then`, no "should", no "must", no bullet list of outcomes)
- AND references no specific files, functions, or endpoints
- AND is shorter than 2 sentences

If **more than half** of the children are ambiguous, trigger preplanning for the entire epic.

If any trigger condition is met:
1. Log: `"Epic has ambiguous tasks — running /dso:preplanning to decompose before execution."`
2. Invoke `/dso:preplanning <epic-id>` (full mode)
3. After preplanning completes, continue to Phase 2

If no trigger condition is met, proceed directly to Phase 2.

#### Step 2b: Epic Complexity Evaluation (/dso:sprint)

When the epic has zero children, dispatch `subagent_type: dso:complexity-evaluator` (model: haiku) to classify the epic's complexity before deciding the decomposition path.

**Dispatch the evaluator:**

Dispatch via `subagent_type: dso:complexity-evaluator` with `model: haiku`. Pass the epic ID as the task argument. Pass `tier_schema=SIMPLE` as a field in the task context so the agent outputs SIMPLE/MODERATE/COMPLEX tier vocabulary.

**Fallback**: If the `dso:complexity-evaluator` named agent is unavailable, fall back to `subagent_type: general-purpose` and load the shared rubric prompt from `$PLUGIN_ROOT/skills/sprint/prompts/` (see `epic-complexity-evaluator` prompt file in that directory).

**Route based on classification:**

| Classification | Confidence | Route |
|---------------|------------|-------|
| SIMPLE | high | Step 3a (Direct Implementation Planning) |
| SIMPLE | medium | Treat as MODERATE |
| MODERATE | high | Step 3b (Lightweight Preplanning) |
| MODERATE | medium | Treat as COMPLEX |
| COMPLEX | any | Step 3c (Full Preplanning) |

Log the classification: `"Epic <id> classified as <CLASSIFICATION> (confidence: <confidence>) — routing to <path>."`

#### Step 3a: Direct Implementation Planning (SIMPLE epics) (/dso:sprint)

The epic's requirements are clear and the scope is small. Skip preplanning entirely and run `/dso:implementation-plan` directly on the epic.

1. Log: `"Epic <id> classified as SIMPLE — running /dso:implementation-plan directly on epic."`
2. Invoke `/dso:implementation-plan` via Skill tool with the epic ID as the argument:
   ```
   Skill("dso:implementation-plan", args="<epic-id>")
   ```
   The skill handles epic type detection and runs inline (no sub-agent dispatch needed).
3. Parse the skill's output using the same STATUS protocol as Phase 2's Implementation Planning Gate
4. Set `epic_routing = "SIMPLE"` — this flag tells Phase 2 to skip the Implementation Planning Gate
5. Continue to Phase 2

#### Step 3b: Lightweight Preplanning (MODERATE epics) (/dso:sprint)

The epic needs scope clarification but is a single concern — enrich the epic without creating stories.

1. Log: `"Epic <id> classified as MODERATE — running /dso:preplanning --lightweight for scope clarification."`
2. Invoke `/dso:preplanning <epic-id> --lightweight`
3. Parse the result:

**On `ENRICHED`:**
- Log: `"Lightweight preplanning complete — epic enriched with done definitions. Running /dso:implementation-plan on epic."`
- Invoke `/dso:implementation-plan` via Skill tool (same as Step 3a, step 2)
- Set `epic_routing = "MODERATE"`
- Continue to Phase 2

**On `ESCALATED`:**
- Log: `"Lightweight preplanning escalated to full mode — reason: <reason>. Running full /dso:preplanning."`
- Invoke `/dso:preplanning <epic-id>` (full mode, no --lightweight flag)
- Set `epic_routing = "COMPLEX"`
- Continue to Phase 2

#### Step 3c: Full Preplanning (COMPLEX epics) (/dso:sprint)

The epic needs structural decomposition into stories. This is the current behavior, unchanged.

1. Log: `"Epic <id> classified as COMPLEX — running /dso:preplanning for full story decomposition."`
2. Invoke `/dso:preplanning <epic-id>`
3. After preplanning completes, set `epic_routing = "COMPLEX"`
4. Continue to Phase 2

---

## Phase 2: Task Analysis & Dependency Graph (/dso:sprint)

### Gather Tasks

1. `.claude/scripts/dso ticket deps <epic-id>` — get all child tasks
2. `.claude/scripts/dso ticket list` (filtered by parent) — get unblocked tasks ready to work
3. `.claude/scripts/dso ticket show <id>` for each ready task to read full descriptions

### Implementation Planning Gate

After gathering tasks, check whether any ready stories need implementation task decomposition before they can be executed by sub-agents.

#### Pre-check: Skip for SIMPLE/MODERATE Routing (/dso:sprint)

If `epic_routing` is `"SIMPLE"` or `"MODERATE"` (set in Phase 1's Preplanning Gate), skip the entire Implementation Planning Gate and proceed directly to **Classify Tasks** below. Tasks were already created as direct children of the epic by `/dso:implementation-plan` — there is no story layer to decompose.

Log: `"Skipping Implementation Planning Gate — epic was routed as <epic_routing>, tasks already exist under epic."`

#### Step 1: Identify Stories Needing Implementation Planning (/dso:sprint)

For each ready task from `.claude/scripts/dso ticket list` (filtered by parent):
1. Run `.claude/scripts/dso ticket deps <task-id>` to check if the story already has child implementation tasks
2. If it has children → **skip** (already planned)
3. If it has zero children → run the complexity evaluator:

**Dispatch a haiku complexity-evaluator sub-agent** to classify the story. Dispatch via `subagent_type: dso:complexity-evaluator` with `model: haiku`. Pass the story ID as the task argument. Pass `tier_schema=TRIVIAL` as a field in the task context so the agent outputs TRIVIAL/MODERATE/COMPLEX tier vocabulary.

**Fallback**: If the `dso:complexity-evaluator` named agent is unavailable, fall back to `subagent_type: general-purpose` and load the shared rubric prompt from `$PLUGIN_ROOT/skills/sprint/prompts/` (see `complexity-evaluator` prompt file in that directory).

**Routing based on classification:**

| Classification | Confidence | Action |
|---------------|------------|--------|
| TRIVIAL | high | Skip `/dso:implementation-plan` — log: `"Story <id> classified as TRIVIAL — skipping /dso:implementation-plan"` |
| TRIVIAL | medium | Treat as COMPLEX (medium confidence = plan) |
| COMPLEX | any | Run `/dso:implementation-plan` via Skill tool (see Step 2) |

**Post-routing action for COMPLEX stories**: After routing a story to `/dso:implementation-plan`, tag it so Phase 5 can upgrade implementation task models:
```bash
.claude/scripts/dso ticket comment <story-id> "COMPLEXITY_CLASSIFICATION: COMPLEX"
```

**When in doubt, the evaluator defaults to COMPLEX** — medium confidence always routes to `/dso:implementation-plan`. The cost of an unnecessary `/dso:implementation-plan` is low; the cost of a sub-agent floundering without a plan is high.

#### Dependency Layer Stratification (/dso:sprint)

Before invoking `/dso:implementation-plan` for any stories, group the stories that need decomposition into topological layers based on their intra-sprint dependencies. This ensures that stories with blockers are planned after the stories they depend on.

**Step A: Collect intra-sprint dependency edges**

For each story in the needs-planning list:
1. Run `.claude/scripts/dso ticket show <story-id>` and read the `DEPENDS ON` field
2. For each dependency listed, check whether it is also in the needs-planning list
3. Record the edge only if both the story and its blocker are in the needs-planning list (ignore cross-sprint or already-completed dependencies)

**Step B: Assign layers**

Using the intra-sprint edges collected in Step A, assign each story to a layer:
1. **Layer 0**: stories with no intra-sprint blockers (no edges pointing into them from other needs-planning stories)
2. **Layer N**: stories whose all blockers are already assigned to Layers 0 through N-1

Repeat until all stories are assigned. If a cycle is detected (story A blocks story B and story B blocks story A), log a warning and treat both as Layer 0 to avoid deadlock.

**Step C: Output layer assignment**

Produce an ordered list of layers, where each layer is a set of story IDs:
- Layer 0: `[story-id-a, story-id-b, ...]` — no blockers, plan first
- Layer 1: `[story-id-c, ...]` — blocked only by Layer 0 stories
- Layer N: `[...]` — blocked by stories in earlier layers

Log the layer assignment: `"Dependency layers: Layer 0: <ids>, Layer 1: <ids>, ..."`. Proceed to Step 2 using this layer ordering.

#### Step 2: Run Implementation Planning (/dso:sprint)

Process stories in layer order — Layer 0 first, then Layer 1, etc. Within each layer, invoke `/dso:implementation-plan` sequentially via Skill tool for each story that needs decomposition. Wait for all stories in the layer to complete before processing the next layer.

> **Note**: Skill tool invocations run sequentially (one story at a time) rather than in parallel. This ensures implementation plans are properly reviewed via the inline review protocol workflow. The tradeoff is longer planning time for multi-story epics.

**For each layer (in order Layer 0, Layer 1, ...):**

a. Filter to stories in this layer that need decomposition
b. For each story in the layer, invoke `/dso:implementation-plan` via Skill tool:
   ```
   Skill("dso:implementation-plan", args="<story-id>")
   ```
   - Log: `"Story <id> has no implementation tasks — running /dso:implementation-plan to decompose."`
c. Wait for the skill invocation to return before processing the next story in the layer
d. For each skill result, **parse STATUS:**
   - On `STATUS:complete TASKS:<ids> STORY:<id>`:
     - Extract the comma-separated task IDs from the `TASKS` field
     - Extract the story ID from the `STORY` field
     - Log: `"Implementation planning complete for story <story-id> — created tasks: <task-ids>"`
     - Proceed to post-dispatch validation (step e)
   - On `STATUS:blocked QUESTIONS:<json-array>`:
     - **Add to blocked-stories list** — do not ask the user inline; collect all `STATUS:blocked` results from this layer batch and present them together after the full layer batch completes (see step d-collect below)
   - **Fallback — if no STATUS line in skill output:**
     - Run `.claude/scripts/dso ticket deps <story-id>` to check whether tasks were created
     - If children exist → treat as success; log a warning: `"WARNING: skill returned no STATUS line for story <id>, but .claude/scripts/dso ticket deps shows tasks — continuing"`; proceed to post-dispatch validation
     - If no children → retry the skill invocation once (same parameters)
     - If retry also produces no children → revert story to open (`.claude/scripts/dso ticket transition <story-id> open`); log: `"ERROR: /dso:implementation-plan failed for story <id> after retry — story reverted to open"`; skip to next story
d-collect. **Collect and present blocked-layer stories** — after the full layer batch completes, for each story with `STATUS:blocked`:
   - **Parse the QUESTIONS field**: Extract the JSON array from the `STATUS:blocked` line. If parsing fails (malformed JSON) or the array is empty (`[]`), treat as a sub-agent failure:
     - Revert the story to open: `.claude/scripts/dso ticket transition <story-id> open`
     - Log: `"ERROR: /dso:implementation-plan returned STATUS:blocked with no parseable questions for story <story-id> — story reverted to open"`
     - Remove story from blocked-stories list
   - **Present all remaining blocked stories' questions to the user at once** — separate by `kind` field:
     ```
     /dso:implementation-plan needs clarification for story <story-id>:

     Blocking (cannot plan without answers):
     1. <question text for kind="blocking">
     ...

     Defaultable (will use stated assumption unless you say otherwise):
     1. <question text for kind="defaultable" — already includes assumption>
     ...

     Please answer the blocking questions. Confirm or override any defaultable assumptions you want to change.
     ```
     If all questions are one kind, omit the empty section header.
   - **Collect user responses**: Wait for the user to reply. Accept free-text response.
   - **Persist answers to story description**: Append a `## Clarifications` section to the story description in the tickets system so the answers survive compaction:
     ```bash
     # Append clarifications to the ticket via comment
     .claude/scripts/dso ticket comment <story-id> "## Clarifications (from sprint orchestrator)
     Q1: <question 1 text>
     A1: <user answer 1>
     Q2: <question 2 text>
     A2: <user answer 2>"
     ```
   - **Re-invoke the skill**: Call the Skill tool again with the same story ID. The clarifications are now persisted in the ticket description, so the skill will read them via `.claude/scripts/dso ticket show`.
   - **If the re-invoked skill returns `STATUS:blocked` again**: Do not ask the user a second time. Treat as failure: revert story to open (`.claude/scripts/dso ticket transition <story-id> open`), log `"ERROR: /dso:implementation-plan returned STATUS:blocked twice for story <story-id> — story reverted to open"`, and skip to the next story.
e. **Post-layer-batch ticket validation** — after all stories in the layer are resolved (complete, blocked-and-resolved, or failed), run:
   ```bash
   .claude/scripts/dso validate-issues.sh --quick --terse
   ```
   Log any warnings but do not block on non-critical results
f. Re-run `.claude/scripts/dso ticket list` (filtered by parent) to pick up newly created implementation tasks before processing the next layer

#### Step 3: Continue to Classification (/dso:sprint)

After all stories have been decomposed, proceed to task classification below with the updated task list.

### Classify Tasks

Classification is performed automatically by `sprint-next-batch.sh` in Phase 3. Each `TASK:` line in its output already includes `model`, `subagent`, and `class` fields — no separate classification step is needed here. Proceed directly to building the dependency graph below.

### Build Dependency Graph

Output a textual dependency graph showing:
- All child tasks with status
- Blocking relationships (arrows)
- Batch assignment for ready tasks

### Exit Condition

If no ready tasks exist:
1. Run `.claude/scripts/dso ticket list` to identify blocking chain
2. Report which tasks are blocked and by what
3. Exit with recommendation

---

## Phase 3: Batch Planning (/dso:sprint)

### Pre-Batch Cleanup

Before building the Batch 1 checklist, clear any lingering tasks from the pre-loop phase:

1. Run `TaskList` to check for pending/in_progress/completed tasks from the pre-loop phase
2. For each task that is NOT a batch work item: `TaskUpdate(taskId=<id>, status='completed')`

### Initialize Batch Progress Checklist

> **CHECKLIST RESET**: At the start of Phase 3 for EACH new batch (Batch 1, Batch 2, etc.),
> complete all previous batch tasks via `TaskUpdate(status='completed')`, then create new
> tasks for the current batch via `TaskCreate`. If you are starting Batch N and the task list
> still shows Batch N-1 items, complete them before creating new batch tasks.

Create tasks via `TaskCreate` for the current batch's items. Replace `N` with the current batch number (1, 2, 3...).

```
[ ] Batch N — Plan (sprint-next-batch.sh)
[ ] Batch N — Pre-batch checks (session usage, git clean, db status)
[ ] Batch N — Claim tasks (.claude/scripts/dso ticket transition in_progress)
[ ] Batch N — Launch sub-agents
[ ] Batch N — Verify sub-agent results + acceptance criteria
[ ] Batch N — Integrate discovered tasks
[ ] Batch N — File overlap check
[ ] Batch N — Run post-batch validation
[ ] Batch N — Persistence coverage check
[ ] Batch N — Visual verification (UI tasks only)
[ ] Batch N — Code review (REVIEW-WORKFLOW.md)
[ ] Batch N — Update ticket notes / handle failures
[ ] Batch N — Commit and push
[ ] Batch N — Context check (compact if ≥70%)
```

Mark each item `in_progress` when starting and `completed` when done.

### Inject Prior Batch Discoveries (Batch 2+ only)

For Batch 2 and subsequent batches, collect discoveries from the previous batch and
prepare them for injection into sub-agent prompts via the `{prior_batch_discoveries}`
placeholder in `task-execution.md`:

```bash
PRIOR_BATCH_DISCOVERIES=$(.claude/scripts/dso collect-discoveries.sh --format=prompt 2>/dev/null) || PRIOR_BATCH_DISCOVERIES="None."
```

- For **Batch 1** (no prior discoveries), set `PRIOR_BATCH_DISCOVERIES="None."`
- For **Batch 2+**, the script outputs a markdown-formatted `## PRIOR_BATCH_DISCOVERIES`
  section listing each discovery with type, task ID, summary, and affected files
- When populating the `task-execution.md` template in Phase 5, replace `{prior_batch_discoveries}`
  with the value of `PRIOR_BATCH_DISCOVERIES`
- **Graceful degradation**: If `collect-discoveries.sh --format=prompt` fails, log a warning
  and use `"None."` as the fallback value. Discovery injection failure must not block the sprint.

### Compose Batch

Run the deterministic batch selector. It handles story-level blocking, task
dependencies, file-overlap detection, classification, and the opus cap in one call —
the orchestrator receives everything needed to launch sub-agents directly:

```bash
.claude/scripts/dso sprint-next-batch.sh <epic-id> --limit=<max_agents>
```

- **`max_agents`**: Use 5 initially. Phase 4's pre-check may truncate to 1 if session
  usage is >90% — in that case re-run with `--limit=1` (or manually discard extras).
- **Omit `--limit`**: Returns the full non-conflicting pool (useful for `--dry-run`).

#### Output format

Each `TASK:` line is tab-separated with all fields the orchestrator needs to launch
the sub-agent — **no further `.claude/scripts/dso ticket show` or `classify-task.sh` calls required**:

```
TASK: <id>  P<priority>  <issue-type>  <model>  <subagent-type>  <class>  <title>  [story:<id>]
```

| Line prefix | Meaning |
|-------------|---------|
| `EPIC: <id> <title>` | Epic being planned |
| `AVAILABLE_POOL: N` | Candidates before overlap/cap filtering |
| `BATCH_SIZE: N` | Tasks selected for this batch |
| `TASK: ...` (tab-separated) | id, P\<priority\>, type, model, subagent, class, title |
| `SKIPPED_OVERLAP: <id> ...` | Deferred — file conflict with higher-priority task |
| `SKIPPED_OPUS_CAP: <id> ...` | Deferred — opus cap (2) already reached |
| `SKIPPED_BLOCKED_STORY: <id> ...` | Deferred — parent story has open blockers |
| `SKIPPED_IN_PROGRESS: <id> ...` | Already claimed by another agent |

Use `--json` for machine-readable output with full detail including file lists.

#### What the script handles (no orchestrator action required)

- **Story-level blocking**: Blocked story → all child tasks deferred, regardless of
  their own dependency state (3-tier propagation: epic → story → task).
- **File overlap**: Higher classify-priority task wins; lower-priority task defers to
  the next cycle. No `.claude/scripts/dso ticket link` is needed — the task reappears as ready naturally.
- **Classification**: Each TASK line includes `model`, `subagent`, and `class` from
  `classify-task.py` — sorted by classify priority (interface-contract first, then
  fan-out-blocker, then independent, then db-dependent), then ticket priority.
- **Opus cap**: At most 2 `model=opus` tasks per batch. Additional opus tasks are
  reported as `SKIPPED_OPUS_CAP` and deferred; freed slots are filled by non-opus tasks
  in priority order.

#### Exit condition

If `BATCH_SIZE: 0`, run `.claude/scripts/dso ticket list` to surface the blocking
chain, report to the user, and exit.

### Dry-Run Mode

If `--dry-run` was specified:
1. Run `sprint-next-batch.sh <epic-id>` (no `--limit`) to get the full pool
2. For each story that needs implementation planning (Phase 2 gate), output one line per story:
   ```
   Dispatching impl-plan sub-agent for story <story-id>: <story-title>
   ```
3. Output the batch plan: task IDs, titles, model, subagent, class
4. **Stop** — do not execute any sub-agents

---

## Phase 4: Pre-Batch Checks (/dso:sprint)

Before launching each batch, run the shared pre-batch check script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check       # standard
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check --db  # if batch includes DB-dependent tasks
```

The script outputs structured key-value pairs:
- `MAX_AGENTS: 1 | 5` — use as `max_agents`
- `SESSION_USAGE: normal | high`
- `GIT_CLEAN: true | false` — if false, commit previous batch first
- `DB_STATUS: running | stopped | skipped` — if stopped, ask user to start DB

Exit 0 means all checks pass. Exit 1 means at least one check requires action (details in output).

### Clean Discovery Directory

Before launching sub-agents, ensure the discovery directory is clean so that only
discoveries from the current batch are collected in Phase 6:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries
```

The script removes any leftover `$ARTIFACTS_DIR/agent-discoveries/*.json` files from the previous batch (dir resolved via `get_artifacts_dir()`)
and ensures the directory exists so agents can write to it immediately. Output:
`DISCOVERIES_CLEANED: <N>`. Exit 0 always (cleanup is best-effort).

**Batch size limit**: Launch at most 5 Task calls in a single message, each with `run_in_background: true`. Before each batch, verify: how many tasks am I about to launch? If > 5, split into multiple batches.

When `max_agents=1`, re-run `sprint-next-batch.sh <epic-id> --limit=1` to get a
single-task batch. Log: `"Session usage >90%, limiting to 1 sub-agent."`

### Claim Tasks

For each task in the batch:
```bash
.claude/scripts/dso ticket transition <id> in_progress
```

### Update from Main

Pull the latest ticket state from main before launching sub-agents. This ensures the batch sees any ticket changes pushed by other worktrees since the last sync:

```bash
.claude/scripts/dso worktree-sync-from-main.sh
```

**Never run bare `git merge origin/main` in a worktree** — use the sync script which handles ticket branch syncing and merge automatically.

If the script reports a non-ticket merge conflict, resolve it (prefer local for code files), commit, and re-run the script. If it fails entirely, log a warning and continue — stale ticket state is preferable to a blocked batch.

---

## Phase 5: Sub-Agent Launch (/dso:sprint)

Launch up to `max_agents` sub-agents (1 or 5, determined in Phase 4) via the Task tool. Each sub-agent gets a structured prompt:

### Display Batch Task List

Before dispatching any sub-agents, print a numbered list of all tasks in the batch so the user can see what work is about to begin. Each line must show the task ID and title:

```
1. [dso-abc1] Fix authentication bug
2. [dso-def2] Add rate limiting to API endpoints
3. [dso-ghi3] Refactor session management
```

Titles are parsed from the `TASK:` tab-separated lines produced by `sprint-next-batch.sh` — the last field in each `TASK:` line is the title. No additional `.claude/scripts/dso ticket show` calls are needed.

### Blackboard Write and File Ownership Context

Before dispatching sub-agents, create the blackboard file and build per-agent file ownership context:

1. **Write the blackboard**: Pipe the batch JSON (from `sprint-next-batch.sh --json` in Phase 3) to `write-blackboard.sh`:
   ```bash
   echo "$BATCH_JSON" | .claude/scripts/dso write-blackboard.sh
   ```
   If `write-blackboard.sh` fails, log a warning and continue without blackboard — sub-agents will receive empty `{file_ownership_context}`. Blackboard failure must not block sub-agent dispatch.

2. **Read the blackboard and build file ownership context**: Read the blackboard and construct a per-agent ownership string for each sub-agent:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   BLACKBOARD="${TMPDIR:-/tmp}/dso-blackboard-$(basename "$REPO_ROOT")/blackboard.json"
   ```
   For each agent (task), build a `file_ownership_context` string with the format:
   ```
   You own: file1.py, file2.py. Other agents own: <task-id-X> owns file3.py, file4.py; <task-id-Y> owns file5.py.
   ```
   If the blackboard file does not exist (due to earlier failure or degradation), use an empty string for `file_ownership_context`.

3. **Populate the placeholder**: When filling the `task-execution.md` prompt template, replace `{file_ownership_context}` with the per-agent ownership string built above. Each sub-agent receives its own tailored context showing which files it owns and which files other agents in the batch own.

### Sub-Agent Prompt Template

For each task, launch a Task with the appropriate `subagent_type` (use `general-purpose` for most code tasks, or a specialized type if the task clearly matches one).

**Quality gate (ticket-as-prompt)**: Before dispatch, run the quality check:
```bash
.claude/scripts/dso issue-quality-check.sh <task-id>
```

- **Exit 0 (quality pass)**: Use the ticket-as-prompt template — read `$PLUGIN_ROOT/skills/sprint/prompts/task-execution.md` and fill in `{id}` only. The sub-agent reads its own full context via `.claude/scripts/dso ticket show`.
- **Exit 1 (too sparse)**: Try enriching the ticket first with `.claude/scripts/dso enrich-file-impact.sh <task-id>`, then re-run the quality check. If still failing, fall back — run `.claude/scripts/dso ticket show <id>`, then include the full description inline in the prompt alongside the template instructions.

**Acceptance criteria gate**: After the quality gate, run:
```bash
.claude/scripts/dso check-acceptance-criteria.sh <task-id>
```

- **Exit 0**: Proceed with dispatch — task has structured AC block
- **Exit 1**: Do NOT dispatch. Read `${CLAUDE_PLUGIN_ROOT}/docs/ACCEPTANCE-CRITERIA-LIBRARY.md`, compose an
  appropriate acceptance criteria block for the task, and add it via `.claude/scripts/dso ticket comment <id> "## Acceptance Criteria\n<criteria>"`.

  Re-run the check. If criteria cannot be determined (ambiguous task type), halt and ask the user.

### Subagent Type and Model Selection

Use the `model` and `subagent` fields from the `TASK:` lines produced by
`sprint-next-batch.sh` in Phase 3 — **no additional classify-task.sh call needed**.

When launching each Task tool call, set:
- `subagent_type` = the `subagent` field from the TASK line
- `model` = the `model` field from the TASK line

**COMPLEX story model upgrade**: Before dispatching each task, check whether the parent
story was tagged COMPLEX. Only upgrade if ALL three conditions hold:
1. The task's `model` field from `classify-task.py` is `"sonnet"` (skip if already `"opus"`)
2. The task's `class` field is not `"skill-guided"` (docs/config tasks do not benefit from opus)
3. The parent story is COMPLEX: run `.claude/scripts/dso ticket show <task-id>` and read the `parent` field;
   if a parent story ID exists, run `.claude/scripts/dso ticket show <parent-story-id>` and grep its output with
   `grep -Fx "COMPLEXITY_CLASSIFICATION: COMPLEX"` (exact full-line match to avoid false positives).
   `.claude/scripts/dso ticket show` outputs the full ticket body including note text, so this grep works on note content.

When all three conditions hold, override `model` to `"opus"` and log:
`"Story <parent-id> classified COMPLEX — upgrading task <task-id> model to opus."`

**Skill-guided tasks**: If classification `class` is `"skill-guided"`, append to
the sub-agent prompt: `"Before implementing, check if a skill applies to this task
type (e.g., /writing-skills for skill files, /claude-md-improver for CLAUDE.md
updates, /writing-rules for hookify rules)."` The sub-agent uses its judgment to
invoke the appropriate skill based on the task content.

**Agent description**: Derive from the ticket title — a 3-5 word human-readable summary (e.g., Fix review gate hash, not dso-abc1).

**Important**: Launch ALL sub-agents in the batch within a single message, each with `run_in_background: true`. Without `run_in_background`, foreground Agent calls block until they return — launching 4 agents in one message still executes them serially. Do not launch them sequentially. Maximum 5 Task calls per message.

**Worktree boundary**: If running in a worktree session, append to every sub-agent prompt: `"IMPORTANT: Only modify files under $(git rev-parse --show-toplevel). Do NOT write to any other path."` The PreToolUse edit guard only blocks Edit/Write tools — Bash commands bypass it.

### RED Task Dispatch — Escalation Protocol

**Detect RED tasks**: Before dispatching each task, check whether the `subagent` field from the `TASK:` line equals `dso:red-test-writer`. RED test tasks use a specialized three-tier escalation protocol instead of the normal dispatch flow.

**When `subagent` = `dso:red-test-writer`**, do NOT dispatch via the normal Task tool flow. Instead, follow `prompts/red-task-escalation.md` (the shared three-tier escalation template):

**Tier 1 — Dispatch `dso:red-test-writer` (sonnet)**:
- Pass the full task context: task description, story context, and file impact table
- Parse the leading `TEST_RESULT:` line from the output:
  - `TEST_RESULT:written` → Success. Proceed to TDD setup using `TEST_FILE` and `RED_ASSERTION` fields. Do NOT escalate.
  - `TEST_RESULT:rejected` → Escalate to Tier 2. This is **not** a dispatch failure — do not route to Phase 6 Step 0.
  - Timeout / malformed / non-zero exit → Treat as `TEST_RESULT:rejected` with `REJECTION_REASON: ambiguous_spec`. Escalate to Tier 2.

**Tier 2 — Dispatch `dso:red-test-evaluator` (opus)**:
- Pass: (1) the full `TEST_RESULT:rejected` payload verbatim, and (2) the orchestrator context envelope:
  ```
  TASK_ID: <task_id>
  STORY_ID: <story_id>
  EPIC_ID: <epic_id>
  TASK_DESCRIPTION: <task_description>
  IN_PROGRESS_TASKS: <comma-separated task_ids or "none">
  CLOSED_TASKS: <comma-separated task_ids or "none">
  ```
- Parse the leading `VERDICT:` line:
  - `VERDICT:REVISE` → Requeue all tasks in `AFFECTED_TASKS` to the next batch. Apply `REVISION_GUIDANCE` on re-dispatch. Max one REVISE per task — if the same task reaches REVISE a second time, escalate to the user immediately with both REVISE payloads.
  - `VERDICT:REJECT` → Escalate to Tier 3 (opus retry).
  - `VERDICT:CONFIRM` → Close the task without implementation. Record the `INFEASIBILITY_CATEGORY` and `JUSTIFICATION` in a ticket comment via `.claude/scripts/dso ticket comment <id> "..."` before closing.
  - Timeout / malformed / non-zero exit → Treat as `VERDICT:REJECT`. Escalate to Tier 3.

**Tier 3 — Re-dispatch `dso:red-test-writer` (opus model override)**:
- Re-dispatch the original task to `dso:red-test-writer` with model overridden to **opus**
- Pass the same task context as Tier 1, augmented with the evaluator's `VERDICT:REJECT` payload (including its `REJECTION_REASON`) so the opus writer has full context on why the sonnet attempt failed
- Parse the leading `TEST_RESULT:` line:
  - `TEST_RESULT:written` → Success. Proceed to TDD setup normally.
  - `TEST_RESULT:rejected` → Terminal failure. Escalate to the user with: the Tier 1 rejection payload, the Tier 2 `VERDICT:REJECT` reason, and the Tier 3 rejection payload. Do not retry further.
  - Timeout / malformed / non-zero exit → Terminal failure. Escalate to the user.

See `prompts/red-task-escalation.md` for the complete escalation summary and important notes (REVISE loop prevention, CONFIRM audit requirements, and shared-template usage with `/dso:fix-bug`).

---

## Phase 6: Post-Batch Processing (/dso:sprint)

After ALL sub-agents in the batch return, follow the Orchestrator Checkpoint Protocol from CLAUDE.md.

### Step 0: Dispatch Failure Recovery (/dso:sprint)

Before verifying results, check whether any sub-agent Task call returned an **infrastructure-level dispatch failure** — i.e., the Task tool itself errored rather than the sub-agent producing work that was incorrect. Dispatch failures are distinguishable from task-level failures by their error signature: no `STATUS:` line, no `FILES_MODIFIED:` line, and the error message references agent type, tool availability, or internal errors.

**RED test task exception**: If the failed task's original `subagent` field was `dso:red-test-writer`, do NOT fall back to `general-purpose`. A `TEST_RESULT:rejected` response from `dso:red-test-writer` is **not** an infrastructure dispatch failure — it is an expected domain rejection that triggers the three-tier escalation protocol (see Phase 5 RED Task Dispatch section). Route the task through Tier 2 (dispatch `dso:red-test-evaluator`) instead of the general-purpose retry path. Only true dispatch failures (no `TEST_RESULT:` line, no `STATUS:` line, tool-level error indicators) qualify for the recovery flow below.

**For each sub-agent that returned a dispatch failure:**

1. **Detect**: The Task result contains no `STATUS:` or `FILES_MODIFIED:` lines AND includes error indicators (e.g., "unknown subagent_type", "agent unavailable", "internal error", "Tool result missing")
2. **Retry with general-purpose**: Re-dispatch the same task immediately using `subagent_type="general-purpose"` with the same model and prompt. Log: `"Dispatch failure for task <id> with subagent_type=<original-type> — retrying with general-purpose."`
3. **If retry succeeds**: Continue to Step 1 with the retry result
4. **If retry also fails**: Escalate model (sonnet → opus) and retry once more with `subagent_type="general-purpose"`. Log: `"Retry with general-purpose also failed for task <id> — escalating model to opus."`
5. **If all retries fail**: Mark the task as failed and proceed to Step 9

**Important**: Dispatch failure retries happen sequentially (not parallel) since they are error recovery, not planned work. Do not count retries toward the batch size limit.

### Step 1: Verify Results (/dso:sprint)

For each sub-agent (including any that succeeded on retry), check the Task tool result:
- Did it report success?
- Are the expected files present? (spot-check with Glob)
- Were tests passing?

### Step 1a: Migration Behavioral Verification (/dso:sprint)

For each sub-agent in the batch, check if its task description contains migration keywords (`remove`, `delete`, `migrate`, `move`, `replace`). For migration tasks:

1. **Verify the replacement exists**: Run the first task-specific (non-universal) AC `Verify:` command. If it fails, the migration deleted something without creating its replacement — mark the task as failed.
2. **Behavioral smoke test**: If the task migrates a command, skill, or script, invoke or test the migrated artifact (e.g., check that the replacement file contains the expected workflow reference, or that the command resolves to a project-owned artifact). Log: `"Migration behavioral check for <task-id>: <pass|fail>"`

This step catches the "delete old thing, assume new thing exists" pattern that structural-only verification misses.

### Step 1a2: Test Coverage Enforcement (/dso:sprint)

For each sub-agent that returned successfully, check whether its code changes include corresponding test changes:

1. Extract the list of modified source files from the sub-agent result (files matching `src/**/*.py` or equivalent source patterns, excluding `__init__.py`, migrations, and config files)
2. Extract the list of modified test files (files matching `tests/**/*.py`)
3. If source files were modified but NO test files were modified or created, the sub-agent returned untested code changes. An untested code change is a bug waiting to happen.
4. For untested changes, dispatch a sub-agent (same model as the original) with prompt:
   ```
   The task <task-id> modified source files (<file list>) but did not include any test changes.
   Review the changes and write appropriate tests following TDD principles.
   Read the task's acceptance criteria: .claude/scripts/dso ticket show <task-id>
   Ensure tests cover the modified behavior. Run the tests to confirm they pass.
   ```
5. Log: `"Test coverage enforcement for <task-id>: dispatched test sub-agent for untested changes in <files>"`

**Exceptions** (skip enforcement):
- Tasks classified as `skill-guided` or `docs-only`
- Tasks whose only source changes are type stubs, `__init__.py` re-exports, or Alembic migrations
- Tasks that explicitly document in their AC why tests are not applicable

### Step 1b: Integrate Discovered Tasks (/dso:sprint)

For each sub-agent result, check the `TASKS_CREATED` line:
- If `none` → skip
- If `error: <reason>` → log the error, no action needed
- If task IDs listed (e.g., `ticket-042, ticket-043`):
  1. Run `.claude/scripts/dso ticket show <id>` for each created task to review title and description
  2. Wire dependencies via `.claude/scripts/dso ticket link` if the new task blocks or is blocked by existing work
  3. Log: "Sub-agent for <task-id> discovered N new tasks: <ids>"

After processing all sub-agents in the batch, if any tasks were created:
```bash
.claude/scripts/dso validate-issues.sh --quick --terse
```

Newly created tasks require no special handling beyond this step — they naturally
enter the next P3→P5→P6 batch cycle when the orchestrator loops back to Phase 3
(Batch Planning) for remaining work.

### Step 1c: Collect Agent Discoveries (/dso:sprint)

After integrating discovered tasks, collect the structured discovery files that sub-agents
wrote during execution. These discoveries are propagated to the next batch via the
`{prior_batch_discoveries}` placeholder in `task-execution.md` (see Phase 3).

```bash
DISCOVERIES=$(.claude/scripts/dso collect-discoveries.sh 2>/dev/null) || DISCOVERIES="[]"
```

- If `collect-discoveries.sh` succeeds, `DISCOVERIES` contains a JSON array of discovery objects
- Store the result for use in Phase 3 when composing the next batch's sub-agent prompts
- **Graceful degradation**: If discovery collection fails (script error, malformed JSON), log a
  warning and continue with `DISCOVERIES="[]"`. Discovery collection failure must not block the
  sprint. The script itself handles per-file validation — malformed individual files are skipped
  with warnings to stderr.

### Step 2: Acceptance Criteria Validation (/dso:sprint)

**Batched shared criteria** (run ONCE per batch, not per-task):
Universal criteria (test, lint, format) are already verified by Step 4
(validate-phase.sh post-batch). Do not re-run per task.

**Per-task structural criteria**:
For each task in the batch, extract the `Acceptance Criteria` block from `.claude/scripts/dso ticket show <id>` output
and run each task-specific (non-universal) `Verify:` command:

1. File existence: `test -f {file}` — exit 0 = pass
2. Class importable: `python -c "from {module} import {class}"` — exit 0 = pass
3. Test count: `grep -c "def test_" {file}` — compare to threshold
4. Grep-verifiable: run the grep pattern — exit 0 = pass

Criteria without a `Verify:` command are logged but not machine-verified —
caught by the formal code review (Step 7).

If any machine-verifiable criterion fails:
- Log the failed criterion and its `Verify:` output
- Mark the task as failed in Step 9 (revert to open)
- Include the failed criterion text in the re-dispatch prompt

### Batch Completion Summary

After all sub-agents in the batch have been verified (Steps 1–2), print a completion summary so the user can see the outcome for each task at a glance. Each line must show the task ID, title, and pass/fail result:

```
✓ [dso-abc1] Task title (pass)
✗ [dso-abc2] Other task (fail — reverted to open)
```

Titles are retained from the pre-launch batch list printed in Phase 5 — no additional `.claude/scripts/dso ticket show` calls are needed.

### Step 3: File Overlap Check (Safety Net) (/dso:sprint)

Sub-agents may modify files beyond what their task description predicts. Check for
actual conflicts before committing:

1. For each sub-agent, collect its modified files from the Task result
2. Run the overlap detection script:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh file-overlap \
     --agent=<task-id-1>:<file1>,<file2> \
     --agent=<task-id-2>:<file3>,<file4>
   ```
   The script outputs `CONFLICTS: <N>` followed by one `CONFLICT:` line per overlap.
   Exit 0 = no conflicts, exit 1 = conflicts detected.
3. If conflicts are detected, resolution (same protocol as `/dso:debug-everything` Phase 6 Step 1a):
   a. Identify the primary agent for each conflicting file (highest priority)
   b. Revert ALL secondary agents' changes to conflicting files
   c. Re-run secondary agents one at a time in priority order (not parallel),
      each with original prompt + Conflict Resolution Context (captured diff,
      instruction to respect current file state). Commit after each re-run.
   d. After each re-run: if agent only touched non-conflicting files -> merge OK.
      If it re-modified the same conflicting files -> escalate to user.
4. If no conflicts -> proceed to Step 4

### Step 3b: Semantic Conflict Check (/dso:sprint)

After the file overlap check, run the LLM-based semantic conflict detector on the
batch's combined diff to catch cross-file logical incompatibilities (type signature
mismatches, renamed symbols still referenced elsewhere, inconsistent state assumptions):

```bash
SEMANTIC_RESULT=$(git diff | python3 "$PLUGIN_SCRIPTS/semantic-conflict-check.py" 2>/dev/null) || SEMANTIC_RESULT='{"conflicts":[],"clean":true,"error":"script failed"}'
```

Parse the JSON output:
- If `clean` is `true`: log `"Semantic conflict check: clean"` and proceed
- If `clean` is `false`: log each conflict (files, description, severity) and escalate
  high-severity conflicts to the user before committing
- **Graceful degradation**: `semantic-conflict-check.py` always exits 0 — on failure it
  returns `{"conflicts":[], "clean":true, "error":"<message>"}`. Check for the `error`
  key: if present, log `"Semantic conflict check warning: <error>"` and proceed. Semantic
  conflict check failure is non-fatal and must not block the sprint.

### Step 4: Run Validation (/dso:sprint)

```bash
$PLUGIN_SCRIPTS/validate-phase.sh post-batch
```

If validation fails, identify which sub-agent's code is broken and note it.

#### Test Failure Sub-Agent Delegation (Phase 6 Step 4)

When `validate-phase.sh post-batch` fails, dispatch a debugging sub-agent BEFORE reverting tasks to open. Follow `prompts/test-failure-dispatch-protocol.md` with these caller-specific fields:
- `test_command`: the `validate-phase.sh post-batch` command that failed
- `changed_files`: files modified by the batch (`git diff --name-only`)
- `task_id`: the task ID of the sub-agent that likely caused the failure
- `context`: `sprint-post-batch`
- `batch_task_ids`: IDs of all tasks in the current batch

On `PASS`: re-run `validate-phase.sh post-batch` to confirm, then continue to Step 5.

### Step 5: Persistence Coverage Check (/dso:sprint)

If any task in the batch touched persistence-critical files (job_store, document_processor,
DB models, DB clients), run the persistence coverage check:

```bash
.claude/scripts/dso check-persistence-coverage.sh
```

> **Canonical location**: `.claude/scripts/dso check-persistence-coverage.sh` — `scripts/check-persistence-coverage.sh` is a backward-compatible exec wrapper that delegates to the canonical copy.

If the check fails:
1. Log: `"Persistence coverage check failed — persistence source changed without test coverage."`
2. **Do not commit.** Instead:
   a. If a sub-agent was responsible for the persistence change, re-run it with an updated prompt
      requiring a persistence test (DB round-trip or cross-worker test).
   b. If the persistence change was made by the orchestrator, write the missing test directly.
3. After adding the test, re-run the check and proceed only when it passes.

### Step 6: Visual Verification (UI tasks only) (/dso:sprint)

If any task in the batch modified templates, CSS, or frontend code:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT/app && make test-visual 2>&1
```

- **Pass** → Log: "Visual regression tests pass — MCP visual verification skipped."
- **Fail** → Use `/dso:playwright-debug` starting at the Visual Regression Gate (Tier 2 targeted investigation of flagged elements). If verification fails, revert the task to open.
- **No baselines** → Use `/dso:playwright-debug` full 3-tier process. Verify local env first: `$PLUGIN_SCRIPTS/check-local-env.sh`. Never skip Playwright validation without user approval.

### Step 7: Formal Code Review (/dso:sprint)

Execute the review workflow (REVIEW-WORKFLOW.md). If you have already read this file earlier in this conversation and have not compacted since, use the version in context. This produces a formal review state file with diff hash and scores at `$(get_artifacts_dir)/review-status` (computed by `get_artifacts_dir()` in `hooks/lib/deps.sh`). (Note: the commit workflow's review gate finds this state file and skips re-review.)

**Snapshot exclusion**: When generating the diff files for review (Steps 1 and 2.5 of REVIEW-WORKFLOW.md), exclude snapshot baseline files from the diff so reviewers focus on code changes:
```bash
".claude/scripts/dso capture-review-diff.sh" "$DIFF_FILE" "$STAT_FILE" \
  ':!app/tests/unit/templates/snapshots/*.html'
```

**Interpret results:**
- **No Critical or Important issues** (all scores >= 4) → proceed to Step 8
- **Critical or Important issues found** → ALWAYS enter the Autonomous Resolution Loop
  per REVIEW-WORKFLOW.md. Delegate to the resolution sub-agent to apply fixes, defenses,
  or deferrals. The orchestrator then dispatches a separate re-review sub-agent. No inline
  fixes by the orchestrator are allowed. If the responsible sub-agent's task needs rework,
  revert it to open, add the issue details to the task notes, and re-run it with the
  reviewer's feedback appended to the prompt.
- **Minor issues only** → proceed (note them in ticket but don't block)
- **Review uses autonomous resolution per batch.** The review workflow handles up to `review.max_resolution_attempts` (default: 5) fix/defend attempts automatically before escalating. The resolution loop is split: a resolution sub-agent applies fixes (returns `FIXES_APPLIED`), then the orchestrator dispatches a separate re-review sub-agent. This avoids two-level nesting (orchestrator → resolution → re-review) which causes `[Tool result missing due to internal error]`. See REVIEW-WORKFLOW.md Autonomous Resolution Loop. If issues persist after escalation, report to user and proceed to commit (CI and Phase 7 validation provide additional gates).

### Step 8: Update Ticket Notes (/dso:sprint)

For each task in the batch, write checkpoint-format notes for crash recovery:

| Outcome | Command |
|---------|---------|
| Success | `.claude/scripts/dso ticket comment <id> "CHECKPOINT 6/6: Done ✓ — Files: <files created/modified>. Tests: pass."` |
| Failure | `.claude/scripts/dso ticket comment <id> "CHECKPOINT <N>/6: Failed — <error summary>. Files modified: <files>. Resume from: <what remains>."` |

The checkpoint number on failure should reflect the last successfully completed substep (e.g., if tests passed but implementation failed, use `CHECKPOINT 4/6`).

### Step 9: Handle Failures (/dso:sprint)

For tasks that failed:
- Revert to open: `.claude/scripts/dso ticket transition <id> open`
- Record the failure reason in notes (already done in Step 8)

### Step 10: Commit & Push (/dso:sprint)

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md`. The review gate check
in Step 5 of the commit workflow will find the review state file from Step 7 is already
current, so review is skipped (no double review).

After the commit completes, push the worktree branch to keep it up to date:

```bash
git push -u origin HEAD
```

Do NOT merge to main here — merging to main happens only at epic completion in Phase 9, after non-CI validation passes.

**Blackboard cleanup**: After the commit, run `write-blackboard.sh --clean` to remove the blackboard file:
```bash
.claude/scripts/dso write-blackboard.sh --clean
```

**After completion, continue with Step 11 below.** Do not stop here.

> **CONTROL FLOW WARNING**: After the commit workflow and `git push -u origin HEAD` complete, continue
> IMMEDIATELY with Step 11 (Context Compaction Check). Do NOT use the `/dso:commit` Skill tool
> here — read and execute COMMIT-WORKFLOW.md inline to avoid nested skill invocations that
> may not return control. If you find yourself waiting for user input after pushing, you are
> experiencing a known control-flow regression (observed 2026-03-18). Type "continue"
> mentally and proceed directly to Step 11.

> **CONTINUE:** After `git push -u origin HEAD` and blackboard cleanup are done, proceed to Step 11 then Step 13. Do NOT close the epic or invoke `/dso:end-session` here.

### Step 10a: Close Completed Tasks (/dso:sprint)

After the batch commit and `git push -u origin HEAD` succeed, close each task whose code was successfully committed:

You MUST dispatch the completion-verifier before closing each story — inline verification by the orchestrator is NOT a substitute (see CLAUDE.md rule #26):
- **MANDATORY**: Dispatch `subagent_type: "dso:completion-verifier"` (model: sonnet) with the story ID
- The agent reads done definitions via `.claude/scripts/dso ticket show`
- If the agent returns `overall_verdict: PASS`: proceed with closure
- If the agent returns `overall_verdict: FAIL`: do NOT close the story. For each entry in `remediation_tasks_created`, create a bug task via `.claude/scripts/dso ticket create`. Return to Phase 3.
- **Fallback (technical failure only)**: If the dispatch was attempted and the agent times out, returns unparseable JSON, or fails to include `overall_verdict`, log a warning and proceed with closure — Phase 7's validate-work provides the next verification layer. This fallback applies ONLY to technical dispatch failures; it is NOT permission to skip the dispatch.

```bash
.claude/scripts/dso ticket comment <id> "Fixed: <summary>"
.claude/scripts/dso ticket transition <id> open closed
```

Do NOT close tasks that are still open or in a failed state.

### Step 11: Context Compaction Check (/dso:sprint)

Between batches — after all work is committed and pushed to the worktree branch — check whether the session context is at least 70% capacity. **This is the safe window for compaction**: all sub-agents have returned, work is committed and pushed, and ticket tracks task state. Compacting mid-batch would risk losing in-flight sub-agent context.

Run the context check:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
context_exit=0
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh context-check || context_exit=$?
# context_exit: 0=normal, 10=medium, 11=high
```

| Output | Exit Code | Meaning | Action |
|--------|-----------|---------|--------|
| `CONTEXT_LEVEL: normal` | 0 | <70% usage | Proceed to Step 13 normally |
| `CONTEXT_LEVEL: medium` | 10 | 70–90% usage | Compact before next batch (see below) |
| `CONTEXT_LEVEL: high` | 11 | >90% usage | Compact before next batch (agent limit handled separately by pre-check in Phase 4) |

**Note**: Exit codes are non-standard (10/11 indicate compaction recommended, not errors). Callers in `set -e` contexts should use `|| true` or check specific codes.

**The script uses two detection signals**: `CLAUDE_CONTEXT_WINDOW_USAGE` env var (if set by Claude Code) and `$HOME/.claude/check-session-usage.sh`. If neither is available, Claude should self-assess based on its own awareness of accumulated context across multiple batch iterations, tool outputs, and conversation length. When in doubt and multiple batches have run, prefer compacting.

**If `CONTEXT_LEVEL: medium` or `high`** (or Claude self-assesses as >=70%):

1. Log: `"Context usage >=70% — compacting before batch N+1 to prevent mid-work compaction."`
2. Verify the working tree is clean: `git status --short` (all work must be committed before compacting)
3. Write a compact-intent state file so the post-compaction continuation decision knows this was voluntary. Use the actual epic ID (e.g., `LPL-42`). The file is written under `${TMPDIR:-/tmp}` for portability:
   ```bash
   echo "voluntary" > "${TMPDIR:-/tmp}/sprint-compact-intent-<actual-epic-id>"
   ```
   **Important**: The epic ID must survive compaction. Before invoking `/compact`, note the epic ID explicitly in the log message — e.g., `"Compacting before batch N+1 for epic LPL-42."` — so the post-compaction recovery context has it.
4. Invoke compaction:
   ```
   /compact
   ```
5. After compaction, the recovery summary is injected into the new context. Check for `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>` (using the epic ID from the log/recovery summary). **Continue directly to Phase 3** — ticket task state and git history are intact. Do NOT go to Phase 9.
6. **Agent-count after compact (`high` case)**: If context was at `high` (>90%), Phase 4's pre-check re-runs `check-session-usage.sh` for the next batch. If it still signals high, Phase 4 will set `MAX_AGENTS: 1` automatically. No special action is needed in this step — Phase 4 handles it.

---

### Step 13: Continuation Decision (/dso:sprint)

```
Decision: Involuntary compaction detected? → Yes: P9 (Graceful Shutdown)
          → No: More ready tasks? → Yes: Return to P3
                                  → No: P7 (Validation)
```

**Distinguishing involuntary from voluntary compaction**: After a voluntary compact (Step 7b), the file `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>` exists. Delete it and continue to Phase 3. If you see recovery state injected into context but no intent file exists, the compaction was involuntary (Claude Code triggered it automatically while the session was in the middle of work) — go to Phase 9.

- If **involuntary** context compaction has occurred (no intent file) → Phase 9 (graceful shutdown)
- If more ready tasks exist (`.claude/scripts/dso ticket list` filtered by parent) → return to Phase 3
- If no more ready tasks and some tasks are still blocked → report blocking chain, Phase 9
- If all tasks are closed → **Phase 7 is MANDATORY** — proceed immediately to Phase 7 (validation)

---

## Phase 7: Post-Epic Validation (/dso:sprint)

**Triggered when**: all child tasks are closed (or all remaining are failed/blocked).

Validation has two stages: (1) comprehensive project health via `/dso:validate-work`, then (2) epic-specific quality scoring.

### Initialize Post-Loop Progress Checklist

Complete all remaining batch tasks, then create new tasks via `TaskCreate` for the post-epic validation steps:

```
[ ] Integration test gate
[ ] Wait for CI (SHA-based)
[ ] Run E2E tests locally
[ ] Full validation (/dso:validate-work + epic scoring)
[ ] Remediation (if score < 5 → returns to batch loop)
[ ] Close out (close epic + /dso:end-session)
```

Mark each item `in_progress` when starting and `completed` when done. If remediation triggers (score < 5), check off "Remediation" and return to Phase 3 — the batch checklist is re-initialized there, and this post-loop checklist is recreated fresh when Phase 7 is re-entered.

### Step 0: Integration Test Gate (/dso:sprint)

Check if this epic modified integration-relevant code and verify the External API Integration Tests workflow:

1. Get changed files: `git diff --name-only main...HEAD`
2. Check for integration-relevant changes by scanning file paths for:
   - `models/`, `migrations/`, `schema` (DB changes)
   - `providers/`, `services/` with external API calls
   - `routes.py`, `endpoints` (API contract changes)
3. Check the last "External API Integration Tests" workflow run:
   ```bash
   gh run list --workflow="External API Integration Tests" --limit 1 --json status,conclusion,createdAt,url --jq '.[0]'
   ```
4. Decision:
   - If integration-relevant changes detected AND last run is >24h old OR last run failed:
     - Trigger a new run: `gh workflow run "External API Integration Tests"`
     - Log: "Triggered External API Integration Tests — changes affect integrations."
     - Poll status (max 15 min): `gh run list --workflow="External API Integration Tests" --limit 1 --json status,conclusion --jq '.[0]'`
   - If last run passed and is recent (<24h): Log "Integration tests: PASS (last run: {createdAt})"
   - If no integration-relevant changes: Log "No integration-relevant changes — skipping integration test gate"
5. If integration tests fail after trigger: create a P1 bug issue and include in the Phase 7 report. Continue with /dso:validate-work (non-blocking but flagged).

### Step 0.5: CI Verification + E2E Tests (/dso:sprint)

Before running `/dso:validate-work`, verify CI has passed on the final batch's commit and run the full E2E suite locally.

#### Step 0.5a: Wait for CI Containing the Final Commit

**Docs-only detection (run first)**:

```bash
CODE_FILES=$(git diff --name-only main...HEAD | grep -vE '\.(md|txt|json)$|^\.tickets-tracker/|^\.claude/|^docs/' | head -1)
```

If `CODE_FILES` is empty (all changes are documentation, tickets, or config):
- Log: "Docs-only changes detected — skipping CI verification."
- Skip Steps 0.5a and 0.5b entirely
- Proceed directly to Step 1 (/dso:validate-work)

If `CODE_FILES` is non-empty: use `ci-status.sh --wait` which handles SHA-anchored polling, worktree auto-detection (falls back to `main` branch), and 30-minute timeout:

```bash
.claude/scripts/dso ci-status.sh --wait
```

| CI Result | Action |
|-----------|--------|
| `success` | Proceed to Step 0.5b |
| `failure` | Write the validation state file (see below), dispatch an `error-debugging:error-detective` sub-agent (model: `sonnet`) with the CI run URL and failed job names. Follow the test-failure-dispatch protocol (`prompts/test-failure-dispatch-protocol.md`). Commit+push, restart Step 0.5a. If still failing after one attempt → Phase 9 (Graceful Shutdown). |
| Not found after 30 min | Run `gh run list --workflow=CI --limit 10` to check if CI triggered. Report to user. |

#### Validation State File (CI failure context for error-detective sub-agent)

Before dispatching the error-detective sub-agent on CI failure, write the validation state file per `prompts/ci-failure-validation-state.md`.

#### Step 0.5b: Run E2E Tests

Run the full E2E suite locally. This catches browser-visible regressions before the broader `/dso:validate-work` gate.

```bash
cd $(git rev-parse --show-toplevel)/app && make test-e2e
```

**Interpret results:**
- **Pass** → proceed to Step 1
- **Fail** → do NOT proceed. Dispatch a debugging sub-agent FIRST before creating bug issues.

#### E2E Test Failure Sub-Agent Delegation (Phase 7 Step 0.5b)

When E2E tests fail, follow `prompts/test-failure-dispatch-protocol.md` with these caller-specific fields:
- `test_command`: `cd $(git rev-parse --show-toplevel)/app && make test-e2e`
- `changed_files`: files changed across all batches (`git diff --name-only main...HEAD`)
- `task_id`: a tracking task ID for checkpoint notes
- `context`: `sprint-e2e`

On `FAIL` after attempt 2: create a P1 bug issue for each failing test, set as child of epic, return to Phase 3.

### Step 0.75: Completion Verification (/dso:sprint)

You MUST dispatch the completion-verifier before closing the epic — inline verification by the orchestrator is NOT a substitute (see CLAUDE.md rule #26):

1. **MANDATORY**: Dispatch `subagent_type: "dso:completion-verifier"` (model: sonnet) with the epic ID
2. The agent reads success criteria from the epic description
3. If `overall_verdict: PASS`: proceed to Step 1
4. If `overall_verdict: FAIL`: For each entry in `remediation_tasks_created`, create a bug task. Return to Phase 3 for remediation.
5. **Fallback (technical failure only)**: If the dispatch was attempted and the agent times out, returns unparseable JSON, or fails to include `overall_verdict`, log a warning and proceed to Step 1 — validate-work provides the next verification layer. This fallback applies ONLY to technical dispatch failures; it is NOT permission to skip the dispatch.

### Step 1: Run /dso:validate-work (/dso:sprint)

Before invoking `/dso:validate-work`, gather the changed files so the staging test sub-agent can apply tiered behavior (skipping browser automation for backend-only changes):

```bash
CHANGED_FILES=$(git diff --name-only main...HEAD 2>/dev/null || git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")
echo "$CHANGED_FILES"
```

Invoke the `/dso:validate-work` skill. Immediately after the `/dso:validate-work` invocation, append the following context block verbatim — substitute the actual file list from the `$CHANGED_FILES` output above (one file per line). This block is forwarded by `/dso:validate-work` to the staging test sub-agent (Sub-Agent 5) for tiered test selection:

```
### Sprint Change Scope
CHANGED_FILES:
app/src/agents/enrichment.py
app/src/api/status/status_routes.py
scripts/validate.sh
```

(Replace the example files above with the actual output of `git diff --name-only main...HEAD`.)

This checks all 5 domains in parallel: local checks (format, lint, types, tests, DB), CI status, ticket health, staging deployment, and staging browser tests.

**Interpret the report:**
- **All 5 domains PASS** → proceed to Step 2 (epic-specific validation)
- **Any domain FAIL** → do NOT proceed. Create remediation tasks for failures and return to Phase 3. The `/dso:validate-work` report's "Recommended Actions" guides what to fix.
- **Staging test SKIPPED** (staging down) → proceed to Step 2 but note in the final report that staging was not verified

### Step 2: Determine Epic Type (/dso:sprint)

Scan the epic description and child task titles for UI keywords:
- **UI keywords**: `template`, `page`, `route`, `component`, `CSS`, `frontend`, `upload`, `form`, `layout`, `button`, `HTML`, `style`, `responsive`, `modal`, `dialog`
- **Classification**: If any UI keyword found → **UI epic**; otherwise → **backend-only epic**

### Step 3: Gather Changed Files (/dso:sprint)

```bash
git diff --name-only main...HEAD
```

### Step 4: Launch Epic-Specific Validation Sub-Agent (/dso:sprint)

This sub-agent evaluates the epic's quality beyond pass/fail checks — assessing functionality, accessibility, UX (for UI epics), and API contracts (for backend epics).

Launch a Task tool with the appropriate subagent type:
- UI epic: `subagent_type="full-stack-orchestration:test-automator"`
- Backend-only epic: `subagent_type="general-purpose"` (use routing category `test_write` via `discover-agents.sh` to resolve the appropriate agent)

**Validation Agent Prompt**: Read and fill in the externalized prompt template:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Read: $PLUGIN_ROOT/skills/sprint/prompts/epic-validation-review.md
# Placeholders: {title}, {id}, {epic-type}, {repo_root}, {list of files from git diff}
```

### Step 5: Parse Validation Output (/dso:sprint)

Extract the SCORE from the validation agent's output:
- **Score = 5** → Phase 9 (completion)
- **Score < 5** → Phase 8 (remediation)

---

## Phase 8: Remediation Loop (/dso:sprint)

When validation score < 5:

### Reversion Detection

Before creating remediation tasks, invoke `/dso:oscillation-check` as a sub-agent
(`subagent_type="general-purpose"`, `model="sonnet"`) with:
- `files_targeted`: files inferred from the REMEDIATION output
- `context`: remediation
- `epic_id`: the current epic

If it returns OSCILLATION: flag the specific items to the user before creating tasks.
Report which remediation items target files already modified by completed remediation.
If it returns CLEAR: proceed to create tasks normally.

### Step 1: Create Remediation Tasks (/dso:sprint)

For each item in the validation agent's FAIL/REMEDIATION output:

```bash
.claude/scripts/dso ticket create "Fix: {issue description}" -t bug -p 1 --parent=<epic-id>
```

### Step 2: Validate Ticket Health (/dso:sprint)

```bash
.claude/scripts/dso validate-issues.sh
```

### Step 3: Return to Phase 3 (/dso:sprint)

Re-enter the batch planning loop with the new remediation tasks. These tasks will be picked up as ready work and executed in the next batch.

### Safety Bounds

There is no hard limit on the number of batches per session. The loop continues until validation passes or context compaction forces a graceful shutdown.

```
Remediation loop: Score<5 → Create fix tasks → P3 (Batch) → P5 (Execute) → P7 (Re-validate)
  → [score=5] P9 (Complete)
  → [score<5] → Create fix tasks (loop)
  → [context compaction] P9 (Shutdown)
```

---

## Phase 9: Session Close (/dso:sprint)

Phase 9 delegates all completion and shutdown logic to `/dso:end-session`, which handles closing issues, committing, running `merge-to-main.sh` to merge the worktree branch to main, and reporting.

### On Success (Score = 5)

1. Close the epic:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Epic complete: all tasks closed, validation score 5/5"
   .claude/scripts/dso ticket transition <epic-id> open closed
   ```
2. Set sprint context for `/dso:end-session` report:
   - Epic ID and title
   - Total tasks completed this session
   - Validation score: 5/5
3. Invoke `/dso:end-session` with `--bump minor` so that `merge-to-main.sh` performs the minor version bump at merge time rather than on the worktree branch:
   ```
   /dso:end-session --bump minor
   ```
   This passes `--bump minor` through to the `merge-to-main.sh` invocation inside `/dso:end-session`, which increments the minor version and resets patch to 0 as part of the merge commit. If `version.file_path` is not configured in `dso-config.conf`, the flag is a no-op (safe to pass regardless).

### On Graceful Shutdown (Compaction, Failures)

1. Do NOT launch new sub-agents
2. Wait for any running sub-agents to complete
3. Run final validation:
   ```bash
   cd $(git rev-parse --show-toplevel)/app && make test-unit-only
   ```
4. Update ALL in-progress tasks with checkpoint-format progress notes:
   ```bash
   .claude/scripts/dso ticket comment <id> "CHECKPOINT <N>/6: SESSION_END — Progress: <summary>. Next: <what remains>."
   ```
   Use the highest checkpoint number actually reached (e.g., `CHECKPOINT 3/6` if tests were written but implementation not started). This enables `/dso:sprint --resume` to recover from the correct substep.
5. Set sprint context for `/dso:end-session` report:
   - Tasks completed this session
   - Tasks remaining (with IDs and titles)
   - Resume command: `/dso:sprint <epic-id> --resume`
6. Invoke `/dso:end-session`

---

## Quick Reference

| Phase | Purpose | Key Commands |
|-------|---------|-------------|
| 1 | Select epic | `sprint-list-epics.sh --all`, `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket deps` |
| 1b | Preplanning gate | `.claude/scripts/dso ticket deps`, `/dso:preplanning` (if 0 children or ambiguous) |
| 2 | Analyze tasks | `.claude/scripts/dso ticket deps`, `.claude/scripts/dso ticket list`, `.claude/scripts/dso ticket show` |
| 2b | Implementation planning gate | `.claude/scripts/dso ticket deps <story>`, `/dso:implementation-plan` (if story has 0 impl tasks) |
| 3 | Plan batches | Priority classification, batch sizing |
| 4 | Pre-batch checks | Session usage check, counter files, git status, db-status |
| 5 | Launch agents | Task tool with structured prompts |
| 6 | Post-batch | persistence check, REVIEW-WORKFLOW.md, COMMIT-WORKFLOW.md, push, context check (→ `/compact` if >=70%), continuation decision |
| 7 | Validate | CI verification (SHA-based), full E2E tests, `/dso:validate-work` (all domains), then epic-specific scoring |
| 8 | Remediation | Create fix tasks, re-enter loop |
| 9 | Session close | `/dso:end-session` (close issues, commit, merge, report) |

## Error Recovery

| Situation | Action |
|-----------|--------|
| Sub-agent fails | Revert task to open, record failure in notes, continue batch |
| All sub-agents fail | Log failures, graceful shutdown, do not retry in same session |
| Validation agent fails to run | Skip validation, report to user, recommend manual review |
| DB not running for E2E | Ask user to run `make db-start`, wait for confirmation |
| CI fails at Phase 7 | Dispatch `error-debugging:error-detective` sub-agent (model: `sonnet`) to diagnose and fix per test-failure-dispatch protocol, commit+push, restart Phase 7 Step 0.5a; if still failing after one attempt, graceful shutdown |
| Git push fails | Report error, suggest `git pull --rebase`, never force-push |
| Ticket health < 5 after ops | Fix ticket issues before continuing (see `/dso:tickets-health`) |
| Epic has 0 children | Preplanning gate triggers `/dso:preplanning` automatically |
| Story has 0 impl tasks and isn't simple | Implementation planning gate triggers `/dso:implementation-plan` per story |
| `/dso:implementation-plan` needs clarification | Present questions to user, persist answers to story description, resume |
| Context >=70% between batches | Run `context-check`, write intent file, invoke `/compact`, continue to P3 (voluntary — all work committed) |
| Involuntary context compaction detected | Immediate graceful shutdown — do not launch more batches |
