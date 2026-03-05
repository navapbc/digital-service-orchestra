---
name: sprint
description: Execute Epic - Multi-Agent Orchestration
user-invocable: true
---

# Execute Epic: Multi-Agent Orchestration

Automate the full lifecycle of a ticket epic: task analysis, batched sub-agent execution, post-epic validation, and remediation loop.

> **Worktree Compatible**: All commands use dynamic path resolution and work from any worktree.

## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/lockpick-workflow}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
VALIDATE_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.validate)
VISUAL_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_visual)
E2E_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_e2e)
```

Resolution order: See `lockpick-workflow/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — replaces `make test-unit-only` in post-batch and remediation validation
- `LINT_CMD` — replaces `make lint` in validation steps
- `VALIDATE_CMD` — replaces `scripts/validate.sh --ci` call in Phase 1
- `VISUAL_CMD` — replaces `make test-visual` in post-batch checks
- `E2E_CMD` — replaces `make test-e2e` in post-batch checks

## Usage

```
/sprint                     # Interactive epic selection
/sprint <epic-id>           # Execute specific epic
/sprint <epic-id> --dry-run # Plan batches without executing
/sprint <epic-id> --resume  # Resume interrupted epic
```

## Orchestration Flow

```
Flow: P1 (Init) → Preplanning Gate
  → [0 children/ambiguous] /preplanning → P2
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

## Phase 1: Initialization & Epic Selection (/sprint)

### Create Pre-Loop Progress Checklist

Call `TodoWrite` with the following items before doing any other work. This shows the user what setup steps will be completed before batch execution begins:

```
[ ] Select and validate epic
[ ] Run validation gate (validate.sh --ci)
[ ] Epic complexity evaluation (SIMPLE / MODERATE / COMPLEX routing)
[ ] Preplanning gate (lightweight, full, or skip based on routing)
[ ] Gather tasks and build dependency graph
[ ] Implementation planning gate (run /implementation-plan per story if needed — skipped for SIMPLE/MODERATE)
```

Mark each item `in_progress` when starting it and `completed` when done. This list is replaced entirely when the batch loop begins (Phase 3).

> **IMPORTANT**: Use ONLY `TodoWrite`/`TodoRead` for this checklist — do NOT use `TaskCreate`. The `TaskCreate` tool creates independent spinner tasks that persist across `TodoWrite` calls and will NOT be cleared when Phase 3 replaces the checklist. If you accidentally created `TaskCreate` tasks for pre-loop tracking, complete them via `TaskUpdate(status='completed')` before Phase 3 begins.

### Parse Arguments

- `<epic-id>`: The ticket epic to execute
- `--dry-run`: Output batch plan without executing any sub-agents
- `--resume`: Resume an interrupted epic (skip to Phase 3 with recovery)

### If No Epic ID Provided

1. Run the epic discovery script:
   ```bash
   $(git rev-parse --show-toplevel)/scripts/sprint-list-epics.sh --all
   ```
   This outputs tab-separated lines in three categories:
   - `<id>\tP*\t<title>` for in-progress epics (listed first, `P*` replaces priority)
   - `<id>\tP<priority>\t<title>` for unblocked open epics
   - `BLOCKED\t<id>\tP<priority>\t<title>` for blocked ones (with `--all`)

   Exit codes:
   - Exit code 1 → no open epics exist, report and exit
   - Exit code 2 → all open epics are blocked; display the BLOCKED-prefixed lines from stdout as context, then exit
2. Parse the output and print a numbered list to the user. Lines with `P*` are
   in-progress epics — number them first. Then number unblocked lines. Display
   blocked epics below as informational context, not as selectable options:
   ```
   In-progress epics:

     1. [P*] <title> (<epic-id>) ← resumable

   Unblocked epics (sorted by priority):

     2. [P0] <title> (<epic-id>)
     3. [P1] <title> (<epic-id>)
     4. [P2] <title> (<epic-id>)
     ...

   Blocked epics (not selectable):
     - [P2] <title> (<epic-id>)
   ```
3. Ask the user: "Enter the number or epic ID to execute:" and wait for their text input
4. Map the user's response (number or epic ID) back to the corresponding epic and proceed

### Validate Epic

1. Run `tk show <epic-id>` — confirm it is type `epic` and status is `open` or `in_progress`
2. Run `tk dep tree <epic-id>` — if 100% complete, skip to Phase 7 (validation)
3. Mark epic in-progress: `tk status <epic-id> in_progress`
4. Mark the **Select and validate epic** todo item `completed`.

### Context Efficiency Rules

**Status checks**: Use `$REPO_ROOT/scripts/issue-summary.sh <id>` or `tk ready` for orchestrator status checks (is it done? what's blocking?). Reserve full `tk show <id>` only when sub-agents need to read their complete task context.

**Ticket-as-prompt**: Sub-agents read their own task context via `tk show` instead of receiving it inline. Before dispatch, run the quality gate:
```bash
$REPO_ROOT/scripts/issue-quality-check.sh <id>
```
- **Exit 0** (quality pass): Use the ticket-as-prompt template (`task-execution.md`) — sub-agent reads its own context
- **Exit 1** (too sparse): Fall back to inline prompt — orchestrator runs `tk show <id>` and includes output in the Task prompt

**Writing quality ticket**: When creating tasks for sub-agent execution, include:
- Concrete file paths (`src/`, `tests/`)
- Acceptance criteria with keywords: "must", "should", "Given/When/Then"
- At least 5 lines of description
This ensures `issue-quality-check.sh` passes and sub-agents can self-serve their ticket context.

### If `--resume` Flag

1. Run `tk ready` and filter for in-progress tasks under `<epic-id>` for interrupted tasks
2. For each in-progress task, run `tk show <id>` and parse its notes for CHECKPOINT lines
3. Apply checkpoint resume rules:
   - **CHECKPOINT 6/6 ✓** — task is fully done; fast-close: verify files exist, then `tk close <id> --reason="Fixed: <summary>"`
   - **CHECKPOINT 5/6 ✓** — near-complete; fast-close: spot-check files and close without re-execution
   - **CHECKPOINT 3/6 ✓ or 4/6 ✓** — partial progress; re-dispatch with resume context: include the highest checkpoint note in the sub-agent prompt so it can continue from that substep
   - **CHECKPOINT 1/6 ✓ or 2/6 ✓** — early progress only; revert to open with `tk status <id> open` for full re-execution
   - **No CHECKPOINT lines or malformed CHECKPOINT lines** — revert to open: `tk status <id> open`
4. Fallback rule: if CHECKPOINT lines are present but ambiguous (missing ✓, duplicate numbers, non-sequential), treat as malformed → revert to open
5. Proceed to Phase 3

### Run Validation Gate

Run `validate.sh --ci` to populate the validation state file. This allows sub-agents to use Edit/Write/Bash without being blocked by the validation gate hook.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$REPO_ROOT/lockpick-workflow/scripts/validate.sh --ci
```

