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

## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)  # shim-exempt: internal orchestration script
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)  # shim-exempt: internal orchestration script
VISUAL_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_visual)  # shim-exempt: internal orchestration script
E2E_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_e2e)  # shim-exempt: internal orchestration script
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — replaces `make test-unit-only` in post-batch and remediation validation
- `LINT_CMD` — replaces `make lint` in validation steps
- `VISUAL_CMD` — replaces `make test-visual` in post-batch checks
- `E2E_CMD` — replaces `make test-e2e` in post-batch checks

## Usage

```
/dso:sprint                     # Interactive epic selection
/dso:sprint <epic-id>           # Execute specific epic
/dso:sprint <epic-id> --dry-run # Plan batches without executing
```

## Orchestration Flow

```
Flow: P1 (Init) → Preplanning Gate
  → [0 children/ambiguous] /dso:preplanning → P2
  → [children exist & clear] P2 (Task Analysis)
  P2 → [stories without impl tasks?] layer-stratify → parallel dispatch (≤3/layer) → STATUS:complete→tasks created | STATUS:blocked→ask user → Re-gather → P3
  P2 → [all have impl tasks] P3 (Batch Preparation)
  P3 → [dry-run] Output plan & stop
  P3 → [execute] P4 (Sub-Agent Launch) → P5 (Post-Batch)
  P5 → [context >=70%] /compact → P3 (proactive, safe — all work committed)
  P5 → [involuntary compaction detected] P8 (Graceful Shutdown)
  P5 → [more ready tasks] P3
  P5 → [all done] P6 (Validation)
  P6 → [score=5] P8 (Completion)
  P6 → [score<5] P7 (Remediation) → P3
```

---

## Phase 1: Initialization & Primary Ticket Selection (/dso:sprint)

### Parse Arguments

- `<primary-ticket-id>`: The primary ticket to execute (any type: epic, story, task, or bug)
- `--dry-run`: Output batch plan without executing any sub-agents

### If No Primary Ticket ID Provided

1. Run the epic discovery script:
   ```bash
   .claude/scripts/dso sprint-list-epics.sh --all --min-children=1
   ```
   This outputs tab-separated lines in three categories:
   - `<id>\tP*\t<title>\t<child_count>[\tBLOCKING]` for in-progress epics (4 or 5 fields; `P*` replaces priority)
   - `<id>\tP<priority>\t<title>\t<child_count>[\tBLOCKING]` for unblocked open epics (4 or 5 fields)
   - `BLOCKED\t<id>\tP<priority>\t<title>\t<child_count>\t<blocker_ids>` for blocked ones (6 fields; with `--all`)

   The `<child_count>` field is the number of child tickets. The `<blocker_ids>` field is a comma-separated list of open blocker epic IDs.

   Exit codes:
   - Exit code 1 → no open epics exist, report and exit
   - Exit code 2 → all open epics are blocked; display the BLOCKED-prefixed lines from stdout as context, then exit

   After running, also run the same command **without** `--min-children=1` to count how many epics were hidden:
   ```bash
   .claude/scripts/dso sprint-list-epics.sh --all
   ```
   Calculate `hidden_count = total_unfiltered_count - filtered_count` (count only non-BLOCKED lines from each run).

   **If no eligible epics remain** after applying `--min-children=1` (i.e., the filtered output is empty or exit code 1/2):
   - Report: "No epics with children are ready to execute."
   - If there are 0-child epics that were filtered out, show: "There are N epics with no children yet. Run `/dso:brainstorm` on one to decompose it into stories before executing."
   - Exit.

2. Parse the output and print a numbered list. **CRITICAL: You MUST output the formatted list as visible text BEFORE invoking any tool call.** Do NOT pass epics as `options` to `AskUserQuestion` — the `options` field is limited to 4 items and cannot display blocked epics or the hidden-count note. Number in-progress (`P*`) epics first, then unblocked. Blocked epics are informational only (not selectable). Render `BLOCKING` epics in **bold**. Below the list, if `hidden_count > 0`, append a note:
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

   (N epics with zero children are hidden. Run `/dso:brainstorm` on one to create stories.)
   ```
   Omit the hidden-epics note when `hidden_count == 0`.
3. Ask the user: "Enter the number or epic ID to execute:" and wait for their text input. Use `AskUserQuestion` with a free-text prompt only — do not pass epics as options.
4. Map the user's response (number or epic ID) back to the corresponding epic and proceed

### Validate Primary Ticket

Set `primary_ticket_id = <the resolved ticket ID>`.

1. Run `.claude/scripts/dso ticket show <primary_ticket_id>` — confirm status is `open` or `in_progress` (any ticket type is accepted)

#### Auto-Resume Detection

If the ticket type is `epic` AND status is `in_progress`:

(a) Print: `"Epic <primary_ticket_id> is in_progress — resuming from checkpoint scan."`

(b) Run `.claude/scripts/dso ticket deps <primary_ticket_id>` to check for children.

(c) **If zero children**: Log `"No children found — falling through to Preplanning Gate."` and continue to Drift Detection → Preplanning Gate normally (scenario: abandoned mid-preplanning, skip checkpoint resume).

(d) **If children exist**:
   - Run drift detection with `--status=open` filter:
     ```
     DRIFT_RESULT=$(.claude/scripts/dso sprint-drift-check.sh <primary_ticket_id> --status=open)
     ```
   - Handle `DRIFT_DETECTED` / `NO_DRIFT` the same as the existing Drift Detection Check section below.
   - Then apply checkpoint resume rules:
     1. Run `.claude/scripts/dso ticket list` and filter for in-progress tasks under `<primary_ticket_id>` for interrupted tasks
     2. For each in-progress task, run `.claude/scripts/dso ticket show <id>` and parse its notes for CHECKPOINT lines
     3. Apply checkpoint resume rules:
        - **CHECKPOINT 6/6 ✓** — task is fully done; fast-close: verify files exist, then `.claude/scripts/dso ticket transition <id> open closed --reason="Fixed: <summary>"`
        - **CHECKPOINT 5/6 ✓** — near-complete; fast-close: spot-check files and close without re-execution
        - **CHECKPOINT 3/6 ✓ or 4/6 ✓** — partial progress; re-dispatch with resume context: include the highest checkpoint note in the sub-agent prompt so it can continue from that substep
        - **CHECKPOINT 1/6 ✓ or 2/6 ✓** — early progress only; revert to open with `.claude/scripts/dso ticket transition <id> open` for full re-execution
        - **No CHECKPOINT lines or malformed CHECKPOINT lines** — revert to open: `.claude/scripts/dso ticket transition <id> open`
     4. Fallback rule: if CHECKPOINT lines are present but ambiguous (missing ✓, duplicate numbers, non-sequential), treat as malformed → revert to open
     5. **Backward compatibility**: Sprint reads old positional-counter checkpoints (CHECKPOINT N/6) without error and resumes from the last completed phase — no migration of existing checkpoint notes is required. Semantic-named checkpoints (CHECKPOINT:batch-complete, CHECKPOINT:review-passed, CHECKPOINT:validation-passed) are equivalent in resume logic.
   - After checkpoint processing, proceed to Phase 3.

(e) **Non-epic tickets** (story, task, bug) with `in_progress` status are NOT affected by auto-resume detection — they proceed through Non-Epic Routing as before. Auto-resume only applies to epic-type tickets.

2. Run `.claude/scripts/dso ticket deps <primary_ticket_id>` — if 100% complete, skip to Phase 6 (validation)
3. Mark ticket in-progress: `.claude/scripts/dso ticket transition <primary_ticket_id> in_progress`
4. Mark the **Select and validate primary ticket** todo item `completed`.

**Non-epic routing**: After validation, check the ticket type and route accordingly:

| Ticket type | Route |
|-------------|-------|
| `epic` | Continue to Drift Detection → Preplanning Gate (standard flow) |
| `bug` | Dispatch `/dso:fix-bug` as sub-skill (SC4) — see Bug Routing below |
| `story` or `task` | Run complexity evaluation then optional `/dso:implementation-plan` (SC1) — see Non-Epic Routing below |

#### Bug Routing (SC4)

<!-- REVIEW-DEFENSE: Finding 3 — The absence of an explicit ORCHESTRATOR_RESUME fence here is intentional.
     SC4 is a terminal routing path: the sprint orchestrator exits after fix-bug completes (step 4 proceeds directly
     to Phase 8 Session Close). There is no sprint phase to resume into after fix-bug returns, so the ORCHESTRATOR_RESUME
     pattern (which guards against fix-bug's own termination directives overriding the caller) is not applicable.
     The fix-bug skill's SUB-AGENT-GUARD handles nested sub-agent context as designed per the epic's success criteria. -->
When ticket type is `bug`:

1. Log: `"Primary ticket <primary_ticket_id> is a bug — dispatching /dso:fix-bug."`
2. Emit SKILL_INVOKE breadcrumb then invoke `/dso:fix-bug <primary_ticket_id>` via Skill tool.
3. Emit SKILL_RESUMED breadcrumb after the skill returns.
4. Exit Phase 1 and proceed to Phase 8 (Session Close). Do not continue to the Preplanning Gate or Phase 2.

#### Non-Epic Routing (SC1)

When ticket type is `story` or `task`:

1. Log: `"Primary ticket <primary_ticket_id> is a <type> — running complexity evaluation."`
2. Dispatch `subagent_type: dso:complexity-evaluator` (model: haiku) with `tier_schema=TRIVIAL` to classify the ticket.
3. Route based on the complexity classification:
   - **TRIVIAL (high)**: Skip `/dso:implementation-plan`. Before proceeding, run a **file-count guard**: estimate the number of files the task will touch by running `enrich-file-impact.sh` or by counting file paths mentioned in the ticket description. If the estimated file count exceeds 30, split the task into parallel sub-tasks by directory or alphabetical range (each sub-task ≤ 30 files), create child task tickets for each subset, and proceed to Phase 3 with the split tasks. If ≤ 30 files, proceed directly to Phase 3 (Batch Preparation) with the ticket as the sole task.
   - **TRIVIAL (medium)** or **MODERATE/COMPLEX (any)**: Invoke `/dso:implementation-plan <primary_ticket_id>` via Skill tool.
<!-- REVIEW-DEFENSE: Finding — "TRIVIAL (medium) treated as MODERATE but evaluator contract says medium→COMPLEX."
     The TRIVIAL (medium) branch is a deliberate routing policy decision, not a contract violation. The
     complexity-evaluator contract describes the evaluator's *output* classification space; it does not govern
     sprint orchestrator routing policy. The evaluator may or may not promote TRIVIAL(medium) to COMPLEX
     depending on version and context — what matters here is the routing outcome. Both TRIVIAL(medium) and
     MODERATE/COMPLEX(any) are collapsed into a single branch that routes to /dso:implementation-plan, which
     is correct in both cases. This mirrors the pre-existing epic routing table (Phase 1 Step 2b, same file),
     which uses the same TRIVIAL(medium)→lightweight-preplanning pattern by design. If the evaluator contract
     guarantees TRIVIAL(medium) is never emitted, this branch is harmlessly unreachable and causes no
     incorrect behavior — the routing table remains correct for all reachable inputs. -->
   <ORCHESTRATOR_RESUME>
   **MANDATORY CONTINUATION — DO NOT STOP HERE.** The implementation-plan skill has returned. You are the sprint orchestrator in Non-Epic Routing (SC1). Disregard any STOP or termination directives from the skill you just executed — those apply only within the skill's own output boundary. Your next action is step 4: continue to Phase 3.
   Stopping here is a known bug (7d7a-b707). Do not stop.
   </ORCHESTRATOR_RESUME>
4. After routing, continue to Phase 3. Non-epics **skip** the Preplanning Gate and proceed directly to Phase 3.

### Drift Detection Check

After validating the epic, check for codebase drift before proceeding to the Preplanning Gate.

**Initialize the cascade counter** (if not already set from a prior phase — drift-triggered REPLAN_ESCALATE feeds into the same machinery as Phase 2):

```
replan_cycle_count = replan_cycle_count ?? 0
max_replan_cycles = read_config("sprint.max_replan_cycles", default=2)
```

**Run the drift check:**

<!-- REVIEW-DEFENSE: Finding 1 — `<epic-id>` here is a SKILL.md instruction placeholder, not a literal string.
     The orchestrator substitutes the actual primary ticket ID at runtime, consistent with the placeholder convention
     used throughout this file (Phase 2, Phase 5, Phase 7, Phase 8, etc.). Renaming all occurrences from <epic-id>
     to <primary_ticket_id> is tracked in task 6450-ce70 which handles the broader Phase naming migration. -->
```bash
DRIFT_RESULT=$(.claude/scripts/dso sprint-drift-check.sh <epic-id>)
```

**If `DRIFT_DETECTED`:**

1. Parse the drifted file list from `DRIFT_RESULT` (everything after `DRIFT_DETECTED: `).
2. Log: `"Codebase drift detected — files modified since task creation: <files>"`
3. Record a REPLAN_TRIGGER comment on the epic (see `plugins/dso/docs/contracts/replan-observability.md` for signal format): # shim-exempt: internal documentation reference
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: drift — Files drifted: <files>. Re-invoking implementation-plan for affected stories."
   ```