**Bash timeout**: Use `timeout: 600000` (10 minutes — the TaskOutput hard cap). The smart CI wait in validate.sh can poll for up to 15 minutes, but the TaskOutput tool caps at 600000ms; use `|| true` and check the state file for CI results if the call times out.

**If validation fails**: Run `/debug-everything` to fix all failures before continuing with the sprint. Do NOT proceed to the Preplanning Gate until validation passes.

### Preplanning Gate

After the epic is validated and counters are initialized, check whether the epic is ready for execution or needs decomposition first.

#### Step 1: Check for Existing Children (/sprint)

```bash
tk dep tree <epic-id>
```

Count the number of child tasks returned.

- **If children exist**: proceed to Step 2a (Existing Children Readiness Check)
- **If zero children**: proceed to Step 2b (Epic Complexity Evaluation)

#### Step 2a: Existing Children Readiness Check (/sprint)

This is the existing readiness check — unchanged. It applies only when the epic already has children.

**Trigger `/preplanning` (full mode) if ANY of the following are true:**

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
1. Log: `"Epic has ambiguous tasks — running /preplanning to decompose before execution."`
2. Invoke `/preplanning <epic-id>` (full mode)
3. After preplanning completes, continue to Phase 2

If no trigger condition is met, proceed directly to Phase 2.

#### Step 2b: Epic Complexity Evaluation (/sprint)

When the epic has zero children, dispatch a haiku sub-agent to classify the epic's complexity before deciding the decomposition path.

**Dispatch the evaluator:**

Use the Task tool with `model: "haiku"` and the prompt content from `$(git rev-parse --show-toplevel)/.claude/skills/sprint/prompts/epic-complexity-evaluator.md`. Pass the epic ID as argument.

**Route based on classification:**

| Classification | Confidence | Route |
|---------------|------------|-------|
| SIMPLE | high | Step 3a (Direct Implementation Planning) |
| SIMPLE | medium | Treat as MODERATE |
| MODERATE | high | Step 3b (Lightweight Preplanning) |
| MODERATE | medium | Treat as COMPLEX |
| COMPLEX | any | Step 3c (Full Preplanning) |

Log the classification: `"Epic <id> classified as <CLASSIFICATION> (confidence: <confidence>) — routing to <path>."`

#### Step 3a: Direct Implementation Planning (SIMPLE epics) (/sprint)

The epic's requirements are clear and the scope is small. Skip preplanning entirely and run `/implementation-plan` directly on the epic.

1. Log: `"Epic <id> classified as SIMPLE — running /implementation-plan directly on epic."`
2. Dispatch `/implementation-plan` sub-agent via Task tool:
   - Read the prompt template from `$(git rev-parse --show-toplevel)/.claude/skills/sprint/prompts/impl-plan-dispatch.md`
   - Fill `{story-id}` with the **epic ID** (not a story ID — /implementation-plan handles epic type detection)
   - Fill `{evaluator-context}` with the epic complexity evaluator JSON output
   - Launch with `subagent_type="general-purpose"` and `model="sonnet"`
3. Parse sub-agent return value using the same STATUS protocol as Phase 2's Implementation Planning Gate
4. Set `epic_routing = "SIMPLE"` — this flag tells Phase 2 to skip the Implementation Planning Gate
5. Continue to Phase 2

#### Step 3b: Lightweight Preplanning (MODERATE epics) (/sprint)

The epic needs scope clarification but is a single concern — enrich the epic without creating stories.

1. Log: `"Epic <id> classified as MODERATE — running /preplanning --lightweight for scope clarification."`
2. Invoke `/preplanning <epic-id> --lightweight`
3. Parse the result:

**On `ENRICHED`:**
- Log: `"Lightweight preplanning complete — epic enriched with done definitions. Running /implementation-plan on epic."`
- Dispatch `/implementation-plan` sub-agent (same as Step 3a, step 2)
- Set `epic_routing = "MODERATE"`
- Continue to Phase 2

**On `ESCALATED`:**
- Log: `"Lightweight preplanning escalated to full mode — reason: <reason>. Running full /preplanning."`
- Invoke `/preplanning <epic-id>` (full mode, no --lightweight flag)
- Set `epic_routing = "COMPLEX"`
- Continue to Phase 2

#### Step 3c: Full Preplanning (COMPLEX epics) (/sprint)

The epic needs structural decomposition into stories. This is the current behavior, unchanged.

1. Log: `"Epic <id> classified as COMPLEX — running /preplanning for full story decomposition."`
2. Invoke `/preplanning <epic-id>`
3. After preplanning completes, set `epic_routing = "COMPLEX"`
4. Continue to Phase 2

---

## Phase 2: Task Analysis & Dependency Graph (/sprint)

### Gather Tasks

1. `tk dep tree <epic-id>` — get all child tasks
2. `tk ready` (filtered by parent) — get unblocked tasks ready to work
3. `tk show <id>` for each ready task to read full descriptions

### Implementation Planning Gate

After gathering tasks, check whether any ready stories need implementation task decomposition before they can be executed by sub-agents.

#### Pre-check: Skip for SIMPLE/MODERATE Routing (/sprint)