4. Identify which stories' tasks reference any of the drifted files (inspect each child task's `## File Impact` or `## Files to Modify` section).
5. For each affected story, emit a SKILL_INVOKE breadcrumb and re-invoke `/dso:implementation-plan <story-id>` via the Skill tool (same as Phase 2 Step 2).

   <ORCHESTRATOR_RESUME>
   **MANDATORY CONTINUATION — DO NOT STOP HERE.** The implementation-plan skill has returned. You are the sprint orchestrator in Drift Detection. Continue to the next affected story, then proceed to step 6 (record REPLAN_RESOLVED).
   Stopping here is a known bug (7d7a-b707). Do not stop.
   </ORCHESTRATOR_RESUME>

   - **On success (`STATUS:complete`)**: continue.
   - **On `STATUS:blocked`**: surface the story as blocked for user input (same handling as Phase 2 blocked-stories list).
   - **On `REPLAN_ESCALATE: brainstorm EXPLANATION:<text>`**: add the story and its explanation to the **replan-stories list** and route through the existing d-replan-collect cascade machinery (Phase 2 step d-replan-collect). The `replan_cycle_count` / `max_replan_cycles` initialized above are shared with Phase 2 — do not reinitialize them.
6. After all re-invocations complete (and no REPLAN_ESCALATE is outstanding), record:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: implementation-plan — Drift re-planning complete for <N> stories."
   ```
7. Proceed to Preplanning Gate.

**Note:** `DRIFT_DETECTED` and `RELATES_TO_DRIFT` are independent signals — both may appear in the same `DRIFT_RESULT` output. Process each block that matches, in order. They are NOT mutually exclusive branches.

**If `RELATES_TO_DRIFT` lines are present in `DRIFT_RESULT`:**

1. Parse each `RELATES_TO_DRIFT: <epic-id> <summary>` line from `DRIFT_RESULT`.
2. Log: `"Relates_to drift detected — related epic <epic-id> closed after implementation plan: <summary>"` for each line.
3. Record a REPLAN_TRIGGER comment on the epic (see `plugins/dso/docs/contracts/replan-observability.md` for signal format): # shim-exempt: internal documentation reference
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: drift — Relates_to epic <closed-epic-id> closed after implementation plan. <summary>. Re-invoking implementation-plan for affected stories."
   ```
4. Identify which stories' tasks reference any of the drifted relates_to epics (inspect each child task's `## File Impact` or `## Files to Modify` section, or cross-reference the task's dependency/relates-to links).
5. For each affected story, emit a SKILL_INVOKE breadcrumb and re-invoke `/dso:implementation-plan <story-id>` via the Skill tool (same as DRIFT_DETECTED handling above).

   <ORCHESTRATOR_RESUME>
   **MANDATORY CONTINUATION — DO NOT STOP HERE.** The implementation-plan skill has returned. You are the sprint orchestrator in Drift Detection (RELATES_TO_DRIFT). Continue to the next affected story, then proceed to step 6 (record REPLAN_RESOLVED).
   Stopping here is a known bug (7d7a-b707). Do not stop.
   </ORCHESTRATOR_RESUME>

   - **On success (`STATUS:complete`)**: continue.
   - **On `STATUS:blocked`**: surface the story as blocked for user input (same handling as Phase 2 blocked-stories list).
   - **On `REPLAN_ESCALATE: brainstorm EXPLANATION:<text>`**: add the story and its explanation to the **replan-stories list** and route through the existing d-replan-collect cascade machinery (Phase 2 step d-replan-collect). The `replan_cycle_count` / `max_replan_cycles` initialized above are shared with Phase 2 — do not reinitialize them.
6. After all re-invocations complete (and no REPLAN_ESCALATE is outstanding), record:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: implementation-plan — Relates_to drift re-planning complete for <N> stories."
   ```
7. Proceed to Preplanning Gate.

**If `NO_DRIFT`:**

Log: `"No codebase drift detected — proceeding to Preplanning Gate."` Continue normally.

### Clarity Gate

The Clarity Gate is a three-layer check that runs **for epic-typed tickets only** before entering the Preplanning Gate. It prevents sprint execution from starting when the ticket intent is unclear.

**CHECKPOINT: clarity-gate-start** — record this before running the gate.

#### Layer 1: Structural Clarity Check

Run the ticket clarity check script:

```bash
.claude/scripts/dso ticket-clarity-check.sh <primary_ticket_id>
```

Parse the result:
- **Exit 0 (CLEAR)**: ticket passes structural check; proceed to Layer 2.
- **Exit 1 (UNCLEAR)**: log the reason; proceed to User Escalation (Layer 3).
- **Exit 2 (ERROR/ABSENT)**: script is missing or encountered an error; emit a warning (`"ticket-clarity-check.sh unavailable — falling through to Layer 2"`); proceed to Layer 2 (fail-open).

#### Layer 2: Scope Certainty Assessment

Dispatch `dso:complexity-evaluator` (model: haiku) with the primary ticket context to evaluate `scope_certainty`:

```
subagent_type: dso:complexity-evaluator
model: haiku
input:
  ticket_id: <primary_ticket_id>
  tier_schema: SIMPLE
```

Parse `scope_certainty` from the evaluator's JSON output:

- **`High` or `Medium`**: proceed to Preplanning Gate.
- **`Low`**: proceed to User Escalation (Layer 3).
- **Unrecognized value**: treat as `Low` — proceed to User Escalation (Layer 3).
- **Agent unavailability** (timeout, dispatch failure, API key absent): log `"WARNING: complexity-evaluator unavailable — falling through to Layer 3."` and proceed to User Escalation (Layer 3).

#### Layer 3: User Escalation (AskUserQuestion)

When either Layer 1 or Layer 2 signals low clarity, present options via AskUserQuestion:

> "The primary ticket `<primary_ticket_id>` has low clarity. How would you like to proceed?
>
> (a) Run `/dso:fix-bug` if this is actually a defect
> (b) Run `/dso:brainstorm` to enrich the ticket before executing
> (c) Proceed anyway with the current ticket as-is"

Wait for user response and route accordingly:
- **(a) fix-bug**: dispatch `/dso:fix-bug <primary_ticket_id>`, then exit to Phase 8.
- **(b) brainstorm**: invoke `/dso:brainstorm <primary_ticket_id>` via Skill tool, then re-enter Preplanning Gate.
- **(c) proceed**: log `"User elected to proceed with low-clarity ticket."`, continue to Preplanning Gate.

### Context Efficiency Rules

**Status checks**: Use `.claude/scripts/dso issue-summary.sh <id>` or `.claude/scripts/dso ticket list` for orchestrator status checks (is it done? what's blocking?). Reserve full `.claude/scripts/dso ticket show <id>` only when sub-agents need to read their complete task context.

**Ticket-as-prompt**: Before dispatch, run the quality gate:
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

**File impact enrichment**: If a ticket is missing a file impact section, run `.claude/scripts/dso enrich-file-impact.sh <id>` to auto-generate it. Use `--dry-run` to preview. Gracefully degrades if `ANTHROPIC_API_KEY` is unset.

### Preplanning Gate

#### Step 1: Check for Existing Children (/dso:sprint)

```bash
.claude/scripts/dso ticket deps <epic-id>
```

Count the number of child tasks returned.

- **If children exist**: proceed to Step 2a (Existing Children Readiness Check)
- **If zero children**: proceed to Step 2b (Epic Complexity Evaluation)

#### Step 2a: Existing Children Readiness Check (/dso:sprint)

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


> **CONTROL_LOSS detection note (applies to every SKILL_INVOKE/SKILL_RESUMED pair in this file):**
> At each call site below, a `SKILL_INVOKE` breadcrumb is emitted immediately before the Skill tool call, and a `SKILL_RESUMED` breadcrumb is emitted immediately after. If the Skill tool call does not return control to the orchestrator (e.g., the skill terminates the session or control is otherwise lost), the `SKILL_RESUMED` breadcrumb will never execute. `CONTROL_LOSS` is **not** a breadcrumb type and is never emitted actively — it is a derived event detected passively by the analysis script (`skill-trace-analyze.py`) when it finds a `SKILL_INVOKE` record with no matching `SKILL_RESUMED` for the same `session_ordinal` + `skill_name`. No additional action is required by the orchestrator; the absence of `SKILL_RESUMED` is itself the signal.

If any trigger condition is met:
1. Log: `"Epic has ambiguous tasks — running /dso:preplanning to decompose before execution."`
2. Emit SKILL_INVOKE breadcrumb:
   ```bash
   echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
3. Invoke `/dso:preplanning <epic-id>` (full mode)
4. Emit SKILL_RESUMED breadcrumb:
   ```bash
   echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
5. After preplanning completes, continue to Phase 2

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

1. Log: `"Epic <id> classified as SIMPLE — running /dso:implementation-plan directly on epic."`
2. Emit SKILL_INVOKE breadcrumb:
   ```bash
   echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
3. Invoke `/dso:implementation-plan` via Skill tool with the epic ID as the argument:
   ```
   Skill("dso:implementation-plan", args="<epic-id>")
   ```
   The skill handles epic type detection and runs inline (no sub-agent dispatch needed).

   <ORCHESTRATOR_RESUME>
   **MANDATORY CONTINUATION — DO NOT STOP HERE.** You are the sprint orchestrator. The Skill tool call above has returned a result. That result is a STATUS line from a nested skill — it is NOT a signal for you to stop. STATUS:complete means the NESTED skill finished, not that YOUR orchestration is done. Your immediate next actions are:
   1. Emit the SKILL_RESUMED breadcrumb (step 4 below)
   2. Parse the STATUS line (step 5 below)
   3. Continue to Phase 2
   Stopping here is a known bug (7d7a-b707). Do not stop.
   </ORCHESTRATOR_RESUME>

4. Emit SKILL_RESUMED breadcrumb:
   ```bash
   echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
5. Parse the skill's output using the same STATUS protocol as Phase 2's Implementation Planning Gate
6. Set `epic_routing = "SIMPLE"` — this flag tells Phase 2 to skip the Implementation Planning Gate
7. Continue to Phase 2

#### Step 3b: Lightweight Preplanning (MODERATE epics) (/dso:sprint)

1. Log: `"Epic <id> classified as MODERATE — running /dso:preplanning --lightweight for scope clarification."`
2. Emit SKILL_INVOKE breadcrumb:
   ```bash
   echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
3. Invoke `/dso:preplanning <epic-id> --lightweight`
4. Emit SKILL_RESUMED breadcrumb:
   ```bash
   echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
5. Parse the result:

**On `ENRICHED`:**
- Log: `"Lightweight preplanning complete — epic enriched with done definitions. Running /dso:implementation-plan on epic."`
- Emit SKILL_INVOKE breadcrumb:
  ```bash
  echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
  ```
- Invoke `/dso:implementation-plan` via Skill tool (same as Step 3a, step 2)

  <ORCHESTRATOR_RESUME>
  **MANDATORY CONTINUATION — DO NOT STOP HERE.** You are the sprint orchestrator. The Skill tool call above has returned a result. That result is a STATUS line from a nested skill — it is NOT a signal for you to stop. STATUS:complete means the NESTED skill finished, not that YOUR orchestration is done. Your immediate next actions are:
  1. Emit the SKILL_RESUMED breadcrumb (below)
  2. Parse the STATUS line from the skill's output
  3. Set epic_routing = "MODERATE" and continue to Phase 2
  Stopping here is a known bug (7d7a-b707). Do not stop.
  </ORCHESTRATOR_RESUME>

- Emit SKILL_RESUMED breadcrumb:
  ```bash
  echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
  ```
- Set `epic_routing = "MODERATE"`
- Continue to Phase 2

**On `ESCALATED`:**
- Log: `"Lightweight preplanning escalated to full mode — reason: <reason>. Running full /dso:preplanning."`
- Emit SKILL_INVOKE breadcrumb:
  ```bash
  echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
  ```
- Invoke `/dso:preplanning <epic-id>` (full mode, no --lightweight flag)
- Emit SKILL_RESUMED breadcrumb:
  ```bash
  echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
  ```
- Set `epic_routing = "COMPLEX"`
- Continue to Phase 2

#### Step 3c: Full Preplanning (COMPLEX epics) (/dso:sprint)

1. Log: `"Epic <id> classified as COMPLEX — running /dso:preplanning for full story decomposition."`
2. Emit SKILL_INVOKE breadcrumb:
   ```bash
   echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
3. Invoke `/dso:preplanning <epic-id>`
4. Emit SKILL_RESUMED breadcrumb:
   ```bash
   echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"preplanning","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
5. After preplanning completes, set `epic_routing = "COMPLEX"`
6. Continue to Phase 2

---

## Phase 2: Task Analysis & Dependency Graph (/dso:sprint)

### Gather Tasks

1. `.claude/scripts/dso ticket deps <epic-id>` — get all child tasks
2. `.claude/scripts/dso ticket list` (filtered by parent) — get unblocked tasks ready to work
3. `.claude/scripts/dso ticket show <id>` for each ready task to read full descriptions

### Implementation Planning Gate

#### Pre-check: Skip for SIMPLE/MODERATE Routing (/dso:sprint)

If `epic_routing` is `"SIMPLE"` or `"MODERATE"` (set in Phase 1's Preplanning Gate), skip the entire Implementation Planning Gate and proceed directly to **Classify Tasks** below. Tasks were already created as direct children of the epic by `/dso:implementation-plan` — there is no story layer to decompose.

Log: `"Skipping Implementation Planning Gate — epic was routed as <epic_routing>, tasks already exist under epic."`

#### Design-Blocked Story Filter (/dso:sprint)

Before processing stories for implementation planning, filter out design-blocked stories.

**Source tag constants from shared config:**
```bash
source plugins/dso/skills/shared/constants/figma-tags.conf
# TAG_AWAITING_IMPORT=design:awaiting_import
```

**Read staleness threshold from config:**
```bash
figma_staleness_days=$(grep '^design\.figma_staleness_days=' .claude/dso-config.conf | cut -d= -f2)
figma_staleness_days=${figma_staleness_days:-7}
```

**Initialize awaiting_design_stories list (once before layer loop):**
```
awaiting_design_stories = []  # List of {id, title, tag_applied_date}
```

**For each story from `.claude/scripts/dso ticket list` (filtered by parent):**
1. Run `.claude/scripts/dso ticket show <story-id>` and check the `tags` field
2. If `design:awaiting_import` (i.e., `$TAG_AWAITING_IMPORT`) is present:
   - Log: `"Story <id> tagged design:awaiting_import — skipping implementation planning."`
   - Estimate the tag age from the ticket's comment timestamps: find the comment whose body contains `"Import designs/"` (written by design-wireframe when the tag was applied) and read its `timestamp` field from the JSON output. Compute days elapsed: `$(( ($(date +%s) - comment_timestamp_epoch) / 86400 ))`. If no such comment exists, treat tag age as unknown (no staleness warning).
   - Add the story to the `awaiting_design_stories` list: `{id: "<story-id>", title: "<story-title>", tag_applied_date: "<date or unknown>"}`
   - **Do not add this story to the needs-planning list**. Skip all further processing for this story (no complexity eval, no implementation-plan dispatch, no batch dispatch in Phase 4).
3. Only stories **without** the `design:awaiting_import` tag proceed to Step 1 below.

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
| TRIVIAL | high | Skip `/dso:implementation-plan`. **File-count guard**: estimate the file count from the story description or `enrich-file-impact.sh`. If > 30 files, split into child tasks (≤ 30 files each) by directory or alphabetical range before proceeding. Log: `"Story <id> classified as TRIVIAL — skipping /dso:implementation-plan"` |
| TRIVIAL | medium | Treat as COMPLEX (medium confidence = plan) |
| COMPLEX | any | Run `/dso:implementation-plan` via Skill tool (see Step 2) |

**Post-routing action for COMPLEX stories**: After routing a story to `/dso:implementation-plan`, tag it so Phase 4 can upgrade implementation task models:
```bash
.claude/scripts/dso ticket comment <story-id> "COMPLEXITY_CLASSIFICATION: COMPLEX"
```

#### Dependency Layer Stratification (/dso:sprint)

Before invoking `/dso:implementation-plan` for any stories, group the stories that need decomposition into topological layers based on their intra-sprint dependencies.

**Step A: Collect intra-sprint dependency edges**

For each story in the needs-planning list:
1. Run `.claude/scripts/dso ticket show <story-id>` and read the `DEPENDS ON` field
2. For each dependency listed, check whether it is also in the needs-planning list
3. Record the edge only if both the story and its blocker are in the needs-planning list (ignore cross-sprint or already-completed dependencies)

**Step B: Assign layers**

Assign each story to a layer:
1. **Layer 0**: stories with no intra-sprint blockers
2. **Layer N**: stories whose all blockers are in Layers 0 through N-1

If a cycle is detected, log a warning and treat both as Layer 0.

**Step C: Output layer assignment**

Log the layer assignment: `"Dependency layers: Layer 0: <ids>, Layer 1: <ids>, ..."`. Proceed to Step 2 using this layer ordering.

#### Step 2: Run Implementation Planning (/dso:sprint)

Process stories in layer order — Layer 0 first, then Layer 1, etc. Within each layer, invoke `/dso:implementation-plan` sequentially via Skill tool for each story that needs decomposition. Wait for all stories in the layer to complete before processing the next layer.

**Epic-level cascade counter (initialize once before the layer loop):**

```
replan_cycle_count = 0
max_replan_cycles = read_config("sprint.max_replan_cycles", default=2)
```

This counter is shared across all stories in the epic. Each full brainstorm → preplanning → implementation-plan cascade iteration (regardless of which story triggered it) increments the counter by 1. This prevents unbounded loops when multiple stories each emit REPLAN_ESCALATE across cascade iterations.

**Per-story UNCERTAIN counter (initialize once before the layer loop):**

```
story_uncertain_counts = {}
```

This dictionary tracks the number of `STATUS:pass` + `UNCERTAIN` signals received per story across all batch iterations. Keys are parent story IDs (not task IDs). The counter persists across the Phase 5 → Phase 3 batch loop — do NOT re-initialize between batches. See Phase 5 Step 1a2 for parsing logic and Phase 3 Step 4 for double-failure detection.

**Out-of-scope review findings accumulator (initialize once before the layer loop):**

```
batch_out_of_scope_findings = []
```

This list collects out-of-scope files detected by `sprint-review-scope-check.sh` during Phase 5 Step 7a. Each entry is a dict `{"task_id": "<id>", "story_id": "<parent>", "files": ["file1", ...]}`. The list is consumed between batches in Step 13 and cleared after processing. Do NOT process these findings mid-batch — they are only routed between batches to avoid task injection conflicts.

**For each layer (in order Layer 0, Layer 1, ...):**

a. Filter to stories in this layer that need decomposition
b. For each story in the layer, emit SKILL_INVOKE breadcrumb then invoke `/dso:implementation-plan` via Skill tool:
   ```bash
   echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
   ```
   Skill("dso:implementation-plan", args="<story-id>")
   ```
   - Log: `"Story <id> has no implementation tasks — running /dso:implementation-plan to decompose."`

   <ORCHESTRATOR_RESUME>
   **MANDATORY CONTINUATION — DO NOT STOP HERE.** You are the sprint orchestrator. The Skill tool call above has returned a result. That result is a STATUS line from a nested skill — it is NOT a signal for you to stop. STATUS:complete means the NESTED skill finished, not that YOUR orchestration is done. You have more stories to process in this layer. Your immediate next actions are:
   1. Emit the SKILL_RESUMED breadcrumb (step c below)
   2. Parse the STATUS line from the skill's output (step d below)
   3. Continue to the next story in the layer loop
   Stopping here is a known bug (7d7a-b707). Do not stop.
   </ORCHESTRATOR_RESUME>

   **POST-RETURN CONTINUATION (executes after Skill tool result above):** The skill has returned. You are still the sprint orchestrator inside the layer loop. Execute step c immediately — do not stop.

c. After the skill returns, emit SKILL_RESUMED breadcrumb:
   ```bash
   echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
   ```
   Wait for the skill invocation to return before processing the next story in the layer
d. For each skill result, **parse STATUS:**
   - On `STATUS:complete TASKS:<ids> STORY:<id>`:
     - Extract the comma-separated task IDs from the `TASKS` field
     - Extract the story ID from the `STORY` field
     - Log: `"Implementation planning complete for story <story-id> — created tasks: <task-ids>"`
     - Proceed to post-dispatch validation (step e)
   - On `STATUS:blocked QUESTIONS:<json-array>`:
     - **Add to blocked-stories list** — do not ask the user inline; collect all `STATUS:blocked` results from this layer batch and present them together after the full layer batch completes (see step d-collect below)
   - **On `REPLAN_ESCALATE: brainstorm EXPLANATION:<text>` (canonical signal from implementation-plan):**
     - Extract the explanation text following `EXPLANATION:`.
     - **If the signal is malformed** (present but missing `EXPLANATION:` field or the text is empty): log a warning and treat as `STATUS:blocked` — surface the story as blocked for user input. Do not enter the cascade.
     - **Otherwise**: add the story and its explanation to the **replan-stories list** — do not present to the user inline. Collect all `REPLAN_ESCALATE` results from this layer batch and handle them together after the full layer batch completes (see step d-replan-collect below).
   - **Fallback — if no STATUS line in skill output:**
     - Run `.claude/scripts/dso ticket deps <story-id>` to check whether tasks were created
     - If children exist → treat as success; log a warning: `"WARNING: skill returned no STATUS line for story <id>, but .claude/scripts/dso ticket deps shows tasks — continuing"`; proceed to post-dispatch validation
     - If no children → emit SKILL_INVOKE breadcrumb and retry the skill invocation once (same parameters):
       ```bash
       echo '{"type":"SKILL_INVOKE","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
       ```
       After retry returns, emit SKILL_RESUMED breadcrumb:
       ```bash
       echo '{"type":"SKILL_RESUMED","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","skill_name":"implementation-plan","nesting_depth":'"${DSO_TRACE_NESTING_DEPTH:-1}"',"session_ordinal":null,"tool_call_count":null,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}' >> /tmp/dso-skill-trace-${DSO_TRACE_SESSION_ID:-$$}.log || true
       ```
     - If retry also produces no children → revert story to open (`.claude/scripts/dso ticket transition <story-id> open`); log: `"ERROR: /dso:implementation-plan failed for story <id> after retry — story reverted to open"`; skip to next story

**Skill unavailability terminal condition:** If the retry also produces no children and this is the second consecutive skill-load failure (i.e., the initial attempt AND the retry both produced no children), do NOT retry again. Emit a terminal error and stop:

```
SKILL_LOAD_ERROR: dso:sprint skill file could not be loaded after 2 attempts.
Resolution: Verify that plugins/dso/skills/sprint/SKILL.md exists and is readable. Run: ls -la plugins/dso/skills/sprint/SKILL.md
Do NOT continue looping — this sprint session has ended due to skill unavailability.
```

Exit the skill immediately. Do not invoke any further skill steps.
d-collect. **Collect and present blocked-layer stories** — after the full layer batch completes, for each story with `STATUS:blocked`:
   - **Parsing STATUS:blocked**: When `/dso:implementation-plan` returns `STATUS:blocked QUESTIONS:[...]`, parse the JSON array and present each question in human-readable format:
     1. Separate questions by kind: "blocking" (must be answered before proceeding) vs "defaultable" (have a default, can be skipped)
     2. Number each question
     3. Present blocking questions first, then defaultable questions with their defaults shown
     Do NOT display the raw `STATUS:blocked` line to the user.
   - **Important**: Do NOT display the raw `STATUS:blocked QUESTIONS:<json>` line to the user. This is an internal machine signal. Capture it silently, parse the JSON, then present only the formatted question list (see below) to the user.
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
   - **Persist answers to story description**:
     ```bash
     # Append clarifications to the ticket via comment
     .claude/scripts/dso ticket comment <story-id> "## Clarifications (from sprint orchestrator)
     Q1: <question 1 text>
     A1: <user answer 1>
     Q2: <question 2 text>
     A2: <user answer 2>"
     ```
   - **Re-invoke the skill**: Call the Skill tool again with the same story ID.
   - **If the re-invoked skill returns `STATUS:blocked` again**: Do not ask the user a second time. Treat as failure: revert story to open (`.claude/scripts/dso ticket transition <story-id> open`), log `"ERROR: /dso:implementation-plan returned STATUS:blocked twice for story <story-id> — story reverted to open"`, and skip to the next story.