If `epic_routing` is `"SIMPLE"` or `"MODERATE"` (set in Phase 1's Preplanning Gate), skip the entire Implementation Planning Gate and proceed directly to **Classify Tasks** below. Tasks were already created as direct children of the epic by `/implementation-plan` — there is no story layer to decompose.

Log: `"Skipping Implementation Planning Gate — epic was routed as <epic_routing>, tasks already exist under epic."`

#### Step 1: Identify Stories Needing Implementation Planning (/sprint)

For each ready task from `tk ready` (filtered by parent):
1. Run `tk dep tree <task-id>` to check if the story already has child implementation tasks
2. If it has children → **skip** (already planned)
3. If it has zero children → run the complexity evaluator:

**Dispatch a haiku complexity-evaluator sub-agent** to classify the story. Use the Task tool with `model: "haiku"` and the prompt content from `$(git rev-parse --show-toplevel)/.claude/skills/sprint/prompts/complexity-evaluator.md`. Pass the story ID as argument.

**Routing based on classification:**

| Classification | Confidence | Action |
|---------------|------------|--------|
| TRIVIAL | high | Skip `/implementation-plan` — log: `"Story <id> classified as TRIVIAL — skipping /implementation-plan"` |
| TRIVIAL | medium | Treat as COMPLEX (medium confidence = plan) |
| COMPLEX | any | Run `/implementation-plan` — pass evaluator output as context (see Step 2) |

**When in doubt, the evaluator defaults to COMPLEX** — medium confidence always routes to `/implementation-plan`. The cost of an unnecessary `/implementation-plan` is low; the cost of a sub-agent floundering without a plan is high.

#### Dependency Layer Stratification (/sprint)

Before dispatching any `/implementation-plan` sub-agents, group the stories that need decomposition into topological layers based on their intra-sprint dependencies. This ensures that stories with blockers are planned after the stories they depend on.

**Step A: Collect intra-sprint dependency edges**

For each story in the needs-planning list:
1. Run `tk show <story-id>` and read the `DEPENDS ON` field
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

#### Step 2: Run Implementation Planning (/sprint)

Process stories in layer order — Layer 0 first, then Layer 1, etc. Within each layer, dispatch up to 3 concurrent `/implementation-plan` sub-agents in a single message (same parallel-dispatch pattern as Phase 5 sub-agent launch). Wait for all sub-agents in the layer to return before processing the next layer.

**For each layer (in order Layer 0, Layer 1, ...):**

a. Filter to stories in this layer that need decomposition
b. Dispatch up to 3 concurrent Task tool calls in a single message — fill the `impl-plan-dispatch.md` prompt template for each story:
   - `{story-id}` → the story's ticket ID
   - `{evaluator-context}` → complexity-evaluator JSON if available; otherwise `""`
   - `{answers-context}` → empty string `""` (no prior questions on first dispatch)
   - Launch using the Task tool with `subagent_type="general-purpose"` and `model="sonnet"`
   - Log: `"Story <id> has no implementation tasks — running /implementation-plan to decompose."`
c. Wait for all sub-agents in the layer to return before proceeding to the next layer
d. For each sub-agent result, **parse STATUS:**
   - On `STATUS:complete TASKS:<ids> STORY:<id>`:
     - Extract the comma-separated task IDs from the `TASKS` field
     - Extract the story ID from the `STORY` field
     - Log: `"Implementation planning complete for story <story-id> — created tasks: <task-ids>"`
     - Proceed to post-dispatch validation (step e)
   - On `STATUS:blocked QUESTIONS:<json-array>`:
     - **Add to blocked-stories list** — do not ask the user inline; collect all `STATUS:blocked` results from this layer batch and present them together after the full layer batch completes (see step d-collect below)
   - **Fallback — if no STATUS line in sub-agent output:**
     - Run `tk dep tree <story-id>` to check whether tasks were created
     - If children exist → treat as success; log a warning: `"WARNING: sub-agent returned no STATUS line for story <id>, but tk dep tree shows tasks — continuing"`; proceed to post-dispatch validation
     - If no children → retry the sub-agent dispatch once (same prompt, same parameters)
     - If retry also produces no children → revert story to open (`tk status <story-id> open`); log: `"ERROR: /implementation-plan sub-agent failed for story <id> after retry — story reverted to open"`; skip to next story
d-collect. **Collect and present blocked-layer stories** — after the full layer batch completes, for each story with `STATUS:blocked`:
   - **Parse the QUESTIONS field**: Extract the JSON array from the `STATUS:blocked` line. If parsing fails (malformed JSON) or the array is empty (`[]`), treat as a sub-agent failure:
     - Revert the story to open: `tk status <story-id> open`
     - Log: `"ERROR: /implementation-plan returned STATUS:blocked with no parseable questions for story <story-id> — story reverted to open"`
     - Remove story from blocked-stories list
   - **Present all remaining blocked stories' questions to the user at once** — separate by `kind` field:
     ```
     /implementation-plan needs clarification for story <story-id>:

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
     # Append clarifications to the ticket file directly
     TICKET_FILE=$(find .tickets/ -name "*<story-id>*" -print -quit)
     cat >> "$TICKET_FILE" << 'CLARIFICATIONS'

     ---
     ## Clarifications (from sprint orchestrator)

     Q1: <question 1 text>
     A1: <user answer 1>

     Q2: <question 2 text>
     A2: <user answer 2>
     ...
CLARIFICATIONS
     ```
   - **Re-dispatch the sub-agent**: Call the Task tool again with the same `impl-plan-dispatch.md` prompt template, filling:
     - `{story-id}` → same story ID
     - `{evaluator-context}` → same evaluator context as the first dispatch (or `""` if none)
     - `{answers-context}` → inline Q&A formatted as:
       ```
       Q: <question 1 text>
       A: <user answer 1>

       Q: <question 2 text>
       A: <user answer 2>
       ```
   - **If the re-dispatched sub-agent returns `STATUS:blocked` again**: Do not ask the user a second time. Treat as failure: revert story to open (`tk status <story-id> open`), log `"ERROR: /implementation-plan returned STATUS:blocked twice for story <story-id> — story reverted to open"`, and skip to the next story.
e. **Post-layer-batch ticket validation** — after all stories in the layer are resolved (complete, blocked-and-resolved, or failed), run:
   ```bash
   $(git rev-parse --show-toplevel)/scripts/validate-issues.sh --quick --terse
   ```
   Log any warnings but do not block on non-critical results
f. Re-run `tk ready` (filtered by parent) to pick up newly created implementation tasks before processing the next layer

#### Step 3: Continue to Classification (/sprint)

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
1. Run `tk blocked` to identify blocking chain
2. Report which tasks are blocked and by what
3. Exit with recommendation

---

## Phase 3: Batch Planning (/sprint)

### Pre-Batch Cleanup

Before building the Batch 1 checklist, clear any lingering TaskCreate items from the pre-loop phase:

1. Run `TaskList` to check for pending/in_progress/completed tasks from the pre-loop phase
2. For each task that is NOT a batch work item: `TaskUpdate(taskId=<id>, status='deleted')`
3. Then proceed with the batch TodoWrite below

### Initialize Batch Progress Checklist

> **CHECKLIST RESET**: Always call `TodoWrite` at the start of Phase 3 for EACH new batch
> (Batch 1, Batch 2, etc.). This replaces the previous batch's checklist. If you are
> starting Batch N and the checklist still shows Batch N-1 items, call TodoWrite immediately
> before doing any other Phase 3 work.
>
> **IMPORTANT**: Use ONLY `TodoWrite` for batch checklist management — do NOT use `TaskCreate`
> alongside it. `TaskCreate` tasks persist independently across `TodoWrite` calls and are NOT
> cleared when `TodoWrite` replaces the checklist. If you previously created `TaskCreate` tasks
> for batch tracking, complete them via `TaskUpdate(status='completed')` before calling
> `TodoWrite` for the new batch. At the START of EACH new batch, call `TodoWrite` to replace
> the ENTIRE checklist with the new batch's tasks.

Call `TodoWrite` to replace any existing checklist with the current batch's items. Replace `N` with the current batch number (1, 2, 3...). Calling `TodoWrite` replaces the previous list entirely — no accumulation across batches.

```
[ ] Batch N — Plan (sprint-next-batch.sh)
[ ] Batch N — Pre-batch checks (session usage, git clean, db status)
[ ] Batch N — Claim tasks (tk status in_progress)
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

### Compose Batch

Run the deterministic batch selector. It handles story-level blocking, task
dependencies, file-overlap detection, classification, and the opus cap in one call —
the orchestrator receives everything needed to launch sub-agents directly:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$REPO_ROOT/scripts/sprint-next-batch.sh <epic-id> --limit=<max_agents>
```

- **`max_agents`**: Use 5 initially. Phase 4's pre-check may truncate to 1 if session
  usage is >90% — in that case re-run with `--limit=1` (or manually discard extras).
- **Omit `--limit`**: Returns the full non-conflicting pool (useful for `--dry-run`).

#### Output format

Each `TASK:` line is tab-separated with all fields the orchestrator needs to launch
the sub-agent — **no further `tk show` or `classify-task.sh` calls required**:

```
TASK: <id>  P<tk-priority>  <issue-type>  <model>  <subagent-type>  <class>  <title>  [story:<id>]
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
  the next cycle. No `tk dep` is needed — the task reappears as ready naturally.
- **Classification**: Each TASK line includes `model`, `subagent`, and `class` from
  `classify-task.py` — sorted by classify priority (interface-contract first, then
  fan-out-blocker, then independent, then db-dependent), then ticket priority.
- **Opus cap**: At most 2 `model=opus` tasks per batch. Additional opus tasks are
  reported as `SKIPPED_OPUS_CAP` and deferred; freed slots are filled by non-opus tasks
  in priority order.

#### Exit condition

If `BATCH_SIZE: 0`, run `tk blocked` to surface the blocking
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

## Phase 4: Pre-Batch Checks (/sprint)

Before launching each batch, run the shared pre-batch check script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$REPO_ROOT/scripts/agent-batch-lifecycle.sh pre-check       # standard
$REPO_ROOT/scripts/agent-batch-lifecycle.sh pre-check --db  # if batch includes DB-dependent tasks
```

The script outputs structured key-value pairs:
- `MAX_AGENTS: 1 | 5` — use as `max_agents`
- `SESSION_USAGE: normal | high`
- `GIT_CLEAN: true | false` — if false, commit previous batch first
- `DB_STATUS: running | stopped | skipped` — if stopped, ask user to start DB

Exit 0 means all checks pass. Exit 1 means at least one check requires action (details in output).

**Batch size limit**: Launch at most 5 Task calls in a single message. All foreground Tasks block until they return — you cannot exceed the limit mid-flight. Before each batch, verify: how many tasks am I about to launch? If > 5, split into multiple batches.

When `max_agents=1`, re-run `sprint-next-batch.sh <epic-id> --limit=1` to get a
single-task batch. Log: `"Session usage >90%, limiting to 1 sub-agent."`

### Claim Tasks

For each task in the batch:
```bash
tk status <id> in_progress
```

---

## Phase 5: Sub-Agent Launch (/sprint)

Launch up to `max_agents` sub-agents (1 or 5, determined in Phase 4) via the Task tool. Each sub-agent gets a structured prompt:

### Sub-Agent Prompt Template

For each task, launch a Task with the appropriate `subagent_type` (use `general-purpose` for most code tasks, or a specialized type if the task clearly matches one).

**Quality gate (ticket-as-prompt)**: Before dispatch, run the quality check:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$REPO_ROOT/scripts/issue-quality-check.sh <task-id>
```

- **Exit 0 (quality pass)**: Use the ticket-as-prompt template — read `$REPO_ROOT/.claude/skills/sprint/prompts/task-execution.md` and fill in `{id}` only. The sub-agent reads its own full context via `tk show`.
- **Exit 1 (too sparse)**: Fall back — run `tk show <id>`, then include the full description inline in the prompt alongside the template instructions.

**Acceptance criteria gate**: After the quality gate, run:
```bash
$REPO_ROOT/scripts/check-acceptance-criteria.sh <task-id>
```

- **Exit 0**: Proceed with dispatch — task has structured AC block
- **Exit 1**: Do NOT dispatch. Read `.claude/docs/ACCEPTANCE-CRITERIA-LIBRARY.md`, compose an
  appropriate acceptance criteria block for the task, and add it by editing `.tickets/<id>.md` directly to insert an `## ACCEPTANCE CRITERIA` section.
  Re-run the check. If criteria cannot be determined (ambiguous task type), halt and ask the user.

### Subagent Type and Model Selection

Use the `model` and `subagent` fields from the `TASK:` lines produced by
`sprint-next-batch.sh` in Phase 3 — **no additional classify-task.sh call needed**.

When launching each Task tool call, set:
- `subagent_type` = the `subagent` field from the TASK line
- `model` = the `model` field from the TASK line

**Skill-guided tasks**: If classification `class` is `"skill-guided"`, append to
the sub-agent prompt: `"Before implementing, check if a skill applies to this task
type (e.g., /writing-skills for skill files, /claude-md-improver for CLAUDE.md
updates, /writing-rules for hookify rules)."` The sub-agent uses its judgment to
invoke the appropriate skill based on the task content.

**Important**: Launch ALL sub-agents in the batch within a single message (parallel tool calls). Do not launch them sequentially. Maximum 5 Task calls per message — all foreground Tasks return before the next batch, so you cannot exceed the limit mid-flight.

**Worktree boundary**: If running in a worktree session, append to every sub-agent prompt: `"IMPORTANT: Only modify files under $(git rev-parse --show-toplevel). Do NOT write to any other path."` The PreToolUse edit guard only blocks Edit/Write tools — Bash commands bypass it.

---

## Phase 6: Post-Batch Processing (/sprint)

After ALL sub-agents in the batch return, follow the Orchestrator Checkpoint Protocol from CLAUDE.md.

### Step 1: Verify Results (/sprint)

For each sub-agent, check the Task tool result:
- Did it report success?
- Are the expected files present? (spot-check with Glob)
- Were tests passing?

### Step 1b: Integrate Discovered Tasks (/sprint)

For each sub-agent result, check the `TASKS_CREATED` line:
- If `none` → skip
- If `error: <reason>` → log the error, no action needed
- If task IDs listed (e.g., `ticket-042, ticket-043`):
  1. Run `tk show <id>` for each created task to review title and description
  2. Wire dependencies via `tk dep` if the new task blocks or is blocked by existing work
  3. Log: "Sub-agent for <task-id> discovered N new tasks: <ids>"

After processing all sub-agents in the batch, if any tasks were created:
```bash
$(git rev-parse --show-toplevel)/scripts/validate-issues.sh --quick --terse
```

Newly created tasks require no special handling beyond this step — they naturally
enter the next P3→P5→P6 batch cycle when the orchestrator loops back to Phase 3
(Batch Planning) for remaining work.

### Step 2: Acceptance Criteria Validation (/sprint)

**Batched shared criteria** (run ONCE per batch, not per-task):
Universal criteria (test, lint, format) are already verified by Step 4
(validate-phase.sh post-batch). Do not re-run per task.

**Per-task structural criteria**:
For each task in the batch, extract the `ACCEPTANCE CRITERIA` block from `tk show <id>` output
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

### Step 3: File Overlap Check (Safety Net) (/sprint)

Sub-agents may modify files beyond what their task description predicts. Check for
actual conflicts before committing:

1. For each sub-agent, collect its modified files from the Task result
2. Run the overlap detection script:
   ```bash
   $REPO_ROOT/scripts/agent-batch-lifecycle.sh file-overlap \
     --agent=<task-id-1>:<file1>,<file2> \
     --agent=<task-id-2>:<file3>,<file4>
   ```
   The script outputs `CONFLICTS: <N>` followed by one `CONFLICT:` line per overlap.
   Exit 0 = no conflicts, exit 1 = conflicts detected.
3. If conflicts are detected, resolution (same protocol as `/debug-everything` Phase 6 Step 1a):
   a. Identify the primary agent for each conflicting file (highest priority)
   b. Revert ALL secondary agents' changes to conflicting files
   c. Re-run secondary agents one at a time in priority order (not parallel),
      each with original prompt + Conflict Resolution Context (captured diff,
      instruction to respect current file state). Commit after each re-run.
   d. After each re-run: if agent only touched non-conflicting files -> merge OK.
      If it re-modified the same conflicting files -> escalate to user.
4. If no conflicts -> proceed to Step 4

### Step 4: Run Validation (/sprint)

```bash
$(git rev-parse --show-toplevel)/scripts/validate-phase.sh post-batch
```

If validation fails, identify which sub-agent's code is broken and note it.

### Step 5: Persistence Coverage Check (/sprint)

If any task in the batch touched persistence-critical files (job_store, document_processor,
DB models, DB clients), run the persistence coverage check:

```bash
$REPO_ROOT/scripts/check-persistence-coverage.sh
```

If the check fails:
1. Log: `"Persistence coverage check failed — persistence source changed without test coverage."`
2. **Do not commit.** Instead:
   a. If a sub-agent was responsible for the persistence change, re-run it with an updated prompt
      requiring a persistence test (DB round-trip or cross-worker test).
   b. If the persistence change was made by the orchestrator, write the missing test directly.
3. After adding the test, re-run the check and proceed only when it passes.

### Step 6: Visual Verification (UI tasks only) (/sprint)

If any task in the batch modified templates, CSS, or frontend code:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT/app && make test-visual 2>&1
```

- **Pass** → Log: "Visual regression tests pass — MCP visual verification skipped."
- **Fail** → Use `/playwright-debug` starting at the Visual Regression Gate (Tier 2 targeted investigation of flagged elements). If verification fails, revert the task to open.
- **No baselines** → Use `/playwright-debug` full 3-tier process. Verify local env first: `$REPO_ROOT/scripts/check-local-env.sh`. Never skip Playwright validation without user approval.

### Step 7: Formal Code Review (/sprint)

Execute the review workflow (REVIEW-WORKFLOW.md). If you have already read this file earlier in this conversation and have not compacted since, use the version in context. This produces a formal review state file with diff hash and scores at `$(get_artifacts_dir)/review-status` (computed by `get_artifacts_dir()` in `hooks/lib/deps.sh`). (Note: the commit workflow's review gate finds this state file and skips re-review.)

**Snapshot exclusion**: When generating the diff files for review (Steps 0 and 2 of REVIEW-WORKFLOW.md), exclude snapshot baseline files from the diff so reviewers focus on code changes:
```bash
{ git diff --staged -- ':!app/tests/e2e/snapshots/*.png' ':!app/tests/unit/templates/snapshots/*.html'; git diff -- ':!app/tests/e2e/snapshots/*.png' ':!app/tests/unit/templates/snapshots/*.html'; } > "$DIFF_FILE"
# Guard: if diff is empty after exclusion (snapshot-only batch), fall back to full diff
# so verify-review-diff.sh doesn't reject the empty file. The reviewer ignores binary PNGs.
[ -s "$DIFF_FILE" ] || { git diff --staged; git diff; } > "$DIFF_FILE"
[ -s "$DIFF_FILE" ] || git diff HEAD~1 > "$DIFF_FILE"
git diff HEAD --stat -- ':!app/tests/e2e/snapshots/*.png' ':!app/tests/unit/templates/snapshots/*.html' > "$STAT_FILE"
```

**Interpret results:**
- **No Critical or Important issues** (all scores >= 4) → proceed to Step 8
- **Critical issues found** → revert the responsible sub-agent's task to open, add
  the issue details to the task notes, and re-run it with the reviewer's feedback
  appended to the prompt. Re-execute REVIEW-WORKFLOW.md after the fix.
- **Important issues found** → fix directly (small changes) or re-run the sub-agent
  with feedback. Re-execute REVIEW-WORKFLOW.md after the fix.
- **Minor issues only** → proceed (note them in ticket but don't block)
- **Review uses autonomous resolution per batch.** The review workflow handles up to 2 fix/defend attempts automatically before escalating. The resolution loop is split: a resolution sub-agent applies fixes (returns `FIXES_APPLIED`), then the orchestrator dispatches a separate re-review sub-agent. This avoids two-level nesting (orchestrator → resolution → re-review) which causes `[Tool result missing due to internal error]`. See REVIEW-WORKFLOW.md Autonomous Resolution Loop. If issues persist after escalation, report to user and proceed to commit (CI and Phase 7 validation provide additional gates).

### Step 8: Update Ticket Notes (/sprint)

For each task in the batch, write checkpoint-format notes for crash recovery:

| Outcome | Command |
|---------|---------|
| Success | `tk add-note <id> "CHECKPOINT 6/6: Done ✓ — Files: <files created/modified>. Tests: pass."` |
| Failure | `tk add-note <id> "CHECKPOINT <N>/6: Failed — <error summary>. Files modified: <files>. Resume from: <what remains>."` |

The checkpoint number on failure should reflect the last successfully completed substep (e.g., if tests passed but implementation failed, use `CHECKPOINT 4/6`).

### Step 9: Handle Failures (/sprint)

For tasks that failed:
- Revert to open: `tk status <id> open`
- Record the failure reason in notes (already done in Step 8)

### Step 10: Commit & Push (/sprint)

Read and execute `$REPO_ROOT/lockpick-workflow/docs/workflows/COMMIT-WORKFLOW.md`. The review gate check
in Step 5 of the commit workflow will find the review state file from Step 7 is already
current, so review is skipped (no double review).

After the commit completes, merge to main using `merge-to-main.sh` (handles ticket sync, merge, and push in one step — avoids review-gate and pre-push hook issues from ticket file changes on main):

```bash
"$REPO_ROOT/scripts/merge-to-main.sh"
```

Do NOT use `git push` directly — it only pushes the worktree branch and does not merge to main.

**After completion, continue with Step 11 below.** Do not stop here.

> **CONTROL FLOW WARNING**: After the commit workflow and `merge-to-main.sh` complete, continue
> IMMEDIATELY with Step 11 (Context Compaction Check). Do NOT use the `/commit` Skill tool
> here — read and execute COMMIT-WORKFLOW.md inline to avoid nested skill invocations that
> may not return control. If you find yourself waiting for user input after pushing, you are
> experiencing a known control-flow regression (project-specific-bug-id). Type "continue"
> mentally and proceed directly to Step 11.

### Step 11: Context Compaction Check (/sprint)

Between batches — after all work is committed and pushed — check whether the session context is at least 70% capacity. **This is the safe window for compaction**: all sub-agents have returned, work is committed and pushed, and ticket tracks task state. Compacting mid-batch would risk losing in-flight sub-agent context.

Run the context check:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
context_exit=0
$REPO_ROOT/scripts/agent-batch-lifecycle.sh context-check || context_exit=$?
# context_exit: 0=low, 10=medium, 11=high
```

| Output | Exit Code | Meaning | Action |
|--------|-----------|---------|--------|
| `CONTEXT_LEVEL: low` | 0 | <70% usage | Proceed to Step 13 normally |
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
5. The PreCompact hook fires automatically: it captures active ticket tasks, git state, and auto-commits any remaining uncommitted work as a safety checkpoint
6. After compaction, the recovery summary is injected into the new context. Check for `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>` (using the epic ID from the log/recovery summary). **Continue directly to Phase 3** — ticket task state and git history are intact. Do NOT go to Phase 9.
7. **Agent-count after compact (`high` case)**: If context was at `high` (>90%), Phase 4's pre-check re-runs `check-session-usage.sh` for the next batch. If it still signals high, Phase 4 will set `MAX_AGENTS: 1` automatically. No special action is needed in this step — Phase 4 handles it.

**Why this is safe**: Unlike involuntary mid-work compaction, this checkpoint happens after commit+push. The PreCompact hook's auto-commit is a belt-and-suspenders safety net, not the primary save mechanism.

---

### Step 13: Continuation Decision (/sprint)

```
Decision: Involuntary compaction detected? → Yes: P9 (Graceful Shutdown)
          → No: More ready tasks? → Yes: Return to P3
                                  → No: P7 (Validation)
```

**Distinguishing involuntary from voluntary compaction**: After a voluntary compact (Step 7b), the file `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>` exists. Delete it and continue to Phase 3. If you see recovery state injected into context but no intent file exists, the compaction was involuntary (Claude Code triggered it automatically while the session was in the middle of work) — go to Phase 9.

- If **involuntary** context compaction has occurred (no intent file) → Phase 9 (graceful shutdown)
- If more ready tasks exist (`tk ready` filtered by parent) → return to Phase 3
- If no more ready tasks and some tasks are still blocked → report blocking chain, Phase 9
- If all tasks are closed → Phase 7 (validation)

---

## Phase 7: Post-Epic Validation (/sprint)

**Triggered when**: all child tasks are closed (or all remaining are failed/blocked).

Validation has two stages: (1) comprehensive project health via `/validate-work`, then (2) epic-specific quality scoring.

### Initialize Post-Loop Progress Checklist

Call `TodoWrite` to replace the batch checklist with the post-epic validation steps:

```
[ ] Integration test gate
[ ] Wait for CI (SHA-based)
[ ] Run E2E tests locally
[ ] Full validation (/validate-work + epic scoring)
[ ] Remediation (if score < 5 → returns to batch loop)
[ ] Close out (close epic + /end-session)
```

Mark each item `in_progress` when starting and `completed` when done. If remediation triggers (score < 5), check off "Remediation" and return to Phase 3 — the batch checklist is re-initialized there, and this post-loop checklist is recreated fresh when Phase 7 is re-entered.

### Step 0: Integration Test Gate (/sprint)

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
5. If integration tests fail after trigger: create a P1 bug issue and include in the Phase 7 report. Continue with /validate-work (non-blocking but flagged).

### Step 0.5: CI Verification + E2E Tests (/sprint)

Before running `/validate-work`, verify CI has passed on the final batch's commit and run the full E2E suite locally.

#### Step 0.5a: Wait for CI Containing the Final Commit

**Docs-only detection (run first)**:

Before checking CI, determine if the epic made code changes:

```bash
CODE_FILES=$(git diff --name-only main...HEAD | grep -vE '\.(md|txt|json)$|^\.tickets/|^\.claude/|^docs/' | head -1)
```

If `CODE_FILES` is empty (all changes are documentation, tickets, or config):
- Log: "Docs-only changes detected — skipping CI verification."
- Skip Steps 0.5a and 0.5b entirely
- Proceed directly to Step 1 (/validate-work)

If `CODE_FILES` is non-empty: continue with CI verification below.

**Worktree branch detection (run first)**:

```bash
CURRENT_BRANCH=$(git branch --show-current)
if echo "$CURRENT_BRANCH" | grep -qE '^worktree-[0-9]{8}-[0-9]{6}$'; then
    echo "Worktree branch detected ($CURRENT_BRANCH) — CI does not run on ephemeral branches."
    echo "Checking main branch CI instead."
    POLL_BRANCH="main"
else
    POLL_BRANCH="$CURRENT_BRANCH"
fi
```

If `POLL_BRANCH` is `main` (worktree branch detected): poll `gh run list --branch=main --limit=5` for the most recent completed run. If it is passing, consider CI satisfied and proceed to Step 0.5b. Log: "Worktree branch detected — CI does not run on ephemeral branches. Checking main branch CI instead."

**Critical** (non-worktree branches): Do NOT use `ci-status.sh --wait` alone — it returns the latest CI run, which may predate your push. Poll until a completed run **contains** your commit (exact SHA match or ancestor check for the case where another push supersedes yours and GitHub cancels your run).

```bash
HEAD_SHA=$(git rev-parse HEAD)
BRANCH="main"
MAX_WAIT=1800   # 30 minutes
ELAPSED=0
CONCLUSION=""
RUN_ID=""
MATCHED_SHA=""

while [ $ELAPSED -lt $MAX_WAIT ]; do
    git fetch origin $BRANCH --quiet 2>/dev/null || true

    RUNS_JSON=$(gh run list --workflow=CI --branch $BRANCH --limit 20 \
        --json databaseId,status,conclusion,headSha 2>/dev/null)

    while IFS= read -r RUN_LINE; do
        [ -z "$RUN_LINE" ] && continue
        RUN_SHA=$(echo "$RUN_LINE" | jq -r '.headSha')
        RUN_STATUS=$(echo "$RUN_LINE" | jq -r '.status')
        RUN_CONCLUSION=$(echo "$RUN_LINE" | jq -r '.conclusion')
        RUN_ID_CANDIDATE=$(echo "$RUN_LINE" | jq -r '.databaseId')

        CONTAINS=false
        if [ "$RUN_SHA" = "$HEAD_SHA" ]; then
            CONTAINS=true
        elif git merge-base --is-ancestor "$HEAD_SHA" "$RUN_SHA" 2>/dev/null; then
            CONTAINS=true
        fi

        if [ "$CONTAINS" = "true" ] && [ "$RUN_STATUS" = "completed" ]; then
            if [ "$RUN_CONCLUSION" = "success" ] || [ "$RUN_CONCLUSION" = "failure" ]; then
                CONCLUSION="$RUN_CONCLUSION"
                RUN_ID="$RUN_ID_CANDIDATE"
                MATCHED_SHA="$RUN_SHA"
                echo "CI contains $HEAD_SHA (run headSha: $MATCHED_SHA): $CONCLUSION (run: $RUN_ID)"
                break 2
            fi
            echo "  Run $RUN_ID_CANDIDATE ($RUN_SHA) contains our commit but was $RUN_CONCLUSION — checking for newer run..."
        fi
    done < <(echo "$RUNS_JSON" | jq -c '.[]')

    echo "  No completed CI run containing $HEAD_SHA yet (checking in 30s...)"
    sleep 30
    ELAPSED=$((ELAPSED + 30))
done

if [ -z "$CONCLUSION" ]; then
    echo "WARNING: No completed CI run containing $HEAD_SHA found after ${MAX_WAIT}s"
fi
```

| CI Result | Action |
|-----------|--------|
| `success` | Proceed to Step 0.5b |
| `failure` | Write the validation state file (see below), dispatch an `error-debugging:error-detective` agent (model: `sonnet`) with the CI run URL (`gh run view $RUN_ID --web`) and failed job names to diagnose root cause. Run `/debug-everything` to fix, commit+push, restart Step 0.5a. If still failing after one attempt → Phase 9 (Graceful Shutdown). |
| Not found after 30 min | Run `gh run list --workflow=CI --limit 10` to check if CI triggered. If all containing runs were cancelled with no successor, report to user. |

#### Validation State File (CI failure context for /debug-everything)

Before invoking `/debug-everything` on CI failure, write a validation state file so that debug-everything can skip redundant diagnostics for categories that already passed locally:

**File path**: `/tmp/sprint-validation-<epic-id>.json`

**Schema**:
```json
{
  "version": 1,
  "epicId": "<epic-id>",
  "generatedAt": "<ISO-8601 timestamp>",
  "generatedBy": "sprint",
  "localCheckResults": {
    "format": "pass|fail",
    "lint_ruff": "pass|fail",
    "lint_mypy": "pass|fail",
    "test_unit": "pass|fail"
  },
  "ciFailure": {
    "url": "<CI run URL>",
    "failedJobs": ["<job names if available>"]
  },
  "epicInfo": {
    "epicId": "<epic-id>",
    "changedFiles": ["<files from git diff main...HEAD>"]
  }
}
```

Populate `localCheckResults` from the post-batch validation output across all batches. Categories that passed locally are unlikely to be the CI failure cause. Write using Bash (inline JSON). Overwritten if Phase 7 is re-entered.

#### Step 0.5b: Run E2E Tests

Run the full E2E suite locally. This catches browser-visible regressions before the broader `/validate-work` gate.

```bash
cd $(git rev-parse --show-toplevel)/app && make test-e2e
```

**Interpret results:**
- **Pass** → proceed to Step 1
- **Fail** → do NOT proceed. Create a P1 bug issue for each failing test, set it as a child of the epic, and return to Phase 3.

### Step 1: Run /validate-work (/sprint)

Before invoking `/validate-work`, gather the changed files so the staging test sub-agent can apply tiered behavior (skipping browser automation for backend-only changes):

```bash
CHANGED_FILES=$(git diff --name-only main...HEAD 2>/dev/null || git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")
echo "$CHANGED_FILES"
```

Invoke the `/validate-work` skill. Immediately after the `/validate-work` invocation, append the following context block verbatim — substitute the actual file list from the `$CHANGED_FILES` output above (one file per line). This block is forwarded by `/validate-work` to the staging test sub-agent (Sub-Agent 5) for tiered test selection:

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
- **Any domain FAIL** → do NOT proceed. Create remediation tasks for failures and return to Phase 3. The `/validate-work` report's "Recommended Actions" guides what to fix.
- **Staging test SKIPPED** (staging down) → proceed to Step 2 but note in the final report that staging was not verified

### Step 2: Determine Epic Type (/sprint)

Scan the epic description and child task titles for UI keywords:
- **UI keywords**: `template`, `page`, `route`, `component`, `CSS`, `frontend`, `upload`, `form`, `layout`, `button`, `HTML`, `style`, `responsive`, `modal`, `dialog`
- **Classification**: If any UI keyword found → **UI epic**; otherwise → **backend-only epic**

### Step 3: Gather Changed Files (/sprint)

```bash
git diff --name-only main...HEAD
```

### Step 4: Launch Epic-Specific Validation Sub-Agent (/sprint)

This sub-agent evaluates the epic's quality beyond pass/fail checks — assessing functionality, accessibility, UX (for UI epics), and API contracts (for backend epics).

Launch a Task tool with the appropriate subagent type:
- UI epic: `subagent_type="full-stack-orchestration:test-automator"`
- Backend-only epic: `subagent_type="unit-testing:test-automator"`

**Validation Agent Prompt**: Read and fill in the externalized prompt template:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Read: $REPO_ROOT/.claude/skills/sprint/prompts/epic-validation-review.md
# Placeholders: {title}, {id}, {epic-type}, {repo_root}, {list of files from git diff}
```

### Step 5: Parse Validation Output (/sprint)

Extract the SCORE from the validation agent's output:
- **Score = 5** → Phase 9 (completion)
- **Score < 5** → Phase 8 (remediation)

---

## Phase 8: Remediation Loop (/sprint)

When validation score < 5:

### Reversion Detection

Before creating remediation tasks, invoke `/oscillation-check` as a sub-agent
(`subagent_type="general-purpose"`, `model="sonnet"`) with:
- `files_targeted`: files inferred from the REMEDIATION output
- `context`: remediation
- `epic_id`: the current epic

If it returns OSCILLATION: flag the specific items to the user before creating tasks.
Report which remediation items target files already modified by completed remediation.
If it returns CLEAR: proceed to create tasks normally.

### Step 1: Create Remediation Tasks (/sprint)

For each item in the validation agent's FAIL/REMEDIATION output:

```bash
tk create "Fix: {issue description}" -t bug -p 1 --parent=<epic-id>
```

### Step 2: Validate Ticket Health (/sprint)

```bash
$(git rev-parse --show-toplevel)/scripts/validate-issues.sh
```

### Step 3: Return to Phase 3 (/sprint)

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

## Phase 9: Session Close (/sprint)

Phase 9 delegates all completion and shutdown logic to `/end-session`, which handles closing issues, committing, merging to main, and reporting.

### On Success (Score = 5)

1. Close the epic:
   ```bash
   tk close <epic-id> --reason="Epic complete: all tasks closed, validation score 5/5"
   ```
2. Set sprint context for `/end-session` report:
   - Epic ID and title
   - Total tasks completed this session
   - Validation score: 5/5
3. Invoke `/end-session`

### On Graceful Shutdown (Compaction, Failures)

1. Do NOT launch new sub-agents
2. Wait for any running sub-agents to complete
3. Run final validation:
   ```bash
   cd $(git rev-parse --show-toplevel)/app && make test-unit-only
   ```
4. Update ALL in-progress tasks with checkpoint-format progress notes:
   ```bash
   tk add-note <id> "CHECKPOINT <N>/6: SESSION_END — Progress: <summary>. Next: <what remains>."
   ```
   Use the highest checkpoint number actually reached (e.g., `CHECKPOINT 3/6` if tests were written but implementation not started). This enables `/sprint --resume` to recover from the correct substep.
5. Set sprint context for `/end-session` report:
   - Tasks completed this session
   - Tasks remaining (with IDs and titles)
   - Resume command: `/sprint <epic-id> --resume`
6. Invoke `/end-session`

---

## Quick Reference

| Phase | Purpose | Key Commands |
|-------|---------|-------------|
| 1 | Select epic | `sprint-list-epics.sh --all`, `tk show`, `tk dep tree` |
| 1b | Preplanning gate | `tk dep tree`, `/preplanning` (if 0 children or ambiguous) |
| 2 | Analyze tasks | `tk dep tree`, `tk ready`, `tk show` |
| 2b | Implementation planning gate | `tk dep tree <story>`, `/implementation-plan` (if story has 0 impl tasks) |
| 3 | Plan batches | Priority classification, batch sizing |
| 4 | Pre-batch checks | Session usage check, counter files, git status, db-status |
| 5 | Launch agents | Task tool with structured prompts |
| 6 | Post-batch | persistence check, REVIEW-WORKFLOW.md, COMMIT-WORKFLOW.md, push, context check (→ `/compact` if >=70%), continuation decision |
| 7 | Validate | CI verification (SHA-based), full E2E tests, `/validate-work` (all domains), then epic-specific scoring |
| 8 | Remediation | Create fix tasks, re-enter loop |
| 9 | Session close | `/end-session` (close issues, commit, merge, report) |

## Error Recovery

| Situation | Action |
|-----------|--------|
| Sub-agent fails | Revert task to open, record failure in notes, continue batch |
| All sub-agents fail | Log failures, graceful shutdown, do not retry in same session |
| Validation agent fails to run | Skip validation, report to user, recommend manual review |
| DB not running for E2E | Ask user to run `make db-start`, wait for confirmation |
| CI fails at Phase 7 | Dispatch `error-debugging:error-detective` to diagnose, then `/debug-everything` to fix, commit+push, restart Phase 7 Step 0.5a; if still failing after one attempt, graceful shutdown |
| Git push fails | Report error, suggest `git pull --rebase`, never force-push |
| Ticket health < 5 after ops | Fix ticket issues before continuing (see `/tickets-health`) |
| Epic has 0 children | Preplanning gate triggers `/preplanning` automatically |
| Story has 0 impl tasks and isn't simple | Implementation planning gate triggers `/implementation-plan` per story |
| `/implementation-plan` needs clarification | Present questions to user, persist answers to story description, resume |
| Context >=70% between batches | Run `context-check`, write intent file, invoke `/compact`, continue to P3 (voluntary — all work committed) |
| Involuntary context compaction detected | Immediate graceful shutdown — do not launch more batches |