d-replan-collect. **Collect and handle all REPLAN_ESCALATE stories** — after the full layer batch completes, if any stories are in the replan-stories list:
   - **Non-interactive mode check** (before all other steps): If the session is non-interactive (interactivity mode declared at session start as non-interactive), do NOT block for user input. For each story in the replan-stories list, record:
     ```bash
     .claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED: brainstorm — implementation-plan emitted REPLAN_ESCALATE for story <story-id>: <explanation>. Re-run sprint interactively to address."
     ```
     Skip the brainstorm cascade entirely. Do NOT write `REPLAN_RESOLVED`. Continue with any remaining work (the affected stories remain in their current state, pending a follow-up interactive session). See `plugins/dso/docs/contracts/replan-observability.md` for the INTERACTIVITY_DEFERRED signal format. # shim-exempt: internal documentation reference
   - **Check cycle cap first** (before presenting anything to the user):
     - **If `replan_cycle_count >= max_replan_cycles`:** Present the **cap-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "accept the current plan as-is and continue sprint execution". See `plugins/dso/docs/designs/cascade-replan-protocol.md` §"When Max Cycles Are Hit". # shim-exempt: internal documentation reference
     - **If cap is not yet exhausted:** Present the **cap-not-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "accept the current state and continue sprint with these stories as-is".
     - **If user selects (b) or (c):** act accordingly — proceed or abort. Do not enter cascade.
     - **If user selects (a):** Enter the cascade replan per `plugins/dso/docs/designs/cascade-replan-protocol.md`: # shim-exempt: internal documentation reference
       1. Emit SKILL_INVOKE breadcrumb for brainstorm, then invoke `/dso:brainstorm <epic-id>` via Skill tool
       2. Emit SKILL_RESUMED breadcrumb after brainstorm returns
       3. Emit SKILL_INVOKE breadcrumb for preplanning, then invoke `/dso:preplanning <epic-id>` via Skill tool
       4. Emit SKILL_RESUMED breadcrumb after preplanning returns
       5. Increment `replan_cycle_count += 1`
       6. Re-run Step 2 (implementation planning) for all stories in the epic — re-enter the layer loop from the beginning
       7. If implementation-plan returns no `REPLAN_ESCALATE` for any story: write the resolved signal, then cascade exits — proceed to step e normally (plan accepted):
          ```bash
          .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: brainstorm — Stories re-planned after brainstorm cascade."
          ```
       8. If implementation-plan still emits `REPLAN_ESCALATE`: repeat from d-replan-collect (check cap first, then present to user)
e. **Post-layer-batch ticket validation**:
   ```bash
   .claude/scripts/dso validate-issues.sh --quick --terse
   ```
   Log any warnings but do not block on non-critical results
f. Re-run `.claude/scripts/dso ticket list` (filtered by parent) to pick up newly created implementation tasks before processing the next layer

#### Step 3: Continue to Classification (/dso:sprint)

Proceed to task classification with the updated task list.

### Classify Tasks

Classification is performed automatically by `sprint-next-batch.sh` in Phase 3 (Batch Preparation). Each `TASK:` line in its output already includes `model`, `subagent`, and `class` fields — no separate classification step is needed here. Proceed directly to building the dependency graph below.

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

## Phase 3: Batch Preparation (/dso:sprint)

### Step 1: Pre-Batch Checks

Before launching each batch, run the shared pre-batch check script:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check       # standard  # shim-exempt: internal orchestration script
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check --db  # if batch includes DB-dependent tasks  # shim-exempt: internal orchestration script
```

The script outputs structured key-value pairs:
- `MAX_AGENTS: unlimited | N | 0` — use as `max_agents` (see protocol below)
- `SESSION_USAGE: normal | high | critical`
- `GIT_CLEAN: true | false` — if false, commit previous batch first
- `DB_STATUS: running | stopped | skipped` — if stopped, ask user to start DB

Clean the discovery directory:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries  # shim-exempt: internal orchestration script
```

Output: `DISCOVERIES_CLEANED: <N>`. Exit 0 always (best-effort).

**MAX_AGENTS protocol** (3-tier):

| `max_agents` value | Behavior |
|---------------------|----------|
| `unlimited` | Dispatch all ready tasks in a single batch with no artificial cap. Pass `--limit=unlimited` (or omit `--limit`) to `sprint-next-batch.sh`. |
| `N` (positive integer) | Cap the batch at N sub-agents. Pass `--limit=N` to `sprint-next-batch.sh`. Log: `"Session usage elevated, limiting to N sub-agent(s)."` |
| `0` | Skip sub-agent dispatch entirely. Write a ticket comment with utilization percentages and estimated reset time, then proceed to Phase 5 Step 13 (Continuation Decision). Log: `"MAX_AGENTS=0 — session at critical utilization, skipping dispatch."` Comment format: `.claude/scripts/dso ticket comment <epic-id> "BATCH_SKIPPED: MAX_AGENTS=0. Session utilization: <SESSION_USAGE>. Estimated reset: next session."` |

All Task tool calls use `run_in_background: true`.

### Step 2: Claim Tasks

For each task in the batch:
```bash
.claude/scripts/dso ticket transition <id> in_progress
```

### Step 3: Update from Main

Pull the latest code from main before launching sub-agents:

```bash
git fetch origin main && git merge origin/main --no-edit
```

This syncs the worktree branch with the latest main. Ticket branch syncing happens automatically during `merge-to-main.sh` at end-of-sprint (not during mid-sprint sync).

### Step 4: Batch Composition

#### Inject Prior Batch Discoveries (Batch 2+ only)

For Batch 2+, collect discoveries for injection into sub-agent prompts via `{prior_batch_discoveries}` in `task-execution.md`:

```bash
PRIOR_BATCH_DISCOVERIES=$(.claude/scripts/dso collect-discoveries.sh --format=prompt 2>/dev/null) || PRIOR_BATCH_DISCOVERIES="None."
```

- For **Batch 1** (no prior discoveries), set `PRIOR_BATCH_DISCOVERIES="None."`
- For **Batch 2+**, replace `{prior_batch_discoveries}` with the script output
- **Graceful degradation**: If `collect-discoveries.sh --format=prompt` fails, log a warning
  and use `"None."` as the fallback value. Discovery injection failure must not block the sprint.

#### Compose Batch

Run the deterministic batch selector:

```bash
# When max_agents is "unlimited", omit --limit (or pass --limit=unlimited):
.claude/scripts/dso sprint-next-batch.sh <epic-id>
# When max_agents is a positive integer N:
.claude/scripts/dso sprint-next-batch.sh <epic-id> --limit=N
# When max_agents is 0: do NOT call sprint-next-batch.sh — skip dispatch (see Phase 3 Step 1 protocol)
```

- **`max_agents`**: Determined by Step 1's pre-batch check (3-tier: `unlimited`, `N`, or `0`).
- **`unlimited`**: Returns the full non-conflicting pool — dispatch all candidates.
- **`N`** (positive integer): Caps batch at N tasks.
- **`0`**: Skip dispatch entirely — do not call `sprint-next-batch.sh`. Write the utilization comment per Phase 3 Step 1 protocol and proceed to Phase 5 Step 13.

#### Output format

`TASK:` lines are tab-separated — **no further `.claude/scripts/dso ticket show` or `classify-task.sh` calls required**:

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
| `SKIPPED_DESIGN_AWAITING: <id> <title>` | Deferred — story tagged `design:awaiting_import` (Figma designs not yet finalized) |

**Parsing `SKIPPED_DESIGN_AWAITING` lines:** After running `sprint-next-batch.sh`, parse any `SKIPPED_DESIGN_AWAITING` lines from the output. For each such line, extract the story ID and title and add them to the `awaiting_design_stories` list (if not already present from Phase 2 filtering). These stories are surfaced in the Phase 5 Batch Completion Summary "Awaiting designer input" section.

Use `--json` for machine-readable output with full detail including file lists.

#### What the script handles (no orchestrator action required)

- **Story-level blocking**: Blocked story → all child tasks deferred
- **File overlap**: Higher-priority task wins; lower defers to next cycle
- **Classification**: TASK lines include `model`, `subagent`, `class` sorted by classify priority then ticket priority
- **Opus cap**: At most 2 `model=opus` tasks per batch; extras deferred

#### Exit condition

If `BATCH_SIZE: 0`, run `.claude/scripts/dso ticket list` to surface the blocking
chain, report to the user, and exit.

#### Dependency-Aware Overlap Analysis (optional, when sg is available)

After running `sprint-next-batch.sh`, use ast-grep (`sg`) for structural dependency
analysis on batch candidates to surface cross-file import relationships that string
search would miss. This supplements — but does not replace — the script's built-in
file-overlap detection.

```bash
if command -v sg >/dev/null 2>&1; then
    # Structural search: find files that import a batch candidate (Python example)
    sg --pattern 'from $MODULE import $_' --lang python .
    sg --pattern 'import $MODULE' --lang python .
    # For bash: find scripts that source a batch candidate
    sg --pattern 'source $PATH' --lang bash .
else
    # Fall back to grep for module-specific import/source patterns
    grep -rn "import $MODULE\|from $MODULE\|source.*$MODULE" --include='*.py' --include='*.sh' .
fi
```

Use the results to identify hidden dependencies between batch candidates. If two
candidates share a cross-file dependency not reflected in their `file_list`, add a
dependency link (`.claude/scripts/dso ticket link <src> <tgt> depends_on`) before
finalizing the batch to avoid parallel conflicts.

#### Double-Failure Detection (per story)

After composing the batch, check each task's parent story against the `story_uncertain_counts` map (initialized in Phase 2 Step 2) **before dispatching**:

1. For each `TASK:` line in the batch output, extract the parent story ID from the `story:<id>` field.
2. Look up `story_uncertain_counts[<story-id>]`. If the count is **>= 2**, do NOT dispatch the task. Instead:
   a. Record the re-plan trigger on the epic **before** invoking implementation-plan (so the audit trail exists even if re-planning fails):
      ```bash
      .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: failure — Story <story-id> had 2+ UNCERTAIN signals. Routing to implementation-plan."
      ```
   b. Re-invoke `/dso:implementation-plan <story-id>` via the Skill tool to re-plan the story.

      <ORCHESTRATOR_RESUME>
      **MANDATORY CONTINUATION — DO NOT STOP HERE.** The implementation-plan skill has returned. You are the sprint orchestrator in Confidence Failure Re-Planning. Continue to step c (record REPLAN_RESOLVED) and then step d (reset counter).
      Stopping here is a known bug (7d7a-b707). Do not stop.
      </ORCHESTRATOR_RESUME>

   c. After re-planning completes, record resolution:
      ```bash
      .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: implementation-plan — Story <story-id> re-planned after confidence failures."
      ```
   d. Reset `story_uncertain_counts[<story-id>] = 0` so the story does not immediately re-trigger on the next batch.
   e. Remove the affected task(s) from the current batch and proceed with the remaining tasks. The re-planned story's new tasks will be picked up in the next batch cycle.
3. Tasks whose parent story has a count of 0 or 1 are dispatched normally.

**Key invariant**: Only `STATUS:pass` + `UNCERTAIN` signals (tracked in Phase 5 Step 1a2) count toward this threshold. `STATUS:fail` tasks are handled via revert-to-open in Phase 5 Step 9 and do not affect this counter.

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

## Phase 4: Sub-Agent Launch (/dso:sprint)

<HARD-GATE>
Do NOT implement any task directly using Edit, Write, or other file-modification tools. ALL implementation tasks must be dispatched to sub-agents via the Task tool — regardless of how small, simple, or obvious the change appears. "Small markdown edit", "single-line change", "user already approved", or "sub-agent dispatch is overhead" are not valid exceptions. Direct implementation by the orchestrator bypasses checkpoint protocol, code review, and acceptance criteria gates.
</HARD-GATE>

**Explore dispatch parallelism rule (7c45-ee60):** When dispatching Explore sub-agents for search tasks, each Explore call MUST be scoped to a single, targeted search objective. Do NOT dispatch a single Explore sub-agent to search for multiple unrelated code patterns, files, or references in one call.

Instead, parallelize: dispatch one Explore sub-agent per distinct search objective within the same message using `run_in_background: true`. For example:
- BAD: Single Explore dispatched to "find isolation guard code AND all references to it"
- GOOD: Two parallel Explore dispatches — one for "find isolation guard code" and one for "find all references to isolation guard"

A single broad Explore dispatch is a known anti-pattern that produces lower quality results and misses edge cases. Always parallelize independent search objectives.

Launch up to `max_agents` sub-agents (determined by Phase 3 Step 1's MAX_AGENTS protocol — `unlimited`, `N`, or `0`) via the Task tool. When `max_agents=0`, this phase is skipped entirely (see Phase 3 Step 1). Each sub-agent gets a structured prompt:

### Display Batch Task List

Print a numbered list of all tasks in the batch. Each line must show the task ID and title:

```
1. [dso-abc1] Fix authentication bug
2. [dso-def2] Add rate limiting to API endpoints
3. [dso-ghi3] Refactor session management
```

Titles are parsed from the `TASK:` tab-separated lines produced by `sprint-next-batch.sh` — the last field in each `TASK:` line is the title. No additional `.claude/scripts/dso ticket show` calls are needed.

### Blackboard Write and File Ownership Context

Before dispatching sub-agents, create the blackboard file and build per-agent file ownership context:

1. **Write the blackboard**: Pipe the batch JSON (from `sprint-next-batch.sh --json` in Phase 3 Step 4) to `write-blackboard.sh`:
   ```bash
   echo "$BATCH_JSON" | .claude/scripts/dso write-blackboard.sh
   ```
   If `write-blackboard.sh` fails, log a warning and continue without blackboard — sub-agents will receive empty `{file_ownership_context}`. Blackboard failure must not block sub-agent dispatch.

2. **Build file ownership context**:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   BLACKBOARD="${TMPDIR:-/tmp}/dso-blackboard-$(basename "$REPO_ROOT")/blackboard.json"
   ```
   For each agent (task), build a `file_ownership_context` string with the format:
   ```
   You own: file1.py, file2.py. Other agents own: <task-id-X> owns file3.py, file4.py; <task-id-Y> owns file5.py.
   ```
   If the blackboard file does not exist, use an empty string for `file_ownership_context`.

3. **Populate the placeholder**: Replace `{file_ownership_context}` in `task-execution.md` with the per-agent ownership string.

### Worktree Isolation Configuration

Before dispatching sub-agents, read and apply `plugins/dso/skills/shared/prompts/worktree-dispatch.md` for worktree isolation configuration.

Read the config key:
```bash
ISOLATION_ENABLED=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config worktree.isolation_enabled 2>/dev/null || true)
```

When `ISOLATION_ENABLED` equals `true`, add `isolation: "worktree"` to each Agent/Task dispatch call and pass `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` in each sub-agent's prompt so sub-agents can verify isolation. When `ISOLATION_ENABLED` is `false`, empty, or absent, omit the `isolation` parameter entirely.

### Design Context Population

Before dispatch, source the figma tag constants and check whether the parent story has the `design:approved` tag:

```bash
# Source tag constants
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}/skills/shared/constants/figma-tags.conf"
# TAG_APPROVED is now set to "design:approved"
```

For each task, look up the parent story's tags (already fetched during COMPLEX detection):

**If parent story has `design:approved` tag:**

> Note: `design:approved` guarantees the revision PNG exists — the approval command (`design-approve.sh`) validates PNG existence before applying the tag. No additional file existence check is needed here.

1. Find the design UUID from story comments — search for a comment whose body matches the pattern `designs/([^/]+)/` (e.g., `"Design Manifest: designs/550e8400-.../manifest.md"`). Extract the UUID from the first capture group. If multiple comments match, use the most recent one.
2. Build the `design_context` string:
   ```
   ## Design Artifacts
   Manifest path: designs/<uuid>/spatial-layout.json
   Revision image path: designs/<uuid>/figma-revision.png
   ```
3. Replace `{design_context}` in `task-execution.md` with this string.
4. Set `STORY_HAS_DESIGN_APPROVED=true` for model tier enforcement (see Subagent Type and Model Selection).

**If parent story does NOT have `design:approved` tag:**

- Replace `{design_context}` in `task-execution.md` with an empty string.
- Set `STORY_HAS_DESIGN_APPROVED=false`. No model override.

### Sub-Agent Prompt Template

For each task, launch a Task with the appropriate `subagent_type`.

**Quality gate (ticket-as-prompt)**: Before dispatch, run the quality check:
```bash
.claude/scripts/dso issue-quality-check.sh <task-id>
```

- **Exit 0 (quality pass)**: Use ticket-as-prompt template (`$PLUGIN_ROOT/skills/sprint/prompts/task-execution.md`), fill in `{id}` and `{escalation_policy}` (see COMPLEX detection and escalation policy extraction below).
- **Exit 1 (too sparse)**: Try `.claude/scripts/dso enrich-file-impact.sh <task-id>`, re-run check. If still failing, fall back to inline prompt via `.claude/scripts/dso ticket show <id>`.

**Acceptance criteria gate**: After the quality gate, run:
```bash
.claude/scripts/dso check-acceptance-criteria.sh <task-id>
```

- **Exit 0**: Proceed with dispatch — task has structured AC block
- **Exit 1**: Do NOT dispatch. Read `${CLAUDE_PLUGIN_ROOT}/docs/ACCEPTANCE-CRITERIA-LIBRARY.md`, compose AC, add via `.claude/scripts/dso ticket comment <id> "## Acceptance Criteria\n<criteria>"`. Re-run check. If criteria undeterminable, ask user.

### Subagent Type and Model Selection

Use the `model` and `subagent` fields from the `TASK:` lines produced by
`sprint-next-batch.sh` in Phase 3 Step 4 — **no additional classify-task.sh call needed**.

When launching each Task tool call, set `subagent_type` and `model` from the TASK line, then apply the decision table below in order (first matching row wins):

| parent_story_has_design_approved | parent_story_complex | task_model | task_class | action |
|----------------------------------|---------------------|------------|------------|--------|
| `true` (revision image present) | any | any | any | Override `model` to minimum `sonnet` (if current model is `haiku`, upgrade to `sonnet`; if already `sonnet` or `opus`, no change). Log: `"design:approved story — enforcing sonnet minimum for multimodal."` |
| any | any | any | any (doc-story title match) | Override `subagent_type` to `dso:doc-writer`, `model` to `sonnet`. Pass `epic_context` and `git_diff` context fields (see Documentation Story Dispatch below). Log: `"Documentation story detected — dispatching to dso:doc-writer instead of generic agent."` |
| any | `COMPLEX` | `sonnet` | `skill-guided` | No model upgrade. Append skill check guidance to prompt (see below). |
| any | `COMPLEX` | `sonnet` | any other | Override `model` to `opus`. Log: `"Story <parent-id> classified COMPLEX — upgrading task <task-id> model to opus."` |
| any | `COMPLEX` | `opus` | any | No change (already opus). |
| any | not COMPLEX | any | `skill-guided` | No model upgrade. Append skill check guidance to prompt (see below). |
| any | not COMPLEX | any | any other | No change — use `model` and `subagent` from TASK line as-is. |

**Doc-story title match**: Task title or parent story title matches `Update project docs to reflect`.

**Doc-story detection heuristics (apply ALL of these — not just title match):**
A story is a documentation story if ANY of the following are true:
1. Story title contains "doc", "document", "update", "add to", "CLAUDE.md", "KNOWN-ISSUES", "design-notes", "README"
2. Story title starts with "As a" AND acceptance criteria mention documentation files
3. Any child task references a `.md` file in `.claude/docs/`, `plugins/dso/docs/`, or the repo root

**CLAUDE.md-specific rule (79d9-f97a):** When the target file is `CLAUDE.md`, the `dso:doc-writer` dispatch MUST include a bloat-review flag in the task context:
```
doc_target: CLAUDE.md
bloat_review_required: true
max_tokens_budget: 12000
```
The doc-writer agent enforces its CLAUDE.md Read-Only Guard. Do NOT edit CLAUDE.md directly — always route through dso:doc-writer. Direct CLAUDE.md edits are blocked by this rule.

**COMPLEX detection and escalation policy extraction**: Run `.claude/scripts/dso ticket show <task-id>` and read the `parent` field; if a parent story ID exists, run `.claude/scripts/dso ticket show <parent-story-id>` and from that output: (1) grep with `grep -Fx "COMPLEXITY_CLASSIFICATION: COMPLEX"` (exact full-line match to avoid false positives); (2) extract the `## Escalation Policy` section by capturing all lines between `## Escalation Policy` and the next `##` heading (or end of description). Store the extracted text as `escalation_policy_text`. If no `## Escalation Policy` section is present (Autonomous mode omits it), set `escalation_policy_text` to `"Proceed with best judgment. Make and document reasonable assumptions. Do not escalate for uncertainty."` When populating `task-execution.md`, replace `{escalation_policy}` with `escalation_policy_text`.

**Skill check guidance** (appended to prompt when `class` is `skill-guided`): `"Before implementing, check if a skill applies to this task type (e.g., /writing-skills for skill files, /claude-md-improver for CLAUDE.md updates, /writing-rules for hookify rules)."`

### Documentation Story Dispatch

When the doc-story title match triggers, the doc-writer agent receives two named context fields:
```
subagent_type: "dso:doc-writer"
model: "sonnet"
context:
  epic_context: |
    ## Epic ID
    <epic-id>

    ## Story Descriptions
    <full output of `.claude/scripts/dso ticket show <epic-id>`>

  git_diff: |
    <full output of `git diff main...HEAD`>
```

**Agent description**: 3-5 word summary from ticket title (e.g., Fix review gate hash).

**Important**: Launch ALL sub-agents in the batch within a single message, each with `run_in_background: true`. The number of Task calls is governed by `max_agents` from Phase 3 Step 1 (unlimited = all candidates, N = cap at N, 0 = skip dispatch).

**Worktree boundary**: If in a worktree, append to every sub-agent prompt: `"IMPORTANT: Only modify files under $(git rev-parse --show-toplevel). Do NOT write to any other path."` When `ISOLATION_ENABLED=true`, also add `isolation: "worktree"` to the Task dispatch call (see Worktree Isolation Configuration above).

### Testing Mode Routing

Before dispatching sub-agents, extract the `## Testing Mode` value from each task's description:

```bash
TASK_DESC=$(.claude/scripts/dso ticket show <task-id>)
TESTING_MODE=$(echo "$TASK_DESC" | python3 -c "
import sys, re
desc = sys.stdin.read()
m = re.search(r'## Testing Mode\s*\n([^\n#]+)', desc)
print(m.group(1).strip() if m else '')
")
```

Route based on `TESTING_MODE`:

| testing_mode value | Action |
|--------------------|--------|
| `RED` | Dispatch `dso:red-test-writer` before implementation (existing behavior) |
| `GREEN` | Skip RED test dispatch entirely. Sub-agent validates existing tests pass after implementation. |
| `UPDATE` | Sub-agent modifies existing tests to assert new behavior **before** implementing. Do NOT dispatch `dso:red-test-writer`. |
| absent / empty | Default to RED behavior (backward compatibility — tasks created before this field was introduced) |

**GREEN mode**: Pass the following instruction to the sub-agent's Step 4 in `task-execution.md`: skip writing new tests; after implementation, validate that existing tests still pass.

**UPDATE mode**: Pass the following instruction to the sub-agent's Step 4 in `task-execution.md`: modify the existing test file(s) listed in the file impact table to assert the new expected behavior before implementing the source change. The test must fail (RED) on the current code before the fix.

**Backward compatibility**: When `TESTING_MODE` is absent or empty, treat as `RED` — dispatch `dso:red-test-writer` as normal.

---

### RED Task Dispatch — Escalation Protocol

**Detect RED tasks**: Check whether the `subagent` field equals `dso:red-test-writer`.

**When `subagent` = `dso:red-test-writer`**, do NOT use normal dispatch. Follow `prompts/red-task-escalation.md`:

**Tier 1 — Dispatch `dso:red-test-writer` (sonnet)**:
- Pass the full task context: task description, story context, and file impact table
- Parse the leading `TEST_RESULT:` line from the output:
  - `TEST_RESULT:written` → Success. Proceed to TDD setup using `TEST_FILE` and `RED_ASSERTION` fields. Do NOT escalate.
  - `TEST_RESULT:no_new_tests_needed` → Success. No new test was needed. Do NOT escalate to Tier 2. Proceed to normal task execution without TDD setup.
  - `TEST_RESULT:rejected` → Escalate to Tier 2. This is **not** a dispatch failure — do not route to Phase 5 Step 0.
  - Timeout / malformed / non-zero exit → Treat as `TEST_RESULT:rejected` with `REJECTION_REASON: ambiguous_spec`. Escalate to Tier 2.

**Tier 2 — Dispatch `dso:red-test-evaluator` (opus)**:
- Pass: (1) the full `TEST_RESULT:rejected` payload verbatim, and (2) the orchestrator context envelope:
  ```
  TASK_ID: <task_id>
  STORY_ID: <story_id>
  EPIC_ID: <primary_ticket_id>
  PRIMARY_TICKET_ID: <primary_ticket_id>
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
- Pass the same task context as Tier 1, augmented with the evaluator's `VERDICT:REJECT` payload
- Parse the leading `TEST_RESULT:` line:
  - `TEST_RESULT:written` → Success. Proceed to TDD setup normally.
  - `TEST_RESULT:no_new_tests_needed` → Success. No new test was needed. Do NOT escalate to Tier 2. Proceed to normal task execution without TDD setup.
  - `TEST_RESULT:rejected` → Terminal failure. Escalate to the user with: the Tier 1 rejection payload, the Tier 2 `VERDICT:REJECT` reason, and the Tier 3 rejection payload. Do not retry further.
  - Timeout / malformed / non-zero exit → Terminal failure. Escalate to the user.

See `prompts/red-task-escalation.md` for the complete escalation reference.

---

## Phase 5: Post-Batch Processing (/dso:sprint)

After ALL sub-agents in the batch return, follow the Orchestrator Checkpoint Protocol from CLAUDE.md.

### Worktree Isolation Mode: Per-Worktree Serial Review and Commit

**When `worktree.isolation_enabled` is `true` and sub-agents returned with `isolation:worktree`**, do NOT proceed to the shared-directory batch review flow (Step 7). Instead, process each worktree **serially** using the per-worktree protocol:

Read and execute `plugins/dso/skills/sprint/prompts/per-worktree-review-commit.md` for each worktree, in completion order (first-pass-first-merge). This means: for each worktree — run review in the worktree context, commit to the worktree branch, merge the worktree branch into the session branch — before moving to the next worktree.

**Git log note**: In worktree isolation mode, `git log` on the session branch shows one commit per worktree (no combined batch commits). Each worktree's changes are merged independently into the session branch.

**merge-to-main.sh note**: `merge-to-main.sh` runs **once** at session end (Phase 8), not per worktree. Each per-worktree merge is worktree-branch → session-branch only.

After all worktrees have been processed via `per-worktree-review-commit.md`, skip Steps 7 and 10 (which apply only in shared-directory mode) and proceed directly to Steps 8, 9, 10a, 11, and 13.

**When `worktree.isolation_enabled` is `false`, empty, or absent** (shared-directory mode), proceed through Steps 0–13 as written below, including Step 7 (formal code review) and Step 10 (commit and push).

### Step 0: Dispatch Failure Recovery (/dso:sprint)

Check whether any sub-agent Task call returned an **infrastructure-level dispatch failure** (no `STATUS:` line, no `FILES_MODIFIED:` line, error message references agent type/tool availability/internal errors).

**RED test task exception**: If the failed task's `subagent` field was `dso:red-test-writer`, do NOT fall back to `general-purpose`. A `TEST_RESULT:rejected` response triggers the three-tier escalation protocol (Phase 4 RED Task Dispatch). Only true dispatch failures (no `TEST_RESULT:` line, no `STATUS:` line, tool-level error indicators) qualify for the recovery flow below.

**For each sub-agent that returned a dispatch failure:**

1. **Detect**: The Task result contains no `STATUS:` or `FILES_MODIFIED:` lines AND includes error indicators (e.g., "unknown subagent_type", "agent unavailable", "internal error", "Tool result missing")
2. **Retry with general-purpose**: Re-dispatch the same task immediately using `subagent_type="general-purpose"` with the same model and prompt. Log: `"Dispatch failure for task <id> with subagent_type=<original-type> — retrying with general-purpose."`
3. **If retry succeeds**: Continue to Step 1 with the retry result
4. **If retry also fails**: Escalate model (sonnet → opus) and retry once more with `subagent_type="general-purpose"`. Log: `"Retry with general-purpose also failed for task <id> — escalating model to opus."`
5. **If all retries fail**: Mark the task as failed and proceed to Step 9

**Important**: Dispatch failure retries happen sequentially. Do not count retries toward the `max_agents` cap.

### Step 1: Verify Results (/dso:sprint)

For each sub-agent (including any that succeeded on retry), check the Task tool result:
- Did it report success?
- Are the expected files present? (spot-check with Glob)
- Were tests passing?

### Step 1a: Migration Behavioral Verification (/dso:sprint)

For each sub-agent in the batch, check if its task description contains migration keywords (`remove`, `delete`, `migrate`, `move`, `replace`). For migration tasks:

1. **Verify the replacement exists**: Run the first task-specific AC `Verify:` command. If it fails, mark the task as failed.
2. **Behavioral smoke test**: If the task migrates a command/skill/script, invoke or test the migrated artifact. Log: `"Migration behavioral check for <task-id>: <pass|fail>"`

### Step 1a2: Confidence Signal Parsing (/dso:sprint)

For each sub-agent result, scan for the confidence signal line (see `plugins/dso/docs/contracts/confidence-signal.md`): # shim-exempt: internal contract reference

1. **Parse the confidence signal**: Scan the sub-agent output for a line that is exactly `CONFIDENT` or begins with `UNCERTAIN:`.
   - `CONFIDENT` — high confidence; no action needed beyond normal processing.
   - `UNCERTAIN:<reason>` — low confidence; proceed to steps below.
   - **Absent or malformed signal** (no confidence line, bare `UNCERTAIN` with no colon, `UNCERTAIN:` with empty reason) — treat as `UNCERTAIN` with reason `"no confidence signal emitted"`. Log a warning: `"Warning: task <task-id> emitted no valid confidence signal — treating as UNCERTAIN."`

2. **Only count `STATUS:pass` + `UNCERTAIN` signals toward the threshold.** `STATUS:fail` tasks already trigger revert-to-open in Step 9 through the normal failure path — the UNCERTAIN signal on a failing task does not change routing.

3. **For each task where `STATUS:pass` + `UNCERTAIN`:**
   a. Identify the parent story ID from the task's `story:<id>` field in the TASK line (from Phase 4 batch list).
   b. Record the signal: `.claude/scripts/dso ticket comment <story-id> "UNCERTAIN_SIGNAL: task <task-id> — <reason>"`
   c. Increment the per-story counter: `story_uncertain_counts[<story-id>] += 1` (initialize to 0 if not yet set).
   d. Log: `"UNCERTAIN signal from task <task-id> under story <story-id> — count now <N>."`

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

### Step 1c: Collect Agent Discoveries (/dso:sprint)

Collect structured discovery files from sub-agent execution (propagated to next batch via `{prior_batch_discoveries}` in Phase 3 Step 4).

```bash
DISCOVERIES=$(.claude/scripts/dso collect-discoveries.sh 2>/dev/null) || DISCOVERIES="[]"
```

- If `collect-discoveries.sh` succeeds, `DISCOVERIES` contains a JSON array of discovery objects
- Store the result for use in Phase 3 Step 4 when composing the next batch's sub-agent prompts
- **Graceful degradation**: If discovery collection fails (script error, malformed JSON), log a
  warning and continue with `DISCOVERIES="[]"`. Discovery collection failure must not block the
  sprint. The script itself handles per-file validation — malformed individual files are skipped
  with warnings to stderr.

### Step 2: Acceptance Criteria Validation (/dso:sprint)

**Batched shared criteria** (run ONCE per batch, not per-task):
Universal criteria (test, lint, format) are already verified by Phase 5 Step 4
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

Print a completion summary. Each line must show the task ID, title, and pass/fail result:

```
✓ [dso-abc1] Task title (pass)
✗ [dso-abc2] Other task (fail — reverted to open)
```

Titles are retained from the pre-launch batch list printed in Phase 4 — no additional `.claude/scripts/dso ticket show` calls are needed.

#### Awaiting Designer Input Section

After the per-task completion lines, if `awaiting_design_stories` is non-empty, print a blocked status section:

```
Awaiting designer input:
  - [<story-id>] <story-title> (awaiting since <date>)
  - [<story-id>] <story-title> (awaiting since <date>) ⚠️ STALE (><figma_staleness_days> days)
```

**Staleness logic:**
- For each story in `awaiting_design_stories`, compute tag age in days from `tag_applied_date` to today.
- If `tag_applied_date` is unknown, omit the staleness warning for that story.
- If tag age exceeds `figma_staleness_days` (read from `design.figma_staleness_days` in `.claude/dso-config.conf`, default 7), append ` ⚠️ STALE (>N days)` to that story's line.
- Stories in this section are **not** counted as batch failures — they are explicitly blocked pending designer delivery.

These stories are excluded from Phase 2 implementation-plan dispatch and Phase 4 sub-agent dispatch. They are surfaced here to give the user visibility into what is blocked on design. No action is required from the orchestrator — the sprint continues with non-blocked stories.

### Step 3: File Overlap Check (Safety Net) (/dso:sprint)

Check for actual file conflicts before committing:

1. For each sub-agent, collect its modified files from the Task result
2. Run the overlap detection script:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh file-overlap \  # shim-exempt: internal orchestration script
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
batch's combined diff:

```bash
SEMANTIC_RESULT=$(git diff | python3 "$PLUGIN_SCRIPTS/semantic-conflict-check.py" 2>/dev/null) || SEMANTIC_RESULT='{"conflicts":[],"clean":true,"error":"script failed"}'  # shim-exempt: internal orchestration script
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
$PLUGIN_SCRIPTS/validate-phase.sh post-batch  # shim-exempt: internal orchestration script
```

If validation fails, identify which sub-agent's code is broken and note it.

#### Test Failure Sub-Agent Delegation (Phase 5 Step 4)

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

- **Pass** → proceed
- **Fail** → Use `/dso:playwright-debug` Tier 2. If still failing, revert task to open.
- **No baselines** → Use `/dso:playwright-debug` full 3-tier. Verify local env: `$PLUGIN_SCRIPTS/check-local-env.sh`.  # shim-exempt: internal orchestration script

### Step 7: Formal Code Review (/dso:sprint) — Shared-Directory Mode Only

**This step applies only when `worktree.isolation_enabled` is `false` (shared-directory mode).** When worktree isolation is enabled, review is handled per-worktree via `per-worktree-review-commit.md` (see Worktree Isolation Mode section at the top of Phase 5). Skip this step in worktree isolation mode.

Execute the review workflow (REVIEW-WORKFLOW.md). If already read earlier in this conversation, use the version in context. Produces a review state file at `$(get_artifacts_dir)/review-status`.

**Do NOT dispatch any `dso:code-reviewer-*` agent directly.** You MUST execute REVIEW-WORKFLOW.md Step 3 first to obtain `REVIEW_TIER` and `REVIEW_AGENT` from the complexity classifier before dispatching. Hardcoding `dso:code-reviewer-light` or any other tier is prohibited — the classifier determines the tier based on diff characteristics.

**Snapshot exclusion**: Exclude snapshot baselines from review diffs:
```bash
".claude/scripts/dso capture-review-diff.sh" "$DIFF_FILE" "$STAT_FILE" \
  ':!app/tests/unit/templates/snapshots/*.html'
```

**Interpret results:**
- **No Critical or Important issues** (all scores >= 4) → proceed to Step 8
- **Critical or Important issues found** (any score < 4, OR any critical/important finding regardless of score) → Enter Autonomous Resolution Loop per REVIEW-WORKFLOW.md. No inline fixes by orchestrator. Failed tasks: revert to open, add issue details, re-run with reviewer feedback. **Score=3 with important findings is NOT a pass — do NOT suggest graceful shutdown or proceed to commit. Apply the fix or escalate.**
- **Minor issues only** → proceed (note them in ticket but don't block)
- **Autonomous resolution**: Up to `review.max_resolution_attempts` (default: 5) fix/defend attempts before tier escalation (light → standard → deep). When attempts are exhausted, upgrade to the next tier before escalating to user — the deep tier (3 sonnet + opus synthesis) must be tried before user escalation. Resolution sub-agent applies fixes, then orchestrator dispatches separate re-review sub-agent (no nesting). If issues persist after deep tier, escalate to the user — do NOT commit or initiate graceful shutdown. The review loop continues until the review passes OR the user explicitly approves proceeding.

> **CONTEXT ANCHOR**: When REVIEW_RESULT: passed is received from the review sub-agent, this is NOT a session completion signal. Proceed immediately to Step 7a → Step 8 → Step 9 → Step 10. Do NOT stop, wait for user input, or treat review completion as a stopping point.

### Step 7a: Out-of-Scope Review Feedback Detection (/dso:sprint)

After review resolution completes (Step 7) and before proceeding to Step 8, check whether accepted review findings reference files outside the task's scope.


For each task in the batch that completed review:

1. Run `sprint-review-scope-check.sh` with the reviewer-findings path and task ID:
   ```bash
   SCOPE_RESULT=$(.claude/scripts/dso sprint-review-scope-check.sh "$(get_artifacts_dir)/reviewer-findings.json" "<task-id>")  # shim-exempt: internal orchestration script
   ```
2. If `SCOPE_RESULT` starts with `OUT_OF_SCOPE`:
   a. Parse the out-of-scope file list (everything after `OUT_OF_SCOPE: `).
   b. Log: `"Review accepted findings for out-of-scope files: <files> (task <task-id>)"`
   c. Append to the accumulator:
      ```
      batch_out_of_scope_findings.append({
          "task_id": "<task-id>",
          "story_id": "<parent-story-id>",
          "files": [<out-of-scope files>]
      })
      ```
   d. **DO NOT route to implementation-plan here.** Out-of-scope findings are collected during the batch and processed only between batches (Step 13) to avoid mid-batch task injection conflicts.
3. If `IN_SCOPE` → no action needed; proceed normally.
4. If the script fails (non-zero exit) → log a warning and continue. Scope checking failure must not block the sprint.

### Step 8: Update Ticket Notes (/dso:sprint)

For each task in the batch, write checkpoint-format notes for crash recovery:

| Outcome | Command |
|---------|---------|
| Success | `.claude/scripts/dso ticket comment <id> "CHECKPOINT:batch-complete — Done ✓ — Files: <files created/modified>. Tests: pass."` |
| Failure (pre-review) | `.claude/scripts/dso ticket comment <id> "CHECKPOINT:implementation-done — Failed at review — <error summary>. Files modified: <files>. Resume from: review."` |
| Failure (post-review) | `.claude/scripts/dso ticket comment <id> "CHECKPOINT:review-passed — Failed at validation — <error summary>. Resume from: validation."` |

Use semantic checkpoint names to describe progress phase:
- `CHECKPOINT:implementation-done` — code written, not yet reviewed
- `CHECKPOINT:review-passed` — code reviewed, not yet validated
- `CHECKPOINT:validation-passed` — batch validation passed
- `CHECKPOINT:batch-complete` — all substeps done

### Step 9: Handle Failures (/dso:sprint)

For tasks that failed:
- Revert to open: `.claude/scripts/dso ticket transition <id> open`
- Record the failure reason in notes (already done in Step 8)

### Step 10: Commit & Push (/dso:sprint) — Shared-Directory Mode Only

**This step applies only when `worktree.isolation_enabled` is `false` (shared-directory mode).** When worktree isolation is enabled, commits are made per-worktree via `per-worktree-review-commit.md` (see Worktree Isolation Mode section at the top of Phase 5). Skip this step in worktree isolation mode.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md`.

**HARD-GATE — reject signal**: When the review complexity classifier emits `SIZE_ACTION=reject` (diff exceeds 600 lines), you MUST NOT override this signal. You have exactly two options:
1. Split the batch: identify independent subsets of changes, commit them separately, and review each subset
2. Escalate to user: present the reject signal and ask how to proceed

Any rationalization for overriding reject ("these changes are related", "splitting would break functionality", "this is a single logical change") is prohibited. The reject threshold exists because reviewers cannot effectively review diffs above this size.

Push the worktree branch:

```bash
git push -u origin HEAD
```

Do NOT merge to main here.

**Blackboard cleanup**: After the commit, run `write-blackboard.sh --clean` to remove the blackboard file:
```bash
.claude/scripts/dso write-blackboard.sh --clean
```

<HARD-GATE>
Do NOT proceed to Step 11 until Step 10a (completion-verifier dispatch) has completed and returned an overall_verdict. The orchestrator is biased toward confirming its own work — CLAUDE.md rule 24 exists because this step has been skipped in past sessions. "All tests pass" and "all tasks closed" do NOT substitute for independent verification.

Do NOT rationalize skipping Step 10a. Prior evidence ("RED tests are GREEN", "CI passes", "AC verified") does not satisfy the completion-verifier requirement. The verifier checks done-definitions that task-level AC verification does not cover.

Do NOT use the `/dso:commit` Skill tool here — read and execute COMMIT-WORKFLOW.md inline to avoid nested skill invocations that may not return control.
</HARD-GATE>

After `git push -u origin HEAD` and blackboard cleanup are done, proceed to **Step 10a** then Step 11 then Step 13. Do NOT close the epic or invoke `/dso:end-session` here.

> **CONTINUE:** After commit and push, proceed immediately to Step 10a. Do NOT stop, wait for user input, or initiate graceful shutdown here.

### Step 10a: Close Completed Tasks (/dso:sprint)

After the batch commit and `git push -u origin HEAD` succeed, close each task whose code was successfully committed:

**Pre-dispatch child closure check (Step 10a prerequisite):**
Before dispatching dso:completion-verifier, verify all child tasks of this story are closed:

```bash
OPEN_CHILDREN=$(.claude/scripts/dso ticket list --status=open 2>/dev/null | \
    python3 -c "import json,sys; data=json.load(sys.stdin); \
    children=[t for t in data if t.get('parent_id')=='<story-id>']; \
    print(len(children))")
```

If OPEN_CHILDREN > 0:
- Do NOT dispatch dso:completion-verifier
- Do NOT close the story
- Transition story back to in_progress: `.claude/scripts/dso ticket transition <story-id> in_progress`
- Add a comment: `.claude/scripts/dso ticket comment <story-id> "Step 10a blocked: <N> child tasks still open: <list IDs>. Complete them before closure."`
- Resume Phase 3 to close the remaining tasks

Only when OPEN_CHILDREN == 0, proceed to dispatch dso:completion-verifier.

<HARD-GATE>
Do NOT close this story, do NOT transition it to closed, and do NOT proceed to Step 11 until dso:completion-verifier has been dispatched via Task tool and its verdict received. This gate applies regardless of whether:
- All RED tests are GREEN
- All child tasks are closed
- CI passes
- The orchestrator believes the story is complete

"All tests pass" is not a substitute for the completion-verifier dispatch. Dispatch the verifier NOW before reading any further.
</HARD-GATE>

**MANDATORY**: Dispatch `subagent_type: "dso:completion-verifier"` (model: sonnet) with the story ID (CLAUDE.md rule #24 — no inline verification substitute).
- `overall_verdict: PASS` → proceed with closure
- `overall_verdict: FAIL` → see branching logic below
- **Fallback (agent unavailable)**: If dispatch fails with "Agent type not found" or "Unknown agent", fall back per CLAUDE.md Agent fallback rule — dispatch `subagent_type: general-purpose` and read `plugins/dso/agents/completion-verifier.md` inline as the system prompt. This is NOT permission to skip the step.
- **Fallback (technical failure only)**: On timeout/unparseable JSON, log warning and proceed with closure.

**Story validation failure detection** — when `overall_verdict: FAIL`:

Check whether all tasks under the story are closed (no open or in-progress tasks remain):

- **If open/in-progress tasks still exist**: create bug tasks from `remediation_tasks_created` and return to Phase 3 (Batch Preparation) as normal.
- **If all tasks are closed but validation fails** (story-level done definition not satisfied despite no remaining tasks):
  1. Do NOT close the story.
  2. Log: `"Story <id> validation failed despite all tasks closed — creating TDD remediation tasks"`
  3. Record a REPLAN_TRIGGER comment on the epic **before** invoking implementation-plan (so the audit trail exists even if re-planning fails):
     ```bash
     .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: validation — Story <story-id> validation failed with all tasks closed. Creating TDD remediation tasks."
     ```
  4. Re-invoke `/dso:implementation-plan <story-id>` via the Skill tool on the story to create remediation tasks. The implementation-plan re-invocation guard will detect existing closed children and produce a diff plan (new tasks only for uncovered success criteria — no duplication). **If implementation-plan emits `REPLAN_ESCALATE: brainstorm`**: add the story to the `replan-stories` list and route to **d-replan-collect** (Phase 2 replan logic). The cascade counter (`sprint.max_replan_cycles`) applies — if the cap is reached, escalate to the user. Do NOT assume implementation-plan always succeeds here.

     <ORCHESTRATOR_RESUME>
     **MANDATORY CONTINUATION — DO NOT STOP HERE.** The implementation-plan skill has returned. You are the sprint orchestrator in Story Validation Failure handling (Step 10a). Continue to step 5 (TDD remediation tasks) and then step 6 (record REPLAN_RESOLVED), then return to Phase 3.
     Stopping here is a known bug (7d7a-b707). Do not stop.
     </ORCHESTRATOR_RESUME>

  5. Implementation-plan will create TDD remediation tasks following standard flow: RED test task first (failing test targeting the unmet done definition), then implementation task depending on the RED test. No special logic is needed in sprint to enforce this ordering.
  6. After re-planning completes (no REPLAN_ESCALATE), record resolution:
     ```bash
     .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: implementation-plan — Remediation tasks created for story <story-id>."
     ```
  7. Return to Phase 3 (Batch Preparation) to execute the new remediation tasks.

<HARD-GATE>
Do NOT rationalize around a FAIL verdict. The verifier's verdict is final — scope-scoping arguments ("pre-existing failures," "out-of-scope tests," "RED marker tolerance," "already tracked as a separate bug") do not override the FAIL → Phase 3 path. The orchestrator's judgment about whether the FAIL "really applies" is exactly the bias the verifier was designed to counteract. Only `overall_verdict: PASS` or technical failure (timeout/unparseable JSON) permits proceeding past this step.
</HARD-GATE>

**RED marker cleanup (before closure)**: After `overall_verdict: PASS`, check `.test-index` for stale RED markers associated with tests from this story's scope. If any `[test_name]` entries exist for tests that now pass (GREEN), remove them before closing the story. Stale markers accumulate across story completions and block epic closure.

```bash
# Check for stale RED markers
grep -n "\[.*\]" .test-index || true
# Remove any markers for tests that are now passing
```

```bash
.claude/scripts/dso ticket comment <id> "Fixed: <summary>"
.claude/scripts/dso ticket transition <id> open closed
```

Do NOT close tasks that are still open or in a failed state.

### Step 11: Context Compaction Check (/dso:sprint)

Between batches — after all work is committed and pushed — check whether the session context is at least 70% capacity.

Run the context check:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
context_exit=0
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh context-check || context_exit=$?  # shim-exempt: internal orchestration script
# context_exit: 0=normal, 10=medium, 11=high
```

| Output | Exit Code | Meaning | Action |
|--------|-----------|---------|--------|
| `CONTEXT_LEVEL: normal` | 0 | <70% usage | Proceed to Step 13 normally |
| `CONTEXT_LEVEL: medium` | 10 | 70–90% usage | Compact before next batch (see below) |
| `CONTEXT_LEVEL: high` | 11 | >90% usage | Compact before next batch |

**Detection signals**: `CLAUDE_CONTEXT_WINDOW_USAGE` env var (if set by Claude Code) and `$HOME/.claude/check-session-usage.sh`. If neither is available, self-assess based on accumulated context. When in doubt after multiple batches, prefer compacting.

**If `CONTEXT_LEVEL: medium` or `high`** (or Claude self-assesses as >=70%):

1. Log: `"Context usage >=70% — compacting before batch N+1 to prevent mid-work compaction."`
2. Verify the working tree is clean: `git status --short` (all work must be committed before compacting)
3. Write a compact-intent state file. Use the actual epic ID (e.g., `LPL-42`):
   ```bash
   echo "voluntary" > "${TMPDIR:-/tmp}/sprint-compact-intent-<actual-epic-id>"
   ```
   **Important**: Note the epic ID explicitly in the log message — e.g., `"Compacting before batch N+1 for epic LPL-42."` — the epic ID must survive compaction.
4. Invoke compaction:
   ```
   /compact
   ```
5. After compaction, check for `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>`. **Continue directly to Phase 3.** Do NOT go to Phase 8.
6. **Agent-count after compact**: No special action needed — Phase 3 Step 1's pre-check re-evaluates `MAX_AGENTS` (may return `unlimited`, `N`, or `0`) automatically.

---

### Step 13: Continuation Decision (/dso:sprint)

#### Step 13a: Out-of-Scope Review Feedback Routing (between batches)

Before evaluating the continuation decision, process any out-of-scope review findings collected during the batch (Step 7a). This fires ONLY between batches — never mid-batch.

If `batch_out_of_scope_findings` is non-empty:

1. Deduplicate by story: group all out-of-scope files by `story_id`.
2. For each affected story:
   a. Collect the full list of out-of-scope files across all tasks in that story.
   b. Record the re-plan trigger on the epic **before** invoking implementation-plan (so the audit trail exists even if re-planning fails):
      ```bash
      .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: review — Out-of-scope files from review: <files>. Routing to implementation-plan for story <story-id>."
      ```
   c. **Check the cascade cycle cap before invoking implementation-plan:**
      - **If `replan_cycle_count >= max_replan_cycles`:** Cap is exhausted. Present the out-of-scope files and inform the user the cascade limit has been reached:
        ```
        Out-of-scope review files require re-planning for story <story-id>:
          <file list>

        The cascade replan limit (max_replan_cycles=<N>) has been reached.
        Options:
          (a) Proceed — skip re-planning for these files and continue sprint execution
          (b) Abort — stop the sprint for this epic; it will remain open for manual adjustment
          (c) Manual adjustment — edit the relevant story or epic tickets manually, then resume the sprint
        ```
        Wait for user input. Act on their choice. Do NOT invoke implementation-plan.
      - **If cap is not yet exhausted:** proceed to step d.
   d. Invoke `/dso:implementation-plan <story-id>` via the Skill tool to create tasks covering the out-of-scope files.

      <ORCHESTRATOR_RESUME>
      **MANDATORY CONTINUATION — DO NOT STOP HERE.** The implementation-plan skill has returned. You are the sprint orchestrator in Out-of-Scope Review Feedback Routing (Step 13a). Continue to step e (handle REPLAN_ESCALATE) and then step f (record resolution).
      Stopping here is a known bug (7d7a-b707). Do not stop.
      </ORCHESTRATOR_RESUME>

   e. **Handle REPLAN_ESCALATE:** If implementation-plan emits `REPLAN_ESCALATE: brainstorm`: add the story and its explanation to the `replan-stories` list (processed in step 2a below).
   f. After re-planning completes (no REPLAN_ESCALATE), record resolution:
      ```bash
      .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: implementation-plan — Tasks created for out-of-scope review feedback on story <story-id>."
      ```
2a. **Handle collected REPLAN_ESCALATE stories** — if any stories were added to the `replan-stories` list during step 2e above:
   - **Non-interactive mode check** (before all other steps): If the session is non-interactive, do NOT block for user input. For each story in the replan-stories list, record:
     ```bash
     .claude/scripts/dso ticket comment <epic-id> "INTERACTIVITY_DEFERRED: brainstorm — implementation-plan emitted REPLAN_ESCALATE for story <story-id>: <explanation>. Re-run sprint interactively to address."
     ```
     Skip the brainstorm cascade entirely. Do NOT write `REPLAN_RESOLVED`. Continue to step 3 below (clear accumulator and return to Phase 3). See `plugins/dso/docs/contracts/replan-observability.md` for the INTERACTIVITY_DEFERRED signal format. # shim-exempt: internal documentation reference
   - **If `replan_cycle_count >= max_replan_cycles`:** Present the **cap-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "skip re-planning for these stories and continue sprint execution".
   - **If cap is not yet exhausted:** Present the **cap-not-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "accept the current state and continue sprint with these stories as-is".
     - **If user selects (b) or (c):** act accordingly — proceed or abort. Do not enter cascade.
     - **If user selects (a):** Enter the cascade replan per `plugins/dso/docs/designs/cascade-replan-protocol.md`: # shim-exempt: internal documentation reference
       1. Invoke `/dso:brainstorm <epic-id>` via Skill tool
       2. Delete `/tmp/preplanning-context-<epic-id>.json` (invalidate stale preplanning cache)
       3. Invoke `/dso:preplanning <epic-id>` via Skill tool
       4. Increment `replan_cycle_count += 1`
       5. Re-run `/dso:implementation-plan` for all affected stories
       6. If no more `REPLAN_ESCALATE`: write the resolved signal, then cascade exits — proceed normally:
          ```bash
          .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: brainstorm — Stories re-planned after brainstorm cascade."
          ```
       7. If `REPLAN_ESCALATE` persists: repeat from 2a (check cap first)
3. Clear the accumulator: `batch_out_of_scope_findings = []`
4. Return to Phase 3 (Batch Preparation) to include the newly created tasks.

If `batch_out_of_scope_findings` is empty, proceed to the standard continuation decision below.

#### Step 13b: Standard Continuation Decision

```
Decision: Involuntary compaction detected? → Yes: P8 (Graceful Shutdown)
          → No: More ready tasks? → Yes: Return to P3
                                  → No: P6 (Validation)
```

**Voluntary vs involuntary compaction**: If `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>` exists, delete it and continue to Phase 3. If no intent file exists, the compaction was involuntary — go to Phase 8.

- If **involuntary** context compaction has occurred (no intent file) → Phase 8 (graceful shutdown)
- If more ready tasks exist (`.claude/scripts/dso ticket list` filtered by parent) → return to Phase 3
- If no more ready tasks and some tasks are still blocked → report blocking chain, Phase 8
- If all tasks are closed → **Phase 6 is MANDATORY** — proceed to Phase 6 (validation). Phase 6 has a HARD-GATE requiring completion-verifier dispatch (Step 0.75) before any other Phase 6 step executes. Do NOT skip the Phase 6 HARD-GATE.

---

## Phase 6: Post-Primary Ticket Validation (/dso:sprint)

**Triggered when**: all child tasks are closed (or all remaining are failed/blocked).

<HARD-GATE>
Do NOT execute any Phase 6 step until Step 0.75 (completion-verifier dispatch) has completed and returned an overall_verdict for the epic. Do NOT skip Step 0.75 because "all stories are closed" or "all tasks passed" — those are orchestrator-level observations, not independent verification. CLAUDE.md rule 24: the verifier exists because the orchestrator is biased toward confirming its own work.

Do NOT proceed to Step 1 (/dso:validate-work) or Phase 8 (Session Close) without the completion-verifier result. Phase 6 steps must execute in order: Step 0.75 → Step 1 → Step 2 → Step 3 → Step 4 → Step 5.
</HARD-GATE>

### Steps 0 through 0.5: Integration Test Gate, CI Verification, and E2E Tests

Read and execute `prompts/phase6-ci-gates.md` for the integration test gate, CI verification, and E2E testing. After completing those steps, proceed to Step 0.75 below.

### Step 0.75: Completion Verification (/dso:sprint)

**MANDATORY**: Dispatch `subagent_type: "dso:completion-verifier"` (model: sonnet) with the epic ID (CLAUDE.md rule #24).
- `overall_verdict: PASS` → proceed to Step 1
- `overall_verdict: FAIL` → create bug tasks from `remediation_tasks_created`, return to Phase 3 (Batch Preparation)
- **Fallback (agent unavailable)**: If dispatch fails with "Agent type not found" or "Unknown agent", fall back per CLAUDE.md Agent fallback rule — dispatch `subagent_type: general-purpose` and read `plugins/dso/agents/completion-verifier.md` inline as the system prompt. This is NOT permission to skip the step.
- **Fallback (technical failure only)**: On timeout/unparseable JSON, log warning and proceed to Step 1.

<HARD-GATE>
Do NOT rationalize around a FAIL verdict. The verifier's verdict is final — scope-scoping arguments ("pre-existing failures," "out-of-scope tests," "RED marker tolerance," "already tracked as a separate bug") do not override the FAIL → Phase 3 path. The orchestrator's judgment about whether the FAIL "really applies" is exactly the bias the verifier was designed to counteract. Only `overall_verdict: PASS` or technical failure (timeout/unparseable JSON) permits proceeding to Step 1.
</HARD-GATE>

### Step 1: Run /dso:validate-work (/dso:sprint)

Before invoking `/dso:validate-work`, gather the changed files:

```bash
CHANGED_FILES=$(git diff --name-only main...HEAD 2>/dev/null || git diff --name-only HEAD~1..HEAD 2>/dev/null || echo "")
echo "$CHANGED_FILES"
```

Invoke `/dso:validate-work`. Append this context block (substitute actual file list):

```
### Sprint Change Scope
CHANGED_FILES:
app/src/agents/enrichment.py
app/src/api/status/status_routes.py
scripts/validate.sh
```

**Interpret the report:**
- **All 5 domains PASS** → proceed to Step 2
- **Any domain FAIL** → create remediation tasks and return to Phase 3 (Batch Preparation)
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
- **Score = 5** → Phase 8 (completion)
- **Score < 5** → Phase 7 (remediation)

---

## Phase 7: Remediation Loop (/dso:sprint)

**Trigger**: Epic validation score < 5 (from Phase 6 Step 5).

Read and execute `prompts/remediation-loop.md` for the full remediation protocol (gap classification, oscillation check, user confirmation, task creation, and safety bounds).

---

## Phase 8: Primary Ticket Closure (/dso:sprint)

Phase 8 delegates to `/dso:end-session`, which handles closing issues, committing, running `merge-to-main.sh`, and reporting.

### On Success (Score = 5)

**Pre-condition**: Phase 6 Step 0.75 must have returned `overall_verdict: PASS` during this session. If the completion-verifier returned FAIL at any point and no remediation batch was executed after the FAIL (i.e., the FAIL was not addressed via Phase 3 re-entry), do NOT proceed with epic closure — return to Phase 3 to address the FAIL findings first.

**FAIL is unconditionally blocking.** If the completion-verifier returned `overall_verdict: FAIL` at any point (Step 10a story-level or Phase 6 Step 0.75 epic-level) and no subsequent remediation batch resolved the FAIL findings, do NOT proceed to epic closure. Do NOT:
- Present the FAIL verdict to the user with rationalizations
- Ask the user whether failing criteria can be waived
- Suggest that "most" criteria passing is sufficient
- Offer to close the epic with caveats

The only valid actions on FAIL are: (a) return to Phase 3 to address the findings, or (b) explicitly confirm with the user that they want to STOP the sprint entirely (not close the epic as "done").

<HARD-GATE>
Before closing the epic, confirm that dso:completion-verifier was dispatched at Phase 6 Step 0.75 with the EPIC ID (not a story ID) and returned overall_verdict: PASS during THIS session. Story-level verifier results from Step 10a do NOT satisfy this requirement — each story verifier runs against one story's done definition; only the epic-level verifier (Step 0.75) runs against all epic-level success criteria simultaneously. If Step 0.75 has not yet been dispatched for the epic, stop and return to Phase 6 Step 0.75 NOW. Do NOT proceed to epic closure until the epic-level verifier verdict is received.
</HARD-GATE>

1. **Verify all changes are merged before closing the epic** (399f-abad):
   ```bash
   git merge-base --is-ancestor HEAD main
   ```
   If this exits non-zero, do NOT close the epic — changes have not been merged to main. Run `merge-to-main.sh` first and resolve any conflicts before proceeding. Only close the epic after `merge-base --is-ancestor` exits 0.
2. Close the epic:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Epic complete: all tasks closed, validation score 5/5, branch merged to main"
   .claude/scripts/dso ticket transition <epic-id> in_progress closed
   ```
3. Set sprint context for `/dso:end-session` report:
   - Epic ID and title
   - Total tasks completed this session
   - Validation score: 5/5
4. Invoke `/dso:end-session --bump minor` via the Skill tool:
   ```
   Skill({skill: "dso:end-session", args: "--bump minor"})
   ```
   If `version.file_path` is not configured in `dso-config.conf`, the `--bump minor` flag is a no-op.
   <HARD-GATE>
   This MUST be done using the Skill tool — not interpreted as a bash command, not
   printed as text, and not deferred for the user to run. The slash-command notation
   above is a Skill tool invocation shorthand. Use the Skill tool directly.
   Do NOT ask the user whether to run /dso:end-session. Invoke it directly.
   Asking "Would you like me to..." is a known anti-pattern (c26f-be3f) that adds
   friction. This is an unconditional directive — execute immediately after the
   epic closes.
   </HARD-GATE>

### On Graceful Shutdown (Compaction, Failures)

1. Do NOT launch new sub-agents
2. Wait for any running sub-agents to complete
3. Run final validation:
   ```bash
   .claude/scripts/dso validate.sh --ci
   ```
4. Update ALL in-progress tasks with checkpoint-format progress notes:
   ```bash
   .claude/scripts/dso ticket comment <id> "CHECKPOINT:<phase-name>:SESSION_END — Progress: <summary>. Next: <what remains>."
   ```
   Use the highest semantic checkpoint name actually reached (e.g., `CHECKPOINT:implementation-done:SESSION_END`, `CHECKPOINT:review-passed:SESSION_END`, `CHECKPOINT:validation-passed:SESSION_END`).
5. Set sprint context for `/dso:end-session` report:
   - Tasks completed this session
   - Tasks remaining (with IDs and titles)
   - Resume command: `/dso:sprint <epic-id>`
6. Invoke `/dso:end-session` via the Skill tool. Pass `--bump minor` if the epic reached Phase 6 completion-verifier PASS this session; omit `--bump` for incomplete sprints (no version bump earned):
   ```
   Skill({skill: "dso:end-session", args: "--bump minor"})   # on success
   Skill({skill: "dso:end-session"})                         # on graceful shutdown
   ```
   <HARD-GATE>
   This MUST be done using the Skill tool — not interpreted as a bash command.
   Do NOT ask the user whether to run /dso:end-session. Invoke it directly.
   </HARD-GATE>

---

