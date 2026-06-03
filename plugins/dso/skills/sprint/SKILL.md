---
name: sprint
description: Use when the user wants to execute an epic, run a sprint, work through a planned epic's stories and tasks, or coordinate multi-agent task execution end-to-end. Routes the epic by complexity (SIMPLE → direct implementation-plan, MODERATE → lightweight preplanning, COMPLEX → full preplanning), runs an SC-coverage gate at haiku/sonnet/opus tiers to confirm story coverage of epic success criteria, plans the task graph, dispatches sub-agents in batches with file-overlap and semantic-conflict checks, runs per-task review and post-batch validation (test gate, lint, AC verification, visual verification for UI), commits/pushes results, and verifies epic completion via the dso:completion-verifier agent before close. Trigger phrases include 'work the epic', 'execute the sprint', 'run the epic', 'sprint this epic', 'work through the stories', 'implement the planned tasks', 'kick off the sprint'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:sprint requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Purpose

You are Senior Orchestrator Agent that follows a clearly defined sprint process and uses sub-agents to execute actions. You are protective of your context window, using sub-agents to investigate, edit, or resolve.

# Execute Epic: Multi-Agent Orchestration

## Config Resolution (reads project .claude/dso-config.conf)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)  # shim-exempt: internal orchestration script
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)  # shim-exempt: internal orchestration script
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)  # shim-exempt: internal orchestration script
VISUAL_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_visual)  # shim-exempt: internal orchestration script
E2E_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test_e2e)  # shim-exempt: internal orchestration script
SPRINT_MODE=$(bash "$PLUGIN_SCRIPTS/mode-detect.sh")  # shim-exempt: SPRINT_MODE must be set before any ci-pr-only Phase A block reads it (bug f6fd-af80-9b13-4649)
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — replaces `make test-unit-only` in post-batch and remediation validation; interpolated as `{TEST_CMD}` in task-execution.md
- `LINT_CMD` — replaces `make lint` in validation steps; interpolated as `{LINT_CMD}` in task-execution.md
- `FORMAT_CHECK_CMD` — replaces `make format-check` in validation steps; interpolated as `{FORMAT_CHECK_CMD}` in task-execution.md
- `VISUAL_CMD` — replaces `make test-visual` in post-batch checks
- `E2E_CMD` — replaces `make test-e2e` in post-batch checks
- `SPRINT_MODE` — `ci-pr` or `local`; governs per-story PR mechanisms. Resolved here at activation so every Phase A ci-pr-only block (Ruleset Preflight, Draft PR Creation) can read it safely. The Mode Banner subsection later in Phase A only emits the banner.

<!-- Schema reference: docs/designs/stage-boundary-preconditions/ -->

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated, never blocks the skill):

```bash
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
bash "$PLUGIN_SCRIPTS/ticket-migrate-schema-hardening.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
bash "$PLUGIN_SCRIPTS/migrate-design-notes-to-design-md.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

## Stage-Boundary Entry Check

<!-- EMIT-PRECONDITIONS: gate_name=sprint_preconditions_entry degradation_type=inferred_decision -->
Source the preconditions validator library and run the entry check for the sprint stage (fail-open: `|| true` prevents blocking when no upstream implementation-plan event exists yet):

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/preconditions-validator-lib.sh" 2>/dev/null || true
_dso_pv_entry_check "sprint" "implementation-plan" "${primary_ticket_id:-}" || true
```

## Orchestration Flow

```
Flow: P1 (Init) → Preplanning Gate
  → [0 children/ambiguous] /dso:preplanning → P2
  → [children exist & clear] P2 (Task Analysis)
  P2 → [stories without impl tasks?] layer-stratify → sequential Skill-tool dispatch (per-layer) → STATUS:complete→tasks created | STATUS:blocked→ask user → Re-gather → P3
  P2 → [all have impl tasks] P3 (Batch Preparation)
  P3 → [execute] P4 (Sub-Agent Launch) → P5 (Post-Batch)
  P5 → [context >=70%] /compact → P3 (proactive, safe — all work committed)
  P5 → [involuntary compaction detected] P8 (Graceful Shutdown)
  P5 → [more ready tasks] P3
  P5 → [all done] P6 (Validation)
  P6 → [score=5] P8 (Completion)
  P6 → [score<5] P7 (Remediation) → P3
```

> **Filing bugs discovered during the sprint**: tooling, infrastructure, or otherwise-unrelated bugs found while orchestrating an epic are **top-level tickets**, not children of the epic under sprint. Pass `--parent <epic-id>` only when the bug's resolution is required for one of the epic's Success Criteria. See `${CLAUDE_PLUGIN_ROOT}/skills/create-bug/SKILL.md` § "Parent Linkage Policy" (bug 7f23-1a14).

---

## Phase A: Initialization & Primary Ticket Selection (/dso:sprint)

### Parse Arguments

- `<primary-ticket-id>`: The primary ticket to execute

### If No Primary Ticket ID Provided

1. Run the epic discovery script:
   ```bash
   .claude/scripts/dso ticket list-epics --all --has-tag=brainstorm:complete
   ```
   This outputs tab-separated lines in three categories:
   - `<id>\tP*\t<title>\t<child_count>[\tBLOCKING]` for in-progress epics (4 or 5 fields; `P*` replaces priority)
   - `<id>\tP<priority>\t<title>\t<child_count>[\tBLOCKING]` for unblocked open epics (4 or 5 fields)
   - `BLOCKED\t<id>\tP<priority>\t<title>\t<child_count>\t<blocker_ids>` for blocked ones (6 fields; with `--all`)

   The `<child_count>` field is the number of child tickets. The `<blocker_ids>` field is a comma-separated list of open blocker epic IDs.

   Exit codes:
   - Exit code 1 → no open epics exist, report and exit

   **If no eligible epics remain** after applying `--has-tag=brainstorm:complete` (i.e., the filtered output is empty or exit code 1):
   - Report: "No epics with the brainstorm:complete tag are ready to execute."
   - Run the same command **without** `--has-tag=brainstorm:complete` to count how many epics were hidden:
   ```bash
   .claude/scripts/dso ticket list-epics --all
   ```
   - If there are epics without brainstorm:complete that were filtered out, show: "There are N epics without the brainstorm:complete tag. Run `/dso:brainstorm` on one to complete scrutiny review before executing."
   - Exit.

2. Parse the output and print a numbered list. **CRITICAL: You MUST output the formatted list as visible text.**  Number in-progress (`P*`) epics first, then unblocked. Blocked epics are informational only (not selectable). Render `BLOCKING` epics in **bold**. 

3. Display the text: "Enter the number or epic ID to execute:" and wait for the user's text input. 
4. Map the user's response (number or epic ID) back to the corresponding epic and proceed

### Validate Primary Ticket

Set `primary_ticket_id = <the resolved ticket ID>`.

1. Run `.claude/scripts/dso ticket show <primary_ticket_id>` — confirm status is `open` or `in_progress`

2. If the ticket status is `in_progress`:

Load skills/sprint/prompts/auto-resume.md and follow the instructions it contains.

3. Mark ticket in-progress: `.claude/scripts/dso ticket transition <primary_ticket_id> in_progress`

<!-- EMIT-PRECONDITIONS: gate_name=sprint_worktree_tracking degradation_type=inferred_decision -->
Post WORKTREE_TRACKING:start on the epic ticket (fail silently if .tickets-tracker/ unavailable): # tickets-boundary-ok
```bash
_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
.claude/scripts/dso ticket comment <primary_ticket_id> "WORKTREE_TRACKING:start branch=${_BRANCH} session_branch=${_BRANCH} timestamp=${_TS}" 2>/dev/null || true
```

**Set vars.SPRINT_SESSION_ID**: Set the `SPRINT_SESSION_ID` repo variable so `resolve-session-branch.sh` can discover the session branch as a fallback (step 2 of its 3-step fallback chain). PATCH first (update existing); POST as fallback (initial creation). `|| true` ensures failure (no gh auth, no `actions:write` permission, fork repo) does not block sprint execution.
```bash
# Set vars.SPRINT_SESSION_ID for resolve-session-branch.sh session discovery fallback.
_SESSION_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
_GH_REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [[ -n "$_GH_REPO" ]]; then
    gh api --method PATCH "repos/$_GH_REPO/actions/variables/SPRINT_SESSION_ID" \
        -f value="$_SESSION_BRANCH" 2>/dev/null || \
    gh api --method POST "repos/$_GH_REPO/actions/variables" \
        -f name="SPRINT_SESSION_ID" -f value="$_SESSION_BRANCH" 2>/dev/null || true
fi
```

The `.sprint-active` marker is gitignored and scoped to the session worktree. It enables the session-merge-only-check pre-commit hook. Phase I removes it.
```bash
# Create sprint-active marker to enable session-worktree merge-only enforcement
touch "$(git rev-parse --show-toplevel)/.sprint-active"
```

### Ruleset Preflight (ci-pr mode only)

When `SPRINT_MODE=ci-pr`, run the Ruleset preflight check before continuing:
```bash
if [[ "${SPRINT_MODE:-}" == "ci-pr" ]]; then
    if .claude/scripts/dso sprint/check-ruleset-preflight.sh 2>/dev/null; then
        echo "Ruleset preflight: OK"
    else
        echo "WARNING: Ruleset preflight failed — session-* branch protection may not be configured. See INSTALL.md#github-rulesets-for-session-branches" >&2
        echo "Continuing sprint — preflight is advisory, not blocking."
    fi
fi
```

This check is NON-BLOCKING (advisory only). If Rulesets aren't configured, warn but continue. Integration boundary: this preflight is the dso-94ya integration point between sprint orchestration and the GitHub Ruleset enforcement layer.

**Draft PR Creation (ci-pr mode only)**: When `SPRINT_MODE=ci-pr`, open a long-lived draft PR before Phase E dispatch using `create-sprint-draft-pr.sh`:
# See also: create-sprint-draft-pr.sh for Phase A draft PR creation (ci-pr mode only)
```bash
# Create long-lived draft PR (ci-pr mode only) — substrate for GitHubPRDefenseStore
if [[ "${SPRINT_MODE:-}" == "ci-pr" ]]; then
    # Capture stdout only; the script emits the PR URL on stdout and errors on stderr.
    # Capturing 2>&1 lands stderr in DRAFT_PR_URL on failure, making the prior `-z`
    # test pass when it should halt (bug d92e-5168). Check exit code AND require an
    # https:// URL — defense in depth against either the script silently emitting
    # empty stdout, or future error paths writing diagnostics to stdout.
    DRAFT_PR_URL=$(SESSION_BRANCH="${_BRANCH}" PRIMARY_TICKET_ID="${primary_ticket_id}" EPIC_TITLE="${_EPIC_TITLE:-}" \
        "$(git rev-parse --show-toplevel)/.claude/scripts/dso" create-sprint-draft-pr.sh)
    _draft_rc=$?
    if [[ $_draft_rc -ne 0 || "$DRAFT_PR_URL" != https://* ]]; then
        echo "ERROR: Phase A draft PR creation failed (rc=$_draft_rc) — halting before Phase E dispatch" >&2
        exit 1
    fi
    echo "Draft PR: $DRAFT_PR_URL"
fi
```
Phase E dispatch must not begin until this block completes.

**Cascade-counter entry init (before the epic/non-epic branch):** initialize the replan cascade counter once here so every routing path — epic (Drift Detection / Phase B) **and** non-epic `story`/`task` (which routes `REPLAN_ESCALATE:` into d-replan-collect but skips both the Drift and Phase B inits) — has an initialized counter for the `replan_cycle_count >= max_replan_cycles` cap comparison:

```
replan_cycle_count = replan_cycle_count ?? 0
max_replan_cycles = read_config("sprint.max_replan_cycles", default=2)
```

Downstream inits (Drift Detection, Phase B Step 2) are idempotent (`?? 0`) and must not reset this value.

**Non-epic routing**: After validation, check the ticket type and route accordingly:

| Ticket type | Route |
|-------------|-------|
| `epic` | Continue to Drift Detection → Preplanning Gate (standard flow) |
| `bug` | Dispatch `/dso:fix-bug` as sub-skill — see Bug Routing below |
| `story` or `task` | Run complexity evaluation then optional `/dso:implementation-plan` — see Non-Epic Routing below |

#### Bug Routing (SC4)

When ticket type is `bug`:

1. Log: `"Primary ticket <primary_ticket_id> is a bug — dispatching /dso:fix-bug."`
2. Invoke `/dso:fix-bug <primary_ticket_id>` via Skill tool.
3. Exit Phase A and proceed to Phase I (Session Close). Do not continue to the Preplanning Gate or Phase B.

#### Non-Epic Routing

When ticket type is `story` or `task`:

1. Log: `"Primary ticket <primary_ticket_id> is a <type> — running complexity evaluation."`
2. Dispatch the `dso:complexity-evaluator` agent (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` value). Read `agents/complexity-evaluator.md` inline and use `subagent_type: "general-purpose"` with `model: "haiku"`. Pass `tier_schema=TRIVIAL` to classify the ticket.

   **Fallback**: If the `agents/complexity-evaluator.md` file is missing, log a warning and fall back to inline complexity assessment using the story description and acceptance criteria.

3. Route based on the complexity classification:
   - **TRIVIAL (high)**: Skip `/dso:implementation-plan`. Before proceeding, run a **file-count guard**: estimate the number of files the task will touch by running `enrich-file-impact.sh` or by counting file paths mentioned in the ticket description. If the estimated file count exceeds 30, split the task into parallel sub-tasks by directory or alphabetical range (each sub-task ≤ 30 files), create child task tickets for each subset, and proceed to Phase C with the split tasks. If ≤ 30 files, proceed directly to Phase C (Batch Preparation) with the ticket as the sole task.
   - **TRIVIAL (medium)** or **MODERATE/COMPLEX (any)**: Invoke `/dso:implementation-plan <primary_ticket_id>` via Skill tool. When the Skill tool returns, parse the STATUS line and proceed immediately to step 4 — do not pause or wait for user input.
4. After the Skill tool returns, route on STATUS and continue to Phase C:
   - `STATUS:complete` → proceed to Phase C
   - `STATUS:blocked` → surface blocked questions to user, then proceed to Phase C once answered
   - `STATUS:bypass REASON:copy_story` → the story is a copy story; skip implementation-plan decomposition and proceed directly to Phase C — Phase E "Copy Story Dispatch" routes it to `dso:gov-copy-writer`
   - `REPLAN_ESCALATE:` → route to d-replan-collect machinery

   Non-epics **skip** the Preplanning Gate and proceed directly to Phase C.

### Drift Detection Check

After validating the epic, check for codebase drift before proceeding to the Preplanning Gate.

**Initialize the cascade counter** (if not already set from a prior phase — drift-triggered REPLAN_ESCALATE feeds into the same machinery as Phase B):

```
replan_cycle_count = replan_cycle_count ?? 0
max_replan_cycles = read_config("sprint.max_replan_cycles", default=2)
```

**Run the drift check:**

```bash
DRIFT_RESULT=$(.claude/scripts/dso sprint/sprint-drift-check.sh <epic-id>)
```

**If `DRIFT_DETECTED`:**

1. Parse the drifted file list from `DRIFT_RESULT` (everything after `DRIFT_DETECTED: `).
2. Log: `"Codebase drift detected — files modified since task creation: <files>"`
3. Record a REPLAN_TRIGGER comment on the epic (see `docs/contracts/replan-observability.md` for signal format): # shim-exempt: internal documentation reference
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: drift — Files drifted: <files>. Re-invoking implementation-plan for affected stories."
   ```
4. Identify which stories' tasks reference any of the drifted files (inspect each child task's `## File Impact` or `## Files to Modify` section).
5. For each affected story, re-invoke `/dso:implementation-plan <story-id>` via the Skill tool. When the Skill tool returns, parse the STATUS line immediately and continue to the next story — do not pause.
   - **On success (`STATUS:complete`)**: continue to the next story.
   - **On `STATUS:blocked`**: surface the story as blocked for user input (same handling as Phase B blocked-stories list).
   - **On `STATUS:bypass REASON:copy_story`**: the story is a copy story; do NOT add tasks. The Phase E "Copy Story Dispatch" section handles dispatch via `dso:gov-copy-writer`. Continue to the next story.
   - **On `REPLAN_ESCALATE: brainstorm EXPLANATION:<text>`**: add the story and its explanation to the **replan-stories list** and route through the existing d-replan-collect cascade machinery (Phase B step d-replan-collect). The `replan_cycle_count` / `max_replan_cycles` initialized above are shared with Phase B — do not reinitialize them.
6. After all re-invocations complete (and no REPLAN_ESCALATE is outstanding), record:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: implementation-plan — Drift re-planning complete for <N> stories."
   ```
7. Proceed to Preplanning Gate.

**Note:** `DRIFT_DETECTED` and `RELATES_TO_DRIFT` are independent signals — both may appear in the same `DRIFT_RESULT` output. Process each block that matches, in order. They are NOT mutually exclusive branches.

**If `RELATES_TO_DRIFT` lines are present in `DRIFT_RESULT`:**

1. Parse each `RELATES_TO_DRIFT: <epic-id> <summary>` line from `DRIFT_RESULT`.
2. Log: `"Relates_to drift detected — related epic <epic-id> closed after implementation plan: <summary>"` for each line.
3. Record a REPLAN_TRIGGER comment on the epic (see `docs/contracts/replan-observability.md` for signal format): # shim-exempt: internal documentation reference
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: drift — Relates_to epic <closed-epic-id> closed after implementation plan. <summary>. Re-invoking implementation-plan for affected stories."
   ```
4. Identify which stories' tasks reference any of the drifted relates_to epics (inspect each child task's `## File Impact` or `## Files to Modify` section, or cross-reference the task's dependency/relates-to links).
5. For each affected story, re-invoke `/dso:implementation-plan <story-id>` via the Skill tool. When the Skill tool returns, parse the STATUS line immediately and continue to the next story — do not pause.
   - **On success (`STATUS:complete`)**: continue to the next story.
   - **On `STATUS:blocked`**: surface the story as blocked for user input (same handling as Phase B blocked-stories list).
   - **On `STATUS:bypass REASON:copy_story`**: the story is a copy story; do NOT add tasks. The Phase E "Copy Story Dispatch" section handles dispatch via `dso:gov-copy-writer`. Continue to the next story.
   - **On `REPLAN_ESCALATE: brainstorm EXPLANATION:<text>`**: add the story and its explanation to the **replan-stories list** and route through the existing d-replan-collect cascade machinery (Phase B step d-replan-collect). The `replan_cycle_count` / `max_replan_cycles` initialized above are shared with Phase B — do not reinitialize them.
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
<!-- EMIT-PRECONDITIONS: gate_name=sprint_ticket_clarity_check degradation_type=inferred_decision -->
- **Exit 2 (ERROR/ABSENT)**: script is missing or encountered an error; emit a warning (`"ticket-clarity-check.sh unavailable — falling through to Layer 2"`); proceed to Layer 2 (fail-open).

#### Layer 2: Scope Certainty Assessment

Dispatch the `dso:complexity-evaluator` agent (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types). Read `agents/complexity-evaluator.md` inline and use `subagent_type: "general-purpose"` with `model: "haiku"`. Pass the primary ticket context to evaluate `scope_certainty`:

```
subagent_type: "general-purpose"
model: haiku
prompt: |
  {verbatim content of agents/complexity-evaluator.md}

  ticket_id: <primary_ticket_id>
  tier_schema: SIMPLE
```

Parse `scope_certainty` from the evaluator's JSON output:

- **`High` or `Medium`**: proceed to Preplanning Gate.
- **`Low`**: proceed to User Escalation (Layer 3).
- **Unrecognized value**: treat as `Low` — proceed to User Escalation (Layer 3).
<!-- EMIT-PRECONDITIONS: gate_name=sprint_complexity_evaluator degradation_type=inferred_decision -->
- **Agent unavailability** (timeout, dispatch failure, API key absent): log `"WARNING: complexity-evaluator unavailable — falling through to Layer 3."` and proceed to User Escalation (Layer 3).

#### Layer 3: User Escalation (AskUserQuestion)

When either Layer 1 or Layer 2 signals low clarity, present options via AskUserQuestion:

> "The primary ticket `<primary_ticket_id>` has low clarity. How would you like to proceed?
>
> (a) Run `/dso:fix-bug` if this is actually a defect
> (b) Run `/dso:brainstorm` to enrich the ticket before executing
> (c) Proceed anyway with the current ticket as-is"

Wait for user response and route accordingly:
- **(a) fix-bug**: dispatch `/dso:fix-bug <primary_ticket_id>`, then exit to Phase I.
- **(b) brainstorm**: invoke `/dso:brainstorm <primary_ticket_id>` via Skill tool, then re-enter Preplanning Gate.
- **(c) proceed**: log `"User elected to proceed with low-clarity ticket."`, continue to Preplanning Gate.

### Mode Banner

`SPRINT_MODE` is resolved during the Config Resolution block at the top of Phase A. This subsection only emits the banner.

Emit exactly one banner based on the result:

| SPRINT_MODE | Banner |
|-------------|--------|
| `ci-pr` | `MODE: ci-pr` |
| `local` | `MODE: local — per-story PR mechanisms inactive` |

When `SPRINT_MODE=local`: all ci-pr-only mechanisms (per-story PR creation, trailer enforcement, story-level review gates, merge orchestration, cross-story diff analysis) are **inactive for this sprint run**. Do not attempt to create PRs or enforce story-level trailers.

When `SPRINT_MODE=ci-pr`: per-story PR mechanisms are active. Proceed with normal sprint flow.

### Context Efficiency Rules

**Status checks**: Use `.claude/scripts/dso issue-summary.sh <id>` or `.claude/scripts/dso ticket list --parent=<epic-id>` (scope to the epic under sprint) for orchestrator status checks (is it done? what's blocking?). Reserve full `.claude/scripts/dso ticket show <id>` only when sub-agents need to read their complete task context.

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
OPEN=$(.claude/scripts/dso ticket list --parent=<epic-id> --status=open,in_progress 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' || echo 0)
ALL=$(.claude/scripts/dso ticket list --parent=<epic-id> --include-archived --exclude-deleted 2>/dev/null | grep -c '"ticket_id"' || echo 0)
```

- **`OPEN > 0`**: → Step 2 (Existing Children Readiness Check)
- **`OPEN == 0` and `ALL > 0`**: All children closed. Log `"Preplanning Gate: all children closed — routing to Phase G."` Skip to Phase G. Do NOT route to Step 7.
- **`ALL == 0`**: → Step 7 (Epic Complexity Evaluation)

#### Step 2: Existing Children Readiness Check (/dso:sprint)

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
3. After preplanning completes, continue to Phase B

If no trigger condition is met, proceed to Step 3 (SC Coverage Haiku Gate).

#### Step 3: SC Coverage Haiku Gate (/dso:sprint)

**Purpose**: Fast-path check that all epic success criteria (SCs) are traceable to at least one child story or task. Uses a haiku sub-agent for speed. This is a read-only advisory gate — it never blocks execution. Sonnet/opus escalation for ESCALATE verdicts is handled by Step 4.

**ORCHESTRATOR_RESUME idempotency**: If your resume context contains `SC_COVERAGE_HAIKU_GATE: complete` for this epic, skip this entire sub-step and proceed to Step 4 if any ESCALATE verdicts were recorded, otherwise proceed to Phase B.

**Step 1 — Collect inputs**:

1. Retrieve the epic's success criteria list from the epic ticket description.
2. Retrieve child descriptions (already fetched by Step 1 and Step 2 above).
<!-- EMIT-PRECONDITIONS: gate_name=sprint_sc_haiku_gate degradation_type=unresolved_question -->
3. If the epic has **0 SCs** (empty success criteria list): log `"0-SC epic: skipping SC coverage haiku gate — no SCs to validate"` and proceed directly to Phase B. Do not dispatch the haiku sub-agent.

**Step 2 — Dispatch haiku sub-agent**:

Dispatch a `subagent_type: general-purpose` sub-agent with `model: haiku`. Load the prompt from `skills/sprint/prompts/sc-coverage-haiku.md`. Provide:
- `epic_sc_list`: an array of `{ "sc_id": "<id>", "sc_text": "<text>" }` objects. Assign sequential IDs (e.g. `sc-1`, `sc-2`) from the epic's SC list in order.
- `children`: an array of `{ "child_id": "<id>", "child_title": "<title>", "child_description": "<description>" }` for each child ticket

**Step 3 — Parse output**:

The haiku sub-agent returns a JSON object with this structure:
```json
{
  "results": [
    {
      "sc_id": "<matches input sc_id>",
      "verdict": "COVERED" | "ESCALATE",
      "covering_child_id": "<child_id or null>",
      "citation_reason": "<explanation or null>"
    }
  ]
}
```
Parse the `results` array. Check `verdict` on each entry. On any missing key, null `results`, or invalid JSON: trigger the fail-open path below.

<!-- EMIT-PRECONDITIONS: gate_name=sprint_sc_haiku_parse degradation_type=inferred_decision -->
**On parse failure** (malformed JSON, missing fields, timeout, or empty output): this gate is fail-open — log a warning `"SC coverage haiku gate: parse failure — skipping gate, proceeding to Phase B"` and proceed directly to Phase B. Do not block execution.

**Step 4 — Emit idempotency marker and route on verdicts**:

Emit `SC_COVERAGE_HAIKU_GATE: complete` to your output so that ORCHESTRATOR_RESUME can detect it on resume.

- **ALL verdicts are `COVERED`**: log `"SC coverage haiku gate: all SCs covered — proceeding to Phase B"` and proceed to Phase B normally. Skip Step 4.
- **ANY verdict is `ESCALATE`**: collect the ESCALATE SCs into an escalation list and proceed to Step 4 (SC Coverage Sonnet Tier).

#### Step 4: SC Coverage Sonnet Tier (/dso:sprint)

**Trigger**: Only runs if the haiku gate (Step 3) returned ANY `ESCALATE` verdict. If haiku marked ALL SCs as `COVERED` (empty escalation list), skip this sub-step entirely and proceed to Phase B.

**Purpose**: Deeper evaluation of SCs that haiku could not conclusively mark as COVERED. Sonnet evaluates each escalated SC independently, with no knowledge of haiku's verdicts.

**ORCHESTRATOR_RESUME idempotency**: If your resume context contains `SC_COVERAGE_SONNET_GATE: complete` for this epic, skip this entire sub-step and:
- If any UNSURE verdicts were recorded → proceed to Step 5 (opus dispatch)
- If any MISSING verdicts were recorded (no UNSURE) → proceed to REPLAN_TRIGGER Routing (no opus dispatch)
- If all verdicts are COVERED → proceed to Phase B directly

**Step 1 — Prepare input**:

From the haiku escalation list, collect only the SCs marked `ESCALATE`. Build the input payload:
```json
{
  "sc_list": [
    { "sc_id": "sc-1", "sc_text": "<original SC text — no haiku verdicts, no escalation reasoning>" }
  ],
  "children": [
    { "child_id": "<id>", "child_title": "<title>", "child_description": "<description>" }
  ]
}
```

**Important input contract**: Pass ONLY the original SC text and children descriptions to sonnet. Do NOT include haiku verdicts, escalation reasoning, or haiku output in the prompt. Sonnet must evaluate independently.

**Step 2 — Dispatch sonnet sub-agent**:

Dispatch a `subagent_type: general-purpose` sub-agent with `model: sonnet`. Load the prompt from `skills/sprint/prompts/sc-coverage-sonnet.md`. Pass the input payload constructed above.

**Step 3 — Parse output**:

The sonnet sub-agent returns a JSON object:
```json
{
  "results": [
    {
      "sc_id": "sc-1",
      "verdict": "COVERED" | "MISSING" | "UNSURE",
      "reasoning": "<explanation>"
    }
  ]
}
```
Parse the `results` array. Check `verdict` on each entry.

<!-- EMIT-PRECONDITIONS: gate_name=sprint_sc_sonnet_parse degradation_type=inferred_decision -->
**On parse failure** (malformed JSON, missing fields, timeout, or empty output): this gate is fail-open — log a warning `"SC coverage sonnet gate: parse failure — treating all sonnet SCs as UNSURE, escalating to opus (Step 5)"` and treat ALL sonnet-evaluated SCs as `UNSURE`. Proceed to Step 5.

**Step 4 — Collect verdicts**:

For each SC in the sonnet results:
- **`COVERED`**: SC is sufficiently covered — remove from escalation tracking.
- **`MISSING`**: SC has a real gap — add to the `sc_coverage_missing` list.
- **`UNSURE`**: Sonnet could not determine coverage — collect into the `sc_coverage_unsure` list for opus escalation.

**Step 5 — Emit idempotency marker and route on UNSURE list**:

Emit `SC_COVERAGE_SONNET_GATE: complete` to your output so that ORCHESTRATOR_RESUME can detect it on resume.

- **If the UNSURE list is empty**: proceed directly to REPLAN_TRIGGER Routing below (no opus dispatch needed). Log: `"SC coverage sonnet gate: no UNSURE SCs — opus escalation skipped"`.
- **If any SCs are UNSURE**: proceed to Step 5 (SC Coverage Opus Tier) with the UNSURE SCs passed as input to opus.

#### Step 5: SC Coverage Opus Tier (/dso:sprint)

**Trigger**: Only dispatch opus if the UNSURE list from Step 4 is non-empty. If the UNSURE list is empty (all SCs resolved by haiku + sonnet), skip opus entirely — log `"SC coverage opus tier: UNSURE list empty — skipping opus, proceeding to REPLAN_TRIGGER routing"` and proceed directly to REPLAN_TRIGGER routing below.

**Purpose**: Opus is the final arbiter for SCs that sonnet could not conclusively classify as COVERED or MISSING. Opus returns only COVERED or MISSING — no UNSURE. This terminates the escalation cascade.

**ORCHESTRATOR_RESUME idempotency**: If your resume context contains `SC_COVERAGE_OPUS_GATE: complete` for this epic, skip this sub-step and proceed directly to REPLAN_TRIGGER routing.

**Step 1 — Prepare input**:

Build the opus input payload using only the SCs in `sc_coverage_unsure` (no MISSING SCs, no haiku/sonnet context):
```json
{
  "unsure_scs": [
    { "sc_id": "sc-1", "sc_text": "<original SC text only — no prior tier verdicts>" }
  ],
  "children": [
    { "child_id": "<id>", "child_title": "<title>", "child_description": "<description>" }
  ]
}
```

**Step 2 — Dispatch opus sub-agent**:

Dispatch a `subagent_type: general-purpose` sub-agent with `model: opus`. Load the prompt from `skills/sprint/prompts/sc-coverage-opus.md`. Pass the input payload constructed above.

**Step 3 — Parse output**:

The opus sub-agent returns a JSON object:
```json
{
  "results": [
    {
      "sc_id": "sc-1",
      "verdict": "COVERED" | "MISSING"
    }
  ]
}
```
Parse the `results` array. Check `verdict` on each entry. Opus returns COVERED or MISSING only — no UNSURE.

<!-- EMIT-PRECONDITIONS: gate_name=sprint_sc_opus_parse degradation_type=inferred_decision -->
**On parse failure** (malformed JSON, missing fields, timeout, or empty output): fail-open conservative — log a warning `"SC coverage opus gate: parse failure — treating all unparseable SCs as MISSING (conservative fail-open)"` and treat ALL opus-evaluated SCs as `MISSING`. Add them to the `sc_coverage_missing` list.

<!-- DESIGN-NOTE: intentional asymmetry — sonnet parse failure escalates to opus (fail-open toward "more review"),
     while opus parse failure treats as MISSING (fail-open toward "acknowledge gap"). The two are deliberately
     asymmetric: sonnet has a tier above it that can resolve ambiguity; opus is the final arbiter and must
     default conservatively. Do NOT change opus fail-open to match the COVERED tie-breaking default in
     sc-coverage-opus.md — that tie-breaking rule applies only to UNSURE verdicts, not to parse failures. -->

**Step 4 — Collect opus verdicts**:

For each SC in the opus results:
- **`COVERED`**: SC is confirmed covered — remove from outstanding list.
- **`MISSING`**: SC has a confirmed gap — add to the `sc_coverage_missing` list.

**Step 5 — Emit idempotency marker**:

Emit `SC_COVERAGE_OPUS_GATE: complete` to your output so that ORCHESTRATOR_RESUME can detect it on resume.

#### Step 6: REPLAN_TRIGGER Routing — SC Coverage Gaps (/dso:sprint)

After completing all applicable escalation tiers, evaluate the `sc_coverage_missing` list:

**If ALL SCs are COVERED** (empty `sc_coverage_missing` list):
- Log: `"SC coverage check complete: all SCs covered — proceeding to Phase B normally."`
- Continue to Phase B.

**If ANY SCs are MISSING** (non-empty `sc_coverage_missing` list):

**Prerequisite — Retrieve child ticket types**: Ensure `ticket_type` is known for each child before routing. The children list was fetched earlier in the Preplanning Gate via `ticket deps`. If `ticket_type` was not preserved from that fetch, run:
```bash
.claude/scripts/dso ticket show <child_id>
```
for each child to retrieve the `ticket_type` field. This is required to determine the routing path: story children → `/dso:preplanning`; task-only children → `/dso:implementation-plan`.

1. Record a `REPLAN_TRIGGER: sc_coverage` comment on the epic listing the missing SCs:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: sc_coverage — Missing SCs: <comma-separated list of missing sc_ids and sc_text>. Routing to decomposition skill to add coverage."
   ```

2. Based on the child ticket types (from the children already fetched above), invoke:

   **If at least one child has `ticket_type: story`** (route to `/dso:preplanning`):

   Invoke `/dso:preplanning <epic-id>` via Skill tool. When the Skill tool returns, proceed to Phase B.

   **If all children have `ticket_type: task`** (route to `/dso:implementation-plan`):

   Invoke `/dso:implementation-plan <epic-id>` via Skill tool. When the Skill tool returns, proceed to Phase B.

   **Otherwise** (children are all epics or have unexpected ticket types): log a warning `"SC coverage REPLAN_TRIGGER: unexpected child types — no story or task children found; proceeding to Phase B without decomposition routing"` and proceed to Phase B.

3. Continue to Phase B.

#### Step 7: Epic Complexity Evaluation (/dso:sprint)

When the epic has zero children, dispatch the `dso:complexity-evaluator` agent to classify the epic's complexity before deciding the decomposition path. (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types.)

**Dispatch the evaluator:**

Read `agents/complexity-evaluator.md` inline and use `subagent_type: "general-purpose"` with `model: "haiku"`. Pass the epic ID as the task argument. Pass `tier_schema=SIMPLE` as a field in the task context so the agent outputs SIMPLE/MODERATE/COMPLEX tier vocabulary.

**Fallback**: If `agents/complexity-evaluator.md` is missing, fall back to `subagent_type: "general-purpose"` and load the shared rubric prompt from `$PLUGIN_ROOT/skills/sprint/prompts/` (see `epic-complexity-evaluator` prompt file in that directory).

**Route based on classification:**

| Classification | Confidence | Route |
|---------------|------------|-------|
| SIMPLE | high | Step 8 (Direct Implementation Planning) |
| SIMPLE | medium | Treat as MODERATE |
| MODERATE | high | Step 9 (Lightweight Preplanning) |
| MODERATE | medium | Treat as COMPLEX |
| COMPLEX | any | Step 10 (Full Preplanning) |

Log the classification: `"Epic <id> classified as <CLASSIFICATION> (confidence: <confidence>) — routing to <path>."`

#### Step 8: Direct Implementation Planning (SIMPLE epics) (/dso:sprint)

1. Log: `"Epic <id> classified as SIMPLE — running /dso:implementation-plan directly on epic."`
2. Invoke `/dso:implementation-plan` via Skill tool with the epic ID as the argument:
   ```
   Skill("dso:implementation-plan", args="<epic-id>")
   ```
   The skill handles epic type detection and runs inline (no sub-agent dispatch needed). When the Skill tool returns, immediately proceed to step 3.

3. Parse the skill's output using the same STATUS protocol as Phase B's Implementation Planning Gate
4. Set `epic_routing = "SIMPLE"` — this flag tells Phase B to skip the Implementation Planning Gate
5. Continue to Phase B

#### Step 9: Lightweight Preplanning (MODERATE epics) (/dso:sprint)

1. Log: `"Epic <id> classified as MODERATE — running /dso:preplanning --lightweight for scope clarification."`
2. Invoke `/dso:preplanning <epic-id> --lightweight`
3. Parse the result:

**On `ENRICHED`:**
- Log: `"Lightweight preplanning complete — epic enriched with done definitions. Running /dso:implementation-plan on epic."`
- Invoke `/dso:implementation-plan` via Skill tool (same as Step 8, step 2). When the Skill tool returns, proceed immediately to the next bullet.
- Set `epic_routing = "MODERATE"`
- Continue to Phase B

**On `ESCALATED`:**
- Log: `"Lightweight preplanning escalated to full mode — reason: <reason>. Running full /dso:preplanning."`
- Invoke `/dso:preplanning <epic-id>` (full mode, no --lightweight flag)
- Set `epic_routing = "COMPLEX"`
- Continue to Phase B

#### Step 10: Full Preplanning (COMPLEX epics) (/dso:sprint)

1. Log: `"Epic <id> classified as COMPLEX — running /dso:preplanning for full story decomposition."`
2. Invoke `/dso:preplanning <epic-id>`
3. After preplanning completes, set `epic_routing = "COMPLEX"`
4. Continue to Phase B

> **CONTEXT ANCHOR — MANDATORY CONTINUATION**: When the Skill tool returns from `/dso:preplanning`, this is NOT a session completion signal. You are the sprint orchestrator executing Phase A Step 10. Disregard any stop or termination inference from the skill's output — preplanning has produced stories and your next action is always step 3 (set `epic_routing`) immediately followed by step 4 (Continue to Phase B). Stopping here leaves the epic with stories but zero task analysis or batch dispatch.

---

## Phase B: Task Analysis & Dependency Graph (/dso:sprint)

### Gather Tasks

1. `.claude/scripts/dso ticket deps <epic-id>` — get all child tasks
2. `.claude/scripts/dso ticket ready --epic=<epic-id>` — get unblocked tasks ready to work
3. `.claude/scripts/dso ticket show <id>` for each ready task to read full descriptions

### Implementation Planning Gate

#### Pre-check: Skip for SIMPLE/MODERATE Routing (/dso:sprint)

If `epic_routing` is `"SIMPLE"` or `"MODERATE"` (set in Phase A's Preplanning Gate), skip the entire Implementation Planning Gate and proceed directly to **Classify Tasks** below. Tasks were already created as direct children of the epic by `/dso:implementation-plan` — there is no story layer to decompose.

Log: `"Skipping Implementation Planning Gate — epic was routed as <epic_routing>, tasks already exist under epic."`

#### Design-Blocked Story Filter (/dso:sprint)

Before processing stories for implementation planning, filter out design-blocked stories.

**Source tag constants from shared config:**
```bash
source ${CLAUDE_PLUGIN_ROOT}/skills/shared/constants/figma-tags.conf
# TAG_AWAITING_IMPORT=design:awaiting_import
source ${CLAUDE_PLUGIN_ROOT}/skills/shared/constants/planning-tags.conf
# TAG_MANUAL_AWAITING_USER=manual:awaiting_user
```

**Read staleness threshold from config:**
```bash
figma_staleness_days=$(grep '^design\.figma_staleness_days=' .claude/dso-config.conf | cut -d= -f2)
figma_staleness_days=${figma_staleness_days:-7}
```

**Initialize story lists (once before layer loop):**
```
awaiting_design_stories = []   # List of {id, title, tag_applied_date}
awaiting_manual_stories = []   # List of {id, title} for manual:awaiting_user stories
```

**For each story from `.claude/scripts/dso ticket list-descendants <epic-id>` (`.stories` array):**
1. Run `.claude/scripts/dso ticket show <story-id>` and check the `tags` field
2. If `design:awaiting_import` (i.e., `$TAG_AWAITING_IMPORT`) is present:
   - Log: `"Story <id> tagged design:awaiting_import — skipping implementation planning."`
   - Estimate the tag age from the ticket's comment timestamps: find the comment whose body contains `"Import designs/"` (written by ui-designer when the tag was applied) and read its `timestamp` field from the JSON output. Compute days elapsed: `$(( ($(date +%s) - comment_timestamp_epoch) / 86400 ))`. If no such comment exists, treat tag age as unknown (no staleness warning).
   - Add the story to the `awaiting_design_stories` list: `{id: "<story-id>", title: "<story-title>", tag_applied_date: "<date or unknown>"}`
   - **Do not add this story to the needs-planning list**. Skip all further processing for this story (no complexity eval, no implementation-plan dispatch, no batch dispatch in Phase E).
3. Only stories **without** the `design:awaiting_import` tag proceed to the `manual:awaiting_user` check below.

**Manual-awaiting-user check** (runs when `planning.external_dependency_block_enabled=true`):

Read the flag:
```bash
_manual_flag=$(grep '^planning.external_dependency_block_enabled=' .claude/dso-config.conf 2>/dev/null | cut -d= -f2)
```

For each story that passed the design filter:
1. If `_manual_flag` is `true`: check the `tags` field for `$TAG_MANUAL_AWAITING_USER` (`manual:awaiting_user`)
2. If present:
   - Log: `"Story <id> tagged manual:awaiting_user — deferring to manual-pause handshake."`
   - Add to `awaiting_manual_stories` list: `{id: "<story-id>", title: "<story-title>"}`
   - **Do not add this story to the needs-planning list.** Skip complexity eval and implementation-plan dispatch.
3. Only stories without `manual:awaiting_user` (or with `_manual_flag != true`) proceed to Step 1 below.

**Topological sort for manual stories:**

After populating `awaiting_manual_stories`, sort them so manual stories appear before their transitive autonomous dependents:
1. Build a dependency graph from `.claude/scripts/dso ticket deps` for each manual story
2. Sort: if manual story M1 is a dependency of M2, M1 appears first
3. **Cycle detection**: if M1 and M2 are both `manual:awaiting_user` and M1 blocks M2 AND M2 blocks M1, log `"CYCLE_DETECTED: manual stories <M1-id> and <M2-id> have mutual dependency"` and escalate to user — do not continue Phase D.

#### Step 1: Identify Stories Needing Implementation Planning (/dso:sprint)

For each ready task from `.claude/scripts/dso ticket ready --epic=<epic-id>`:
1. Run `.claude/scripts/dso ticket deps <task-id>` to check if the story already has child implementation tasks
2. If it has children → **skip** (already planned)
3. If it has zero children → run the complexity evaluator:

**Dispatch a haiku complexity-evaluator sub-agent** to classify the story. Read `agents/complexity-evaluator.md` inline and use `subagent_type: "general-purpose"` with `model: "haiku"`. (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types.) Pass the story ID as the task argument. Pass `tier_schema=TRIVIAL` as a field in the task context so the agent outputs TRIVIAL/MODERATE/COMPLEX tier vocabulary.

**Fallback**: If `agents/complexity-evaluator.md` is missing, fall back to `subagent_type: "general-purpose"` and load the shared rubric prompt from `$PLUGIN_ROOT/skills/sprint/prompts/` (see `complexity-evaluator` prompt file in that directory).

**Routing based on classification:**

| Classification | Confidence | Action |
|---------------|------------|--------|
| TRIVIAL | high | Skip `/dso:implementation-plan`. **File-count guard**: estimate the file count from the story description or `enrich-file-impact.sh`. If > 30 files, split into child tasks (≤ 30 files each) by directory or alphabetical range before proceeding. Log: `"Story <id> classified as TRIVIAL — skipping /dso:implementation-plan"` |
| TRIVIAL | medium | Treat as COMPLEX (medium confidence = plan) |
| MODERATE | any | Run `/dso:implementation-plan` via Skill tool (see Step 2) |
| COMPLEX | any | Run `/dso:implementation-plan` via Skill tool (see Step 2) |

**HARD PROHIBITION — never create tasks directly for stories without tasks.** When a story has zero children tasks, the orchestrator MUST follow this routing table. Creating tasks directly using `ticket create task` is ALWAYS prohibited. The planning gate is satisfied only when STATUS=READY is received from the formal planning pipeline (complexity evaluator → `/dso:implementation-plan` Skill invocation → STATUS parse). Bypassing the pipeline skips: proposal generation, distinctness gate, approach-decision-maker, and plan review.

**Post-routing action for COMPLEX stories**: After routing a story to `/dso:implementation-plan`, tag it so Phase E can upgrade implementation task models:
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

**Step D: Post-planning file-overlap promotion**

After `/dso:implementation-plan` completes for **all stories in a layer**, before beginning the next layer, check for file-level overlap between stories in the same layer:

1. **Collect file sets per story**: For each story in the layer, run `.claude/scripts/dso ticket deps <story-id>` to list its tasks, then for each task run `.claude/scripts/dso ticket show <task-id>` and extract every file path listed under `## Files to Modify` or `## File Impact`. Build a dict `story_files[<story-id>] = set(<file-paths>)`.

2. **Detect pairwise overlaps**: For each pair of stories (A, B) in the same layer where A has higher ticket priority (lower numeric priority value) than B:
   - Compute `overlap = story_files[A] ∩ story_files[B]`
   - If `|overlap| > 0`, log: `"FILE_OVERLAP: stories <A> and <B> share <N> files — promoting <B> to next layer. Shared: <first 5 overlap paths>..."`
   - Add a dependency: `.claude/scripts/dso ticket link <B-id> <A-id> depends_on`
   - Reassign story B to `current_layer + 1` in the layer map

3. **Re-log updated assignment**: After applying all promotions, log: `"Dependency layers after overlap check: Layer 0: <ids>, Layer 1: <ids>, ..."` so the audit trail reflects the final assignment.

4. **When priority is equal**: If A and B have equal numeric priority, prefer keeping the story that appears first in the layer list (by creation order) and promoting the other.

5. **Skip condition**: If a layer contains only one story, skip the overlap check for that layer (no pairs to compare). Log: `"FILE_OVERLAP check: Layer <N> has only 1 story — skipping."`.

This step fires **per layer**, after implementation-plan returns for the whole layer and before moving to the next. It is not applied retroactively to already-executed layers.

#### Step 2: Run Implementation Planning (/dso:sprint)

Process stories in layer order — Layer 0 first, then Layer 1, etc. Within each layer, invoke `/dso:implementation-plan` sequentially via Skill tool for each story that needs decomposition. Wait for all stories in the layer to complete before processing the next layer.

**Epic-level cascade counter (idempotent init — do NOT clobber a value set earlier in Phase A):**

```
replan_cycle_count = replan_cycle_count ?? 0
max_replan_cycles = read_config("sprint.max_replan_cycles", default=2)
```

Use `?? 0` (not `= 0`): the counter may already be initialized — and incremented — by the Phase A entry init (before the epic/non-epic branch) and the Drift Detection cascade. Unconditionally resetting to `0` here would discard drift-consumed cycles and weaken the cascade cap. This counter is shared across all stories in the epic. Each full brainstorm → preplanning → implementation-plan cascade iteration (regardless of which story triggered it) increments the counter by 1. This prevents unbounded loops when multiple stories each emit REPLAN_ESCALATE across cascade iterations.

**Per-story UNCERTAIN counter (initialize once before the layer loop):**

```
story_uncertain_counts = {}
```

This dictionary tracks the number of `STATUS:pass` + `UNCERTAIN` signals received per story across all batch iterations. Keys are parent story IDs (not task IDs). The counter persists across the Phase F → Phase C batch loop — do NOT re-initialize between batches. See Phase F Step 4 for parsing logic and Phase C Step 4 for double-failure detection.

**Out-of-scope review findings accumulator (initialize once before the layer loop):**

```
batch_out_of_scope_findings = []
```

This list collects out-of-scope files detected by `sprint-review-scope-check.sh`. In worktree-isolation mode (the default) the check runs per-worktree inside `per-worktree-review-commit.md` (post-review) and appends here; in shared-directory mode it is populated by Phase F Step 14. Each entry is a dict `{"task_id": "<id>", "story_id": "<parent>", "files": ["file1", ...]}`. The list is consumed between batches in Step 20 and cleared after processing. Do NOT process these findings mid-batch — they are only routed between batches to avoid task injection conflicts.

**For each layer (in order Layer 0, Layer 1, ...):**

a. Filter to stories in this layer that need decomposition
b. For each story in the layer, invoke `/dso:implementation-plan` via Skill tool:
   ```
   Skill("dso:implementation-plan", args="<story-id>")
   ```
   **HARD GATE — SUBSTITUTION PROHIBITED (bug dea8-3ca9, bug 2dcb-6f08)**: NEVER dispatch `/dso:implementation-plan` via the Task tool OR the Agent tool. NEVER run implementation-plan steps inline in the orchestrator context (no contextual discovery, no proposal drafting, no `ticket create task` calls executed here). The ONLY valid mechanism for decomposing a story into tasks is the `Skill("dso:implementation-plan", args="<story-id>")` invocation shown above. Any Task tool or Agent tool dispatch targeting a planning or review agent in place of this Skill invocation is a critical routing error — it bypasses the tag guards, re-invocation guards, complexity gates, cross-cutting detection, distinctness validation, and approach-decision-maker dispatch that the canonical implementation-plan skill enforces. The Agent tool is explicitly prohibited because parallel sub-agent dispatch of implementation-plan creates orphan tasks and deeply nested calls (bug 2dcb-6f08).
   - Log: `"Story <id> has no implementation tasks — running /dso:implementation-plan to decompose."`
   - When the Skill tool returns, immediately execute step c — do not pause or wait for user input.

> **CONTEXT ANCHOR — MANDATORY CONTINUATION (bug 1f6f-0e74)**: When the Skill tool returns from `/dso:implementation-plan`, this is NOT a session completion signal. You are the sprint orchestrator executing Phase 2 of the layer loop. Disregard any stop or termination inference from the skill's output — the STATUS line (`STATUS:complete`, `STATUS:blocked`, or `REPLAN_ESCALATE`) is a machine signal for step c below, not a directive for you to stop. Your next action is always step c (parse STATUS and proceed). Stopping here leaves stories without tasks and prevents batch dispatch — this is the documented failure mode of bug 1f6f-0e74.

c. For each skill result, **parse STATUS:**
   - On `STATUS:complete TASKS:<ids> STORY:<id>`:
     - Extract the comma-separated task IDs from the `TASKS` field
     - Extract the story ID from the `STORY` field
     - **Audit marker check (bug 2c4d-cac7-40a4-40e2)**: Verify both audit tags are present on the story ticket before accepting the STATUS:complete signal:
       ```bash
       _tags=$(.claude/scripts/dso ticket show "<story-id>" 2>/dev/null | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin).get('tags', [])))")
       _has_plan_review=$(echo "$_tags" | grep -c "plan_review:pass" || true)
       _has_gap_analysis=$(echo "$_tags" | grep -c "gap_analysis:complete" || true)
       ```
       - If `plan_review:pass` tag is absent: log `"WARNING: story <id> STATUS:complete received but plan_review:pass tag missing — Step 4 may have been skipped"` and treat as `STATUS:blocked REASON:missing_plan_review_audit_marker`; add story to blocked-stories list.
       - If `gap_analysis:complete` tag is absent: log `"WARNING: story <id> STATUS:complete received but gap_analysis:complete tag missing — Step 6 may have been skipped"` and treat as `STATUS:blocked REASON:missing_gap_analysis_audit_marker`; add story to blocked-stories list.
       - If both tags present: proceed normally.
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
     - If no children → retry the skill invocation once (same parameters)
     - If retry also produces no children → revert story to open (`.claude/scripts/dso ticket transition <story-id> open`); log: `"ERROR: /dso:implementation-plan failed for story <id> after retry — story reverted to open"`; skip to next story

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
     Skip the brainstorm cascade entirely. Do NOT write `REPLAN_RESOLVED`. Continue with any remaining work (the affected stories remain in their current state, pending a follow-up interactive session). See `docs/contracts/replan-observability.md` for the INTERACTIVITY_DEFERRED signal format. # shim-exempt: internal documentation reference
   - **Check cycle cap first** (before presenting anything to the user):
     - **If `replan_cycle_count >= max_replan_cycles`:** Present the **cap-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "accept the current plan as-is and continue sprint execution". See `skills/sprint/docs/cascade-replan-protocol.md` §"When Max Cycles Are Hit". # shim-exempt: internal documentation reference
     - **If cap is not yet exhausted:** Present the **cap-not-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "accept the current state and continue sprint with these stories as-is".
     - **If user selects (b) or (c):** act accordingly — proceed or abort. Do not enter cascade.
     - **If user selects (a):** Enter the cascade replan per `skills/sprint/docs/cascade-replan-protocol.md`: # shim-exempt: internal documentation reference
       1. Invoke `/dso:brainstorm <epic-id>` via Skill tool
       2. Invoke `/dso:preplanning <epic-id>` via Skill tool
       3. Increment `replan_cycle_count += 1`
       4. Re-run Step 2 (implementation planning) for all stories in the epic — re-enter the layer loop from the beginning
       5. If implementation-plan returns no `REPLAN_ESCALATE` for any story: write the resolved signal, then cascade exits — proceed to step e normally (plan accepted):
          ```bash
          .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: brainstorm — Stories re-planned after brainstorm cascade."
          ```
       6. If implementation-plan still emits `REPLAN_ESCALATE`: repeat from d-replan-collect (check cap first, then present to user)
e. **Post-layer-batch ticket validation**:
   ```bash
   .claude/scripts/dso validate-issues.sh --quick --terse
   ```
   Log any warnings but do not block on non-critical results
f. Re-run `.claude/scripts/dso ticket ready --epic=<parent-id>` to pick up newly created implementation tasks before processing the next layer

#### Step 3: Continue to Classification (/dso:sprint)

Proceed to task classification with the updated task list.

### Classify Tasks

Classification is performed automatically by `ticket next-batch` in Phase C (Batch Preparation). Each `TASK:` line in its output already includes `model`, `subagent`, and `class` fields — no separate classification step is needed here. Proceed directly to building the dependency graph below.

### Build Dependency Graph

Output a textual dependency graph showing:
- All child tasks with status
- Blocking relationships (arrows)
- Batch assignment for ready tasks

### Exit Condition

If no ready tasks exist:
1. Parse the `skipped_blocked_story` / `skipped_overlap` / `skipped_in_progress` / `skipped_needs_planning` arrays from the most recent `.claude/scripts/dso ticket next-batch <epic-id> --json` output (already computed in Phase C). These arrays identify the epic-scoped tasks that were eligible but deferred and the reason for each.
2. For transitive chains (A blocks B blocks C), run `.claude/scripts/dso ticket deps <id>` on each surfaced blocked ticket to walk blockers one hop at a time. Do NOT re-read the full ticket list.
3. Report which tasks are blocked and by what
4. Exit with recommendation

---

## Phase C: Batch Preparation (/dso:sprint)

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

**Recipe Engine Pre-flight**

After cleaning discoveries, validate engine availability for recipe-tagged tasks in the upcoming batch:

```bash
_TASK_FILE=$(mktemp /tmp/task-list.XXXXXX.json)
.claude/scripts/dso ticket next-batch <epic-id> --json > "$_TASK_FILE" 2>/dev/null || echo "[]" > "$_TASK_FILE"

RECIPE_REGISTRY_PATH="${CLAUDE_PLUGIN_ROOT}/recipes/recipe-registry.yaml" \
TASK_LIST_FILE="$_TASK_FILE" \
  bash "$PLUGIN_SCRIPTS/sprint/check-recipe-engines.sh"  # shim-exempt: internal orchestration script
rm -f "$_TASK_FILE"
```

Parse output and act:
- `NO_RECIPE_TASKS`: Log `"No recipe tasks in batch — skipping engine pre-flight"` and continue.
- `ENGINES_OK`: Log `"Engine pre-flight passed"` and continue.
- `MISSING_ENGINE: <e>` or `OUTDATED_ENGINE: <e>`: Surface a warning listing missing/outdated engines. Store the `MISSING_ENGINES_LIST=<csv>` value from output in session context for S5 fallback consumption.

Pre-flight does NOT block sprint execution — warn and continue regardless of engine availability.

**MAX_AGENTS protocol** (3-tier):

| `max_agents` value | Behavior |
|---------------------|----------|
| `unlimited` | Dispatch all ready tasks in a single batch with no artificial cap. Pass `--limit=unlimited` (or omit `--limit`) to `ticket next-batch`. |
| `N` (positive integer) | Cap the batch at N sub-agents. Pass `--limit=N` to `ticket next-batch`. Log: `"Session usage elevated, limiting to N sub-agent(s)."` |
| `0` | Skip sub-agent dispatch entirely. Write a ticket comment with utilization percentages and estimated reset time, then proceed to Phase F Step 20 (Continuation Decision). Log: `"MAX_AGENTS=0 — session at critical utilization, skipping dispatch."` Comment format: `.claude/scripts/dso ticket comment <epic-id> "BATCH_SKIPPED: MAX_AGENTS=0. Session utilization: <SESSION_USAGE>. Estimated reset: next session."` |

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

### Step 3.5: Two-Pass Migration Ordering

<!-- CHECKPOINT: Two-Pass Migration Ordering subsection added per task ed30-3675-cbf7-40bc (story 982a). -->

Before composing the batch, wire migration task pair ordering so that the verification/cleanup half of each pair is scheduled after the half it validates. This step reads the persisted `MIGRATION_CLASS:` marker (written by `/dso:implementation-plan` Step 1) from each descendant story's ticket comments — it does **NOT** recompute detection.

**Scope**: This step is epic-scoped. Enumerate all descendant story IDs for the current epic, then invoke the helper once per story that has migration-role-tagged tasks:

```bash
# Collect task pairs with migration-role tags for the story
# TASKS_ARG format: "task-id:migration-role ..." — built by inspecting task tickets
#   under the story for `migration-role:<role>` tags.
# Valid roles: automated-sweep, manual-verification, forward-migration,
#              rollback-verification, flag-cutover, flag-cleanup
bash "${CLAUDE_PLUGIN_ROOT}/scripts/sprint/apply-two-pass-ordering.sh" \
  --story-id <story-id> \
  --tasks "<task-id>:<role> <task-id>:<role>"
```

**Idempotency**: The helper checks for existing `depends_on` edges before writing. Repeated per-batch invocation is safe — no once-per-story guard is needed.

**Three reserved pair types** (wired by the helper):

| Migration class | Pair roles | Edge written |
|-----------------|------------|--------------|
| `sweep` | `automated-sweep` / `manual-verification` | `manual-verification` depends_on `automated-sweep` |
| `db` | `forward-migration` / `rollback-verification` | `rollback-verification` depends_on `forward-migration` |
| feature-flag (role presence only) | `flag-cutover` / `flag-cleanup` | `flag-cleanup` depends_on `flag-cutover` |

Note: the feature-flag pair is detected by **role presence alone** — it does not require a `MIGRATION_CLASS:` marker value.

**Absent-marker fallback**: When a story has no `MIGRATION_CLASS:` marker (or the marker value is `inconclusive`) **and** no feature-flag pair roles are present on its tasks, the helper emits `NO_MARKER` on stderr and writes no edges. Standard batch ordering from `ticket next-batch` applies unchanged. This is the expected path for stories with no migration task pairs; it is not an error.

**Story enumeration**: Obtain descendant story IDs via:

```bash
.claude/scripts/dso ticket list-descendants <epic-id>
```

Filter the output to `story` type tickets. For each story, collect tasks tagged `migration-role:<role>` and pass them to the helper. Stories with no migration-role-tagged tasks are skipped (the helper call is unnecessary for them, but safe if inadvertently invoked with no `--tasks` argument).

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
.claude/scripts/dso ticket next-batch <epic-id>
# When max_agents is a positive integer N:
.claude/scripts/dso ticket next-batch <epic-id> --limit=N
# When max_agents is 0: do NOT call ticket next-batch — skip dispatch (see Phase C Step 1 protocol)
```

- **`max_agents`**: Determined by Step 1's pre-batch check (3-tier: `unlimited`, `N`, or `0`).
- **`unlimited`**: Returns the full non-conflicting pool — dispatch all candidates.
- **`N`** (positive integer): Caps batch at N tasks.
- **`0`**: Skip dispatch entirely — do not call `ticket next-batch`. Write the utilization comment per Phase C Step 1 protocol and proceed to Phase F Step 20.

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
| `SKIPPED_MANUAL_AWAITING: <id> <title>` | Deferred — story tagged `manual:awaiting_user` (manual user input required; only emitted when `planning.external_dependency_block_enabled=true`) |

**Parsing `SKIPPED_DESIGN_AWAITING` lines:** After running `ticket next-batch`, parse any `SKIPPED_DESIGN_AWAITING` lines from the output. For each such line, extract the story ID and title and add them to the `awaiting_design_stories` list (if not already present from Phase B filtering). These stories are surfaced in the Phase F Batch Completion Summary "Awaiting designer input" section.

**`manual:awaiting_user` filter** (when `planning.external_dependency_block_enabled=true`): Stories tagged `manual:awaiting_user` are excluded from the autonomous batch and surfaced as `SKIPPED_MANUAL_AWAITING` lines. After autonomous stories drain, sprint enters Phase D (Manual-Pause Handshake), which presents a blocking handshake listing per-story instructions and an optional `verification_command`. Accepts: `done`, `done <story-id>`, `skip`. Handles `verification_command` execution (timeout: `planning.verification_command_timeout_seconds`, default 30s) and confirmation-token audit logging. Topological sort surfaces manual stories before their transitive autonomous dependents. Schema: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`.

#### Interaction Conflict Filter (/dso:sprint)

Before dispatching any task from the batch, filter out tasks whose parent epic is tagged `interaction:deferred`.

**For each `TASK:` line returned by `ticket next-batch`**:

1. Identify the parent epic of the task (via `story:<id>` field if present, or the `<epic-id>` directly for top-level tasks).
2. Run `.claude/scripts/dso ticket show <epic-id>` and check the `tags` field.
3. If `interaction:deferred` is present in the tags:
   - Log: `"Epic <id> skipped — interaction:deferred tag present. Resolve cross-epic conflicts in /dso:brainstorm first."`
   - Remove this task from the dispatch batch. Do NOT mark the task `in_progress` and do NOT dispatch a sub-agent for it.
4. If `interaction:deferred` is NOT present: include the task in the batch normally.

**Failure contract**: If `ticket show` fails for a given epic, treat the tag as absent and include the task (fail-open).

**No error is thrown** when tasks are filtered — sprint continues with the remaining batch. If all tasks are filtered and `BATCH_SIZE` drops to 0 after filtering, proceed to Phase F Step 20 (Continuation Decision) rather than treating it as a blocking error. Log: `"All batch tasks filtered — interaction:deferred tag present on parent epic(s). Resolve cross-epic conflicts to proceed."`

Use `--json` for machine-readable output with full detail including file lists.

#### What the script handles (no orchestrator action required)

- **Story-level blocking**: Blocked story → all child tasks deferred
- **File overlap**: Higher-priority task wins; lower defers to next cycle
- **Classification**: TASK lines include `model`, `subagent`, `class` sorted by classify priority then ticket priority
- **Opus cap**: At most 2 `model=opus` tasks per batch; extras deferred

#### Exit condition

If `BATCH_SIZE: 0`, parse the `skipped_*` arrays from the `sprint-next-batch.sh --json`
output (already produced above) to surface the blocking chain. Walk transitive blockers
via `.claude/scripts/dso ticket deps <id>` on each surfaced blocked ticket. Report to
the user and exit.

#### Dependency-Aware Overlap Analysis (optional, when sg is available)

After running `ticket next-batch`, use ast-grep (`sg`) for structural dependency
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

After composing the batch, check each task's parent story against the `story_uncertain_counts` map (initialized in Phase B Step 2) **before dispatching**:

1. For each `TASK:` line in the batch output, extract the parent story ID from the `story:<id>` field.
2. Look up `story_uncertain_counts[<story-id>]`. If the count is **>= 2**, do NOT dispatch the task. Instead:
   a. Record the re-plan trigger on the epic **before** invoking implementation-plan (so the audit trail exists even if re-planning fails):
      ```bash
      .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: failure — Story <story-id> had 2+ UNCERTAIN signals. Routing to implementation-plan."
      ```
   b. Re-invoke `/dso:implementation-plan <story-id>` via the Skill tool to re-plan the story. When the Skill tool returns, proceed immediately to step c.

   c. After re-planning completes, record resolution:
      ```bash
      .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: implementation-plan — Story <story-id> re-planned after confidence failures."
      ```
   d. Reset `story_uncertain_counts[<story-id>] = 0` so the story does not immediately re-trigger on the next batch.
   e. Remove the affected task(s) from the current batch and proceed with the remaining tasks. The re-planned story's new tasks will be picked up in the next batch cycle.
3. Tasks whose parent story has a count of 0 or 1 are dispatched normally.

**Key invariant**: Only `STATUS:pass` + `UNCERTAIN` signals (tracked in Phase F Step 4) count toward this threshold. `STATUS:fail` tasks are handled via revert-to-open in Phase F Step 16 and do not affect this counter.

### Pre-Dispatch: Push Session Branch (worktree isolation fix)

Before dispatching any sub-agents, detect whether the orchestrator is running in a session worktree:

```bash
IS_SESSION_WORKTREE=$([ -f "$(git rev-parse --show-toplevel)/.git" ] && echo "true" || echo "false")
```

If `IS_SESSION_WORKTREE=true`, push the session branch so sub-agent worktrees can fetch it:

```bash
# Push session branch so sub-agent worktrees can sync to session HEAD (bug 4724-41a7)
git push -u origin HEAD
SESSION_HEAD=$(git rev-parse HEAD)
SESSION_BRANCH=$(git rev-parse --abbrev-ref HEAD)
```

Inject `SESSION_BRANCH` and `SESSION_HEAD` into each sub-agent's prompt (see `worktree-dispatch.md` for the injection protocol).

If `IS_SESSION_WORKTREE=false` (orchestrator on main), skip the push.

### Dry-Run Mode

If `--dry-run` was specified:
1. Run `ticket next-batch <epic-id>` (no `--limit`) to get the full pool
2. For each story that needs implementation planning (Phase B gate), output one line per story:
   ```
   Dispatching impl-plan sub-agent for story <story-id>: <story-title>
   ```
3. Output the batch plan: task IDs, titles, model, subagent, class
4. **Stop** — do not execute any sub-agents

---

## Phase D: Manual-Pause Handshake (/dso:sprint)

This phase runs **only** when all of the following are true:
- `planning.external_dependency_block_enabled=true`
- `awaiting_manual_stories` list is non-empty
- All autonomous tasks in the current batch have completed (or there are no autonomous tasks in this batch)

### Pause State Management

Before starting the handshake, manage the pause state file via `sprint/sprint-pause-state.sh` (the SIGURG recovery state manager):

```bash
# 1. Remove stale state files from prior sessions (fail-open — no-op when flag is off)
.claude/scripts/dso sprint/sprint-pause-state.sh stale-cleanup  # shim-exempt: internal orchestration script

# 2. Check whether a pause state already exists for this epic (--resume path)
.claude/scripts/dso sprint/sprint-pause-state.sh is-fresh <epic-id>  # shim-exempt: internal orchestration script
```

- **If `is-fresh` exits 0** (fresh state exists): a prior SIGURG interrupted the handshake. Present the user with: `"Found existing pause state for epic <epic-id>. Use --resume when re-invoking sprint to continue the handshake."` Then call `sprint/sprint-pause-state.sh resume-context <epic-id>` to get the first unanswered story and rehydrate the handshake from that story forward.
- **If `is-fresh` exits non-zero** (no fresh state): call `sprint/sprint-pause-state.sh init <epic-id>` to create a fresh state file.

```bash
# 3. Initialize fresh pause state (no-op when flag is off or state already fresh)
.claude/scripts/dso sprint/sprint-pause-state.sh init <epic-id>  # shim-exempt: internal orchestration script
```

**SIGURG trap**: register `_spause_sigurg_handler <epic-id>` (by sourcing `sprint/sprint-pause-state.sh`) as the SIGURG handler. On interrupt, the handler sets `in_progress_marker=false` without removing the state file — the state is preserved for `--resume` on re-invocation.

**Per-story state writes**: after each manual story answer is collected via `sprint-manual-drain.sh`, record the answer:

```bash
.claude/scripts/dso sprint/sprint-pause-state.sh write <epic-id> <story-id> <answer>  # shim-exempt: internal orchestration script
```

**After all stories answered**: call `sprint/sprint-pause-state.sh cleanup <epic-id>` to remove the state file.

### Handshake Input Contract

Stories tagged `manual:awaiting_user` are collected into `awaiting_manual_stories` and presented to the practitioner one at a time by `sprint-manual-drain.sh`. The script accepts three inputs per story:

- **`done`** — story complete; if a `verification_command` is present, execute it in a constrained subshell (timeout: `planning.verification_command_timeout_seconds`, default 30s); if absent, require a user-typed confirmation token (`MANUAL_CONFIRMATION_TOKEN`) and log it as a ticket comment audit entry.
- **`done <story-id>`** — same as `done` but explicitly names the story, used when multiple stories are presented.
- **`skip`** — mark the story skipped; `sprint-manual-drain.sh` writes a sentinel with `handshake_outcome=skip` and propagates skip to transitive dependents.

**Confirmation-token audit path**: when `verification_command` is omitted, `sprint-manual-drain.sh` prompts for a `MANUAL_CONFIRMATION_TOKEN` (a short user-typed string) and writes it as a `MANUAL_PAUSE_SENTINEL` ticket comment. `dso:completion-verifier` reads this sentinel at Phase F Step 18 to verify the manual story without re-executing the manual step.

**Steps:**

1. Write the sorted manual story list to a temp JSON file. Each entry must include the fields expected by `sprint-manual-drain.sh`:
   ```bash
   # Write JSON array to temp file
   MANUAL_JSON_FILE=$(mktemp /tmp/sprint-manual-stories-XXXXXX.json)
   # Array format: [{"id":"<id>","title":"<title>","instructions":"<desc>","verification_command":<cmd|null>,"deps":[...]}]
   ```

2. Call the manual-drain script via the host-project shim:
   ```bash
   .claude/scripts/dso sprint/sprint-manual-drain.sh "$MANUAL_JSON_FILE"  # shim-exempt: internal orchestration script
   ```

3. Parse the exit code:
   - **0**: all manual stories handled — proceed to Phase E (or Phase F if no autonomous tasks remain in this batch)
   - **1**: skip propagation applied — log skipped stories and proceed; skipped stories have a sentinel written with `handshake_outcome=skip`
   - **2**: re-prompt required (this should not occur — `sprint-manual-drain.sh` handles re-prompting internally; if it surfaces here, log as an error and escalate to user)

4. After handshake completes: run `.claude/scripts/dso ticket next-batch <epic-id>` again to pick up any autonomous stories that were unblocked by the manual step completion.

5. Clean up: `rm -f "$MANUAL_JSON_FILE"` and `sprint/sprint-pause-state.sh cleanup <epic-id>`

---

## Phase E: Sub-Agent Launch (/dso:sprint)

# Story branches: story/<epic-id>/<story-id>; created here, merged in Phase F with DSO-Story-Merge trailer.
# In worktree-isolation mode (default), this branch is a logical ticket-tracking container — actual file movement happens via per-task harvest into the session branch (Phase F Step 5; see "Cross-Layer File Visibility Invariant" in Phase F worktree-isolation block).

Before dispatching tasks for a story, create the story branch and capture the branch name:

```bash
STORY_BRANCH=$(bash "$PLUGIN_SCRIPTS/create-story-branch.sh" "$EPIC_ID" "$STORY_ID") # shim-exempt: SKILL.md orchestrator instruction — sprint runs plugin scripts via $PLUGIN_SCRIPTS directly
# STORY_BRANCH = story/<epic-id>/<story-id>; used by Phase F after all worktrees harvested
```

### Predecessor Handoff Check

Before dispatching a story sub-agent, check predecessor verdict when applicable:

```bash
if [[ -n "$_PREDECESSOR_STORY_ID" ]]; then
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-story-handoff.sh" \  # shim-exempt: internal orchestration script
        --predecessor-story-id="$_PREDECESSOR_STORY_ID"
    _HANDOFF_RC=$?
    if [[ $_HANDOFF_RC -ne 0 ]]; then
        echo "DISPATCH_BLOCKED: predecessor $PREDECESSOR_STORY_ID verdict != PASS"
        # add to blocked list; do not dispatch this story
    fi
fi
```

<HARD-GATE>
Do NOT implement any task directly using Edit, Write, or other file-modification tools. ALL implementation tasks are dispatched to sub-agents via the Task tool. Direct implementation by the orchestrator bypasses checkpoint protocol, code review, and acceptance criteria gates.

Do NOT improvise new patterns, variables, or approaches when a user rejects the approved plan. When the user rejects an approach mid-execution:
1. **STOP** the current batch — do not apply ad-hoc substitutes.
2. Record `REPLAN_TRIGGER: user_rejection — User rejected <approach>. Reason: <reason>.` on the epic.
3. Re-invoke `/dso:implementation-plan` for the affected stories to produce a revised plan that incorporates the user's feedback.
4. Only resume execution after the revised plan passes `/dso:plan-review`.

Inventing unauthorized patterns (new variables, alternative sed commands, manual workarounds) to work around a rejected plan is the exact failure mode this gate prevents — it produces untested, unreviewed changes that bypass the re-planning protocol (2f26-430e).
</HARD-GATE>

**Explore dispatch parallelism rule (7c45-ee60):** When dispatching Explore sub-agents for search tasks, each Explore call MUST be scoped to a single, targeted search objective. Do NOT dispatch a single Explore sub-agent to search for multiple unrelated code patterns, files, or references in one call.

Instead, parallelize: dispatch one Explore sub-agent per distinct search objective within the same message using `run_in_background: true`. For example:
- BAD: Single Explore dispatched to "find isolation guard code AND all references to it"
- GOOD: Two parallel Explore dispatches — one for "find isolation guard code" and one for "find all references to isolation guard"

A single broad Explore dispatch is a known anti-pattern that produces lower quality results and misses edge cases. Always parallelize independent search objectives.

Launch up to `max_agents` sub-agents (determined by Phase C Step 1's MAX_AGENTS protocol — `unlimited`, `N`, or `0`) via the Task tool. When `max_agents=0`, this phase is skipped entirely (see Phase C Step 1). Each sub-agent gets a structured prompt:

### Retry Budget Parsing (sub-agent dispatch)

Before dispatching each sub-agent task, the orchestrator MUST parse the `## Retry Budget` block from the task description and honour it during the dispatch loop. This is distinct from the red-test-writer Tier 1/2/3 escalation in `### RED Task Dispatch — Escalation Protocol` below — it governs the dispatch retry budget for the task sub-agent itself.

**Fields parsed from each task description's `## Retry Budget` block:**

- `MAX_ATTEMPTS` — per-tier attempt cap (default: 3). The orchestrator retries the sub-agent up to this many times on the base tier before escalating model.
- `MODEL_TIER_ORDER` — ordered list of model tiers, e.g. `sonnet, opus`. The first tier is the base; subsequent tiers are escalation targets.
- `ESCALATION_DIAGNOSTICS` — when escalating tiers, the orchestrator collects all prior failure messages and forwards them as diagnostic context to the next tier.

**Sub-agent failure protocol (MAX_ATTEMPTS-driven, sonnet→opus escalation):**

1. **Base tier (sonnet)** — Retry the sub-agent up to `MAX_ATTEMPTS` (default: 3) on `sonnet`. Each retry receives the prior failure message in its prompt.
2. **Escalate to opus** — After 3 sonnet failures (MAX_ATTEMPTS exhausted on the base tier), collect all 3 failure messages and re-dispatch on `opus` with the concatenated diagnostic context. The opus tier also gets `MAX_ATTEMPTS` (default: 3) attempts.
3. **Escalate to user** — After 3 opus failures (6 total attempts across both tiers), STOP the dispatch loop and escalate to the user with the full failure history (all 6 messages plus diagnostic context). Do NOT silently drop the task or mark it complete.
4. **MAX_AGENTS: 0 mid-escalation** — If the throttle verdict reaches `MAX_AGENTS: 0` at the sonnet→opus escalation boundary, SKIP the opus tier entirely and escalate to the user immediately. This avoids burning the larger model budget under throttle.

**Defaults when `## Retry Budget` block is absent from a task description:** `MAX_ATTEMPTS=3`, `MODEL_TIER_ORDER=sonnet,opus`. Tasks without an explicit retry budget still receive the same sonnet→opus escalation behaviour for backward compatibility.

### Display Batch Task List

Print a numbered list of all tasks in the batch. Each line must show the task ID and title:

```
1. [dso-abc1] Fix authentication bug
2. [dso-def2] Add rate limiting to API endpoints
3. [dso-ghi3] Refactor session management
```

Titles are parsed from the `TASK:` tab-separated lines produced by `ticket next-batch` — the last field in each `TASK:` line is the title. No additional `.claude/scripts/dso ticket show` calls are needed.

### Blackboard Write and File Ownership Context

Before dispatching sub-agents, create the blackboard file and build per-agent file ownership context:

1. **Write the blackboard**: Pipe the batch JSON (from `ticket next-batch --json` in Phase C Step 4) to `write-blackboard.sh`:
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

Before dispatching sub-agents, read and apply `skills/shared/prompts/worktree-dispatch.md` for worktree isolation configuration.

Read the config key:
```bash
ISOLATION_ENABLED=true  # worktree isolation is always enabled
```

When `ISOLATION_ENABLED` equals `true`, add `isolation: "worktree"` to each Agent/Task dispatch call and inject `SESSION_BRANCH` / `SESSION_HEAD` (so sub-agents can sync to session HEAD via `worktree-session-head-sync.sh`). Do NOT inject the orchestrator's session-worktree absolute path into sub-agent prompts — per bug 9679-695c-6e11-4d95, sub-agents derive their own `REPO_ROOT` from their own `git rev-parse --show-toplevel`. When `ISOLATION_ENABLED` is `false`, empty, or absent, omit the `isolation` parameter entirely.

**Parallel dispatch and stale HEAD**: All worktrees in a batch branch from the session HEAD at the moment of dispatch. When sub-agents are dispatched in parallel and harvested serially, the second and later harvests will encounter merge conflicts because those worktrees were created before earlier harvests advanced the session HEAD. This is **expected and normal** — not a bug. The per-worktree-review-commit.md conflict queue protocol (Step 6 exit 1) handles this case: after the clean worktrees are harvested, conflicting worktrees are rebased onto the updated session HEAD and re-processed through the review → commit → harvest pipeline. No full task re-implementation is needed for conflicts that arise solely from this ordering effect.

### Design Context Population

Before dispatch, source the figma tag constants and check whether the parent story has the `design:approved` tag:

```bash
# Source tag constants
REPO_ROOT=$(git rev-parse --show-toplevel)
source "${CLAUDE_PLUGIN_ROOT}/skills/shared/constants/figma-tags.conf"
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

> **Named-agent dispatch invariant**: Attempt dispatch via `subagent_type: "dso:<agent-name>"` first. Read the agent file (e.g., `agents/<agent-name>.md`) and pass its content inline **only** when the dispatch returns an "Unknown agent" or "agent type not registered" error in the current session. Reading the agent file before the dispatch attempt wastes context tokens, leaks agent internals into the orchestrator window, and inverts the fallback contract. Exception: agents documented as "NOT a valid `subagent_type` value" (e.g., `dso:complexity-evaluator`) always use `general-purpose` + inline read — no named dispatch to attempt.

For each task, launch a Task with the appropriate `subagent_type`.

**Quality gate (ticket-as-prompt)**: Before dispatch, run the quality check:
```bash
.claude/scripts/dso issue-quality-check.sh <task-id>
```

- **Exit 0 (quality pass)**: Use ticket-as-prompt template (`$PLUGIN_ROOT/skills/sprint/prompts/task-execution.md`), fill in `{id}`, `{escalation_policy}`, `{TEST_CMD}`, `{LINT_CMD}`, and `{FORMAT_CHECK_CMD}` (see COMPLEX detection and escalation policy extraction below; `TEST_CMD`, `LINT_CMD`, `FORMAT_CHECK_CMD` are resolved in the Config Resolution block above).
- **Exit 1 (too sparse)**: Try `.claude/scripts/dso enrich-file-impact.sh <task-id>`, re-run check. If still failing, fall back to inline prompt via `.claude/scripts/dso ticket show <id>`.

**Acceptance criteria gate**: After the quality gate, run:
```bash
.claude/scripts/dso check-acceptance-criteria.sh <task-id>
```

- **Exit 0**: Proceed with dispatch — task has structured AC block
- **Exit 1**: Do NOT dispatch. Read `${CLAUDE_PLUGIN_ROOT}/docs/ACCEPTANCE-CRITERIA-LIBRARY.md`, compose AC, add via `.claude/scripts/dso ticket comment <id> "## Acceptance Criteria\n<criteria>"`. Re-run check. If criteria undeterminable, ask user.

### Subagent Type and Model Selection

Use the `model` and `subagent` fields from the `TASK:` lines produced by
`ticket next-batch` in Phase C Step 4 — **no additional classify-task.sh call needed**.

When launching each Task tool call, set `subagent_type` and `model` from the TASK line, then apply the decision table below in order (first matching row wins):

| parent_story_has_design_approved | parent_story_complex | task_model | task_class | action |
|----------------------------------|---------------------|------------|------------|--------|
| `true` (revision image present) | any | any | any | Override `model` to minimum `sonnet` (if current model is `haiku`, upgrade to `sonnet`; if already `sonnet` or `opus`, no change). Log: `"design:approved story — enforcing sonnet minimum for multimodal."` |
| any | any | any | any (doc-story title match) | Use `subagent_type: "general-purpose"` with `model: "sonnet"`. Read `agents/doc-writer.md` inline and pass its content verbatim as the prompt. (`dso:doc-writer` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types.) Pass `epic_context` and `git_diff` context fields (see Documentation Story Dispatch below). Log: `"Documentation story detected — dispatching to dso:doc-writer instead of generic agent."` |
| any | `COMPLEX` | `sonnet` | `skill-guided` | No model upgrade. Append skill check guidance to prompt (see below). |
| any | `COMPLEX` | `sonnet` | any other | Override `model` to `opus`. Log: `"Story <parent-id> classified COMPLEX — upgrading task <task-id> model to opus."` |
| any | `COMPLEX` | `opus` | any | No change (already opus). |
| any | not COMPLEX | any | `skill-guided` | No model upgrade. Append skill check guidance to prompt (see below). |
| any | not COMPLEX | any | any other | No change — use `model` and `subagent` from TASK line as-is. |

**Doc-story title match**: Task title or parent story title matches `Update project docs to reflect`.

**Doc-story detection heuristics (apply ALL of these — not just title match):**
A story is a documentation story if ANY of the following are true:
1. Story title contains "doc", "document", "update", "add to", "CLAUDE.md", "KNOWN-ISSUES", "DESIGN.md", "README"
2. Story title starts with "As a" AND acceptance criteria mention documentation files
3. Any child task references a `.md` file in `.claude/docs/`, `docs/`, or the repo root

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

When the doc-story title match triggers: **do NOT implement documentation changes directly** — this gate is unconditional. The doc-writer agent enforces structural and bloat constraints that the orchestrator does not. Read `agents/doc-writer.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "sonnet"`. The doc-writer agent receives two named context fields:
```
subagent_type: "general-purpose"
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

### Copy Story Dispatch (gov-copy-writer)

A story is a **copy story** when EITHER (a) it carries the `copy-story` tag (set by `dso:story-decomposer` auto-create protocol Step C3), OR (b) its title begins with the verbatim prefix `"Apply gov-copy to "` (case-insensitive — the title pattern produced by the same protocol). These two signals are the canonical producer/consumer contract and MUST match the values story-decomposer writes (see `${CLAUDE_PLUGIN_ROOT}/agents/story-decomposer.md` Step C3). Copy stories are dispatched to `dso:gov-copy-writer` — not the generic task sub-agent. Copy stories are also exempt from `/dso:implementation-plan` decomposition (see implementation-plan SKILL.md copy-story bypass — `STATUS:bypass REASON:copy_story`).

**Before dispatching `dso:gov-copy-writer`**, resolve the artifact output path:

```bash
ARTIFACT_PATH=$(bash "$PLUGIN_SCRIPTS/resolve-copy-artifact-path.sh" \  # shim-exempt: internal orchestration script
    "$EPIC_ID" \
    --project-root "$(git rev-parse --show-toplevel)")
if [[ $? -ne 0 ]]; then
    echo "HALT: resolve-copy-artifact-path.sh failed — check copy.artifact_dir in .claude/dso-config.conf" >&2
    exit 1
fi
```

`resolve-copy-artifact-path.sh` reads `copy.artifact_dir` from `dso-config.conf` (default: `"copy/"`) and invokes `copy_artifact_path.py` to validate and resolve the absolute artifact path. It exits non-zero when the configured path is absolute, contains `..` traversal, or resolves outside the project root.

**Inject `{artifact_path}` into the agent's task arguments**:

```
subagent_type: "dso:gov-copy-writer"
model: "sonnet"
context:
  copy_needs_section: |
    <## Copy Needs section from the epic ticket>
  epic_context: |
    <epic title, description, user archetypes, design notes>
  artifact_path: |
    <resolved ARTIFACT_PATH from above>
  design_context: |
    <design notes if epic has design:approved tag, else empty>
```

**Dispatch-target fallback** (only on "Unknown agent type" error): if the named `subagent_type: "dso:gov-copy-writer"` is not registered in the current Agent tool registry, fall back to `subagent_type: "general-purpose"` with `model: "sonnet"` and read `${CLAUDE_PLUGIN_ROOT}/agents/gov-copy-writer.md` inline, passing its content verbatim as the first element of the prompt before the context block. The agent still does the work — only the dispatch transport changes.  <!-- # precondition-emit-ok: transport-layer dispatch fallback, not graceful degradation -->

#### Coordination-Pass Dispatch (second-pass gov-copy-writer)

When the current batch contains a **coordination-pass child task** (a task whose title contains "coordination-pass" or which carries the tag `copy:coordination-pass`) **and** the first-pass artifact already exists at `ARTIFACT_PATH`, dispatch gov-copy-writer a **second time** with the full first-pass rationale as input.

**Step 1 — Verify the first-pass artifact exists, then snapshot it**:

```bash
if [[ ! -f "$ARTIFACT_PATH" ]]; then
    echo "HALT: coordination-pass task cannot run — first-pass artifact not found at $ARTIFACT_PATH" >&2
    exit 1
fi
SNAPSHOT_PATH=$(mktemp /tmp/gov-copy-writer-first-pass-snapshot.XXXXXX.yaml)
cp "$ARTIFACT_PATH" "$SNAPSHOT_PATH"
```

The existence check comes BEFORE the `cp` so the HALT message fires when expected. With `set -e`, a `cp` of a missing source would fail first and bypass the diagnostic. The snapshot is a stable, read-only input for the second pass — it isolates the coordination-pass agent from any concurrent writes to `ARTIFACT_PATH`.

**Step 2 — Dispatch gov-copy-writer in second-pass (coordination-pass) mode**:

Inject `{first_pass_rationale_path}` alongside the usual inputs:

```
subagent_type: "dso:gov-copy-writer"
model: "sonnet"
context:
  copy_needs_section: |
    <## Copy Needs section from the epic ticket>
  epic_context: |
    <epic title, description, user archetypes, design notes>
  artifact_path: |
    <resolved ARTIFACT_PATH — same path as first pass; coordination pass overwrites in place>
  first_pass_rationale_path: |
    <SNAPSHOT_PATH — stable snapshot of first-pass artifact; read-only>
  design_context: |
    <design notes if epic has design:approved tag, else empty>
```

**Dispatch-target fallback** (only on "Unknown agent type" error): if `dso:gov-copy-writer` is not registered, fall back to `subagent_type: "general-purpose"` with `model: "sonnet"`, and read `${CLAUDE_PLUGIN_ROOT}/agents/gov-copy-writer.md` inline, passing its content verbatim as the first element of the prompt before the context block. The agent detects second-pass mode by the presence of `{first_pass_rationale_path}`.  <!-- # precondition-emit-ok: transport-layer dispatch fallback, not graceful degradation -->

**Important**: Launch ALL sub-agents in the batch within a single message, each with `run_in_background: true`. The number of Task calls is governed by `max_agents` from Phase C Step 1 (unlimited = all candidates, N = cap at N, 0 = skip dispatch).

**Stale HEAD warning (4ad5-25df)**: When `ISOLATION_ENABLED=true`, all agent worktrees are branched from the session HEAD at the moment of dispatch. Agents that complete later will be missing commits from agents that were harvested earlier in the same batch. This is expected and handled by the conflict queue protocol in `per-worktree-review-commit.md` Step 6: if `harvest-worktree.sh` returns exit 1 (merge conflict), the conflicting worktree is queued for post-batch resolution (rebase first, full re-implementation only as a last resort). Do NOT attempt to resolve conflicts during the serial harvest loop — finish all non-conflicting harvests first, then work through the conflict queue.

**Worktree boundary**: When `ISOLATION_ENABLED=true`, add `isolation: "worktree"` to the Task dispatch call (see Worktree Isolation Configuration above). Do NOT append a pre-evaluated `$(git rev-parse --show-toplevel)` path to the sub-agent prompt — the orchestrator's `git rev-parse` resolves to the SESSION worktree, directing the sub-agent to write there instead of its own isolated worktree (bug 6b67-2aad). The sub-agent's `task-execution.md` CWD lock section already instructs it to derive paths from its own `git rev-parse --show-toplevel`. When `ISOLATION_ENABLED=false`, append: `"IMPORTANT: Only modify files under $(git rev-parse --show-toplevel). Do NOT write to any other path."`

**Prompt path hygiene (bug 1053-4ec3)**: The orchestrator MUST NOT include absolute session-worktree paths in sub-agent prompts. When agents receive absolute paths (e.g., from ticket-show output, file-impact tables, or inline instructions), they use those paths in Read/Edit/Write tool calls — directing changes to the session worktree instead of their isolated worktree. The isolated worktree then has no changes, and the platform correctly auto-cleans it, losing all work. To prevent this:
- Use **relative paths only** in sub-agent prompts (e.g., `scripts/design-md-lint.sh`, not the absolute path)
- When passing ticket context, strip or omit absolute path prefixes
- Include this instruction in every dispatch prompt: `"Derive ALL file paths from $(git rev-parse --show-toplevel) in your own CWD. NEVER use absolute paths from system context or prompt text."`
- The sub-agent's task-execution.md Step 8b stages all changes (`git add -A`) before reporting, which triggers the platform's worktree-retention signal as a defense-in-depth measure

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
| `recipe:` | Execute via `recipe-executor.sh` directly — no sub-agent dispatch. See **recipe: execution flow** below. |
| absent / empty | Default to RED behavior (backward compatibility — tasks created before this field was introduced) |

**GREEN mode**: Pass the following instruction to the sub-agent's Step 4 in `task-execution.md`: skip writing new tests; after implementation, validate that existing tests still pass.

**UPDATE mode**: Pass the following instruction to the sub-agent's Step 4 in `task-execution.md`: modify the existing test file(s) listed in the file impact table to assert the new expected behavior before implementing the source change. The test must fail (RED) on the current code before the fix.

**recipe: execution flow**: When `TESTING_MODE` starts with `recipe:`, the orchestrator executes the recipe directly — no Task sub-agent is dispatched and no story branch is created.

**Pre-execution engine check (missing-engine fallback)**: Before executing the recipe, check whether the recipe's engine appears in `MISSING_ENGINES_LIST` (stored in session context from Phase C Step 1 recipe: pre-flight output). To check: look up the recipe's `engine` field from the registry for this recipe name; if that engine name appears in `MISSING_ENGINES_LIST`, route to LLM fallback:

1. Look up `capability_description` and `engine` from the registry for this recipe name.
2. Call `bash "$PLUGIN_SCRIPTS/sprint/translate-recipe-to-llm-task.sh" --recipe=<recipe_name> --intent="<capability_description>" [--param key=value ...] --output-format=task-prompt` to produce an LLM task description. Capture as `LLM_TASK_PROMPT`. # shim-exempt: internal orchestration script
3. Dispatch a normal LLM sub-agent with `LLM_TASK_PROMPT` as the task description (same GREEN dispatch flow — create story branch, dispatch sub-agent with isolation: "worktree", process via Phase F per-worktree-review-commit.md).
4. Record a ticket comment on the recipe task: `.claude/scripts/dso ticket comment <task_id> "RECIPE_FALLBACK: recipe=<recipe_name> engine=<engine_name> reason=engine_not_installed — executing via LLM sub-agent"`
5. Fallback LLM task proceeds through normal Phase F (review, commit, verify) — identical downstream structure to any GREEN task.
6. Count the fallback sub-agent dispatch toward the `max_agents` cap.
7. Skip steps 1–6 of the normal recipe execution flow below.

**When `MISSING_ENGINES_LIST` is empty, not set, or the recipe's engine does not appear in it**: proceed with the normal recipe execution flow (steps 1–6 below).

1. **Parse task description** for:
   - `recipe_name` — the recipe identifier (e.g. `sync-jira-labels`)
   - `recipe_params` — zero or more `key=value` pairs
   - `intent` — human-readable description of what the recipe does (used in sprint log)

2. **Execute the recipe**:
   ```bash
   bash "$PLUGIN_SCRIPTS/recipe-executor.sh" <recipe_name> [--param key=value ...]  # shim-exempt: internal orchestration script
   ```
   Capture stdout as `EXECUTOR_JSON`. On bash-level failure (non-zero exit before JSON is emitted) or empty output, synthesize:
   ```json
   {"exit_code": 1, "errors": ["recipe-executor.sh failed or produced no output"], "engine_name": "<recipe_name>", "degraded": false}
   ```

3. **Format the result**:
   ```bash
   bash "$PLUGIN_SCRIPTS/sprint/format-recipe-result.sh" <recipe_name> <<< "$EXECUTOR_JSON"  # shim-exempt: internal orchestration script
   ```
   Capture stdout as `RECIPE_SUMMARY`.

4. **Record in sprint log**: Log `RECIPE_RESULT: <task_id> — <intent> — <RECIPE_SUMMARY>` as the task result.

5. **On non-zero `exit_code` in JSON**: Mark the task failed in the sprint log with the error summary; continue the batch — do not crash the sprint or halt further task dispatch.

6. **On `degraded=true` in JSON**: Log a degraded warning: `RECIPE_DEGRADED: <task_id> — engine: <engine_name> — <RECIPE_SUMMARY>` with a note that fallback behavior was used. Continue the batch.

**Note**: `recipe:` tasks do NOT create a story branch. They are direct orchestrator-executed actions with no sub-branch worktree.

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
  - `TEST_RESULT:rejected` → Escalate to Tier 2. This is **not** a dispatch failure — do not route to Phase F Step 1.
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

## Phase F: Post-Batch Processing (/dso:sprint)

After ALL sub-agents in the batch return, follow the Orchestrator Checkpoint Protocol from CLAUDE.md.

### Worktree Isolation Mode: Per-Worktree Serial Review and Commit

**When sub-agents returned with `isolation:worktree`** (isolation is always enabled), do NOT proceed to the shared-directory batch review flow (Step 13). Instead, process each worktree **serially** using the per-worktree protocol:

Read and execute `skills/sprint/prompts/per-worktree-review-commit.md` for each worktree, in completion order (first-pass-first-merge). This means: for each worktree — run review in the worktree context, commit to the worktree branch, merge the worktree branch into the session branch, then remove the worktree and its branch (per-worktree-review-commit.md Step 7) — before moving to the next worktree.

**Git log note**: In worktree isolation mode, `git log` on the session branch shows one commit per worktree (no combined batch commits). Each worktree's changes are merged independently into the session branch.

**merge-to-main.sh note**: `merge-to-main.sh` runs **once** at session end (Phase I), not per worktree. Each per-worktree merge is worktree-branch → session-branch only.

**Worktree-isolation execution order (the default).** After all sub-agents in the batch return, execute Phase F in this order:

1. **Steps 1–6** — sub-agent result processing (dispatch-failure recovery, verify results, migration behavioral verification, confidence-signal parsing, integrate discovered tasks, collect discoveries). These operate on the Task return values and are mode-independent.
2. **Per-worktree serial loop** — process each worktree via `per-worktree-review-commit.md`. This loop IS the worktree-mode realization of Step 13 (formal code review) and Step 17 (commit & push); both standalone steps are therefore **skipped**. The loop also runs cleanup-recipes (Step 3.7) and the out-of-scope scope-check per worktree (see that prompt).
3. **Batch/integration gates on the harvested session branch, in order**: Step 7 (acceptance-criteria validation), Step 8 (file-overlap safety net), Step 9 (semantic-conflict check), Step 10 (validate-phase post-batch), Step 11 (persistence coverage), Step 11a (design-md lint), Step 12 (visual verification), Step 12a (visual evaluator post-batch).
4. **Step 14** (out-of-scope review feedback — reads the `batch_out_of_scope_findings` accumulator the per-worktree loop populated), **Step 15** (update ticket notes), **Step 16** (handle failures).
5. **Step 18** (Close Completed Tasks — contains the `dso:completion-verifier` dispatch and the planner-dispatch HARD-GATE; **MANDATORY — never skipped in worktree mode**), then **Step 19** (context-compaction check), **Step 20** (continuation decision).

Skip ONLY the two standalone steps realized inside the per-worktree loop: **Step 13** (review) and **Step 17** (commit & push). Every other Phase F step runs.

**Shared-directory mode (legacy — isolation disabled, unreachable while worktree isolation is always enabled per "Worktree Isolation Configuration"):** Steps 13 and 17 would run inline below and the per-worktree loop would be skipped. Retained for reference; not exercised in current operation.

### Cross-Layer File Visibility Invariant (bug 38b4-e9f6) (/dso:sprint)

In worktree-isolation mode (the default), the file-visibility contract for Layer N+1 sub-agents is provided by **Phase F Step 5 (per-task harvest into session branch)** — NOT by the story-branch merge in Step 18. Each `worktree-agent-<task-id>` branch is merged into the session branch by `harvest-worktree.sh` (see `per-worktree-review-commit.md` Step 5) as soon as its individual review+commit+harvest cycle completes. This advances SESSION_HEAD to include the task's file artifacts BEFORE the parent story closes.

**Invariant**: by the time `/dso:sprint` dispatches a Layer N+1 batch (Phase C → Phase E), SESSION_HEAD contains every harvested task commit from every Layer 0..N story whose tasks have completed Phase F Step 5. Sub-agents call `worktree-session-head-sync.sh` on this SESSION_HEAD on startup (per `skills/shared/prompts/worktree-dispatch.md` Step 2), so they see all prerequisite files from sibling-layer stories.

**ci-pr mode mechanism**: in `dso.workflow=ci-pr`, harvest-worktree.sh's session-branch merge is realized as a per-task GitHub PR (`gh pr create --base $SESSION_BRANCH --head worktree-agent-<task-id>`). Each PR merges into the session branch as it lands. There are NO per-story PRs in worktree-isolation mode; the story branch created at Phase E is a **logical container** for ticket-tracking attribution, not a data-flow waypoint.

**Phase F Step 18 story-branch merge in worktree-isolation mode**: the story branch's tip equals the session-branch tip at the moment Step 18 runs, because all of the story's tasks already harvested into the session branch via Step 5. The `merge-to-main.sh BRANCH=$STORY_BRANCH STORY_PR_BASE=$SESSION_BRANCH` call in Step 18 therefore creates a no-diff merge — handled by `merge-to-main.sh`'s internal no-diff detection. This is intentional — Step 18's contract (P1 verdict + story-closure trailer attribution + GitHub PR record) is preserved while the actual file movement happens in Step 5.

**What this rules out**: the failure mode where Layer N+1 sub-agents start from a SESSION_HEAD that does not contain Layer N's file artifacts. That failure mode presupposes story-branches accumulating without ever merging to the session — which is the shared-directory-mode mental model, not the worktree-isolation-mode reality. In worktree-isolation mode (default), per-task harvest is the canonical, mechanically-realized file-visibility path.

### Step 1: Dispatch Failure Recovery (/dso:sprint)

Check whether any sub-agent Task call returned an **infrastructure-level dispatch failure** (no `STATUS:` line, no `FILES_MODIFIED:` line, error message references agent type/tool availability/internal errors).

**RED test task exception**: If the failed task's `subagent` field was `dso:red-test-writer`, do NOT fall back to `general-purpose`. A `TEST_RESULT:rejected` response triggers the three-tier escalation protocol (Phase E RED Task Dispatch). Only true dispatch failures (no `TEST_RESULT:` line, no `STATUS:` line, tool-level error indicators) qualify for the recovery flow below.

**For each sub-agent that returned a dispatch failure:**

1. **Detect**: The Task result contains no `STATUS:` or `FILES_MODIFIED:` lines AND includes error indicators (e.g., "unknown subagent_type", "agent unavailable", "internal error", "Tool result missing")
2. **Retry with general-purpose**: Re-dispatch the same task immediately using `subagent_type="general-purpose"` with the same model and prompt. Log: `"Dispatch failure for task <id> with subagent_type=<original-type> — retrying with general-purpose."`
3. **If retry succeeds**: Continue to Step 2 with the retry result
4. **If retry also fails**: Escalate model (sonnet → opus) and retry once more with `subagent_type="general-purpose"`. Log: `"Retry with general-purpose also failed for task <id> — escalating model to opus."`
5. **If all retries fail**: Mark the task as failed and proceed to Step 16

**Important**: Dispatch failure retries happen sequentially. Do not count retries toward the `max_agents` cap.

### Step 2: Verify Results (/dso:sprint)

For each sub-agent (including any that succeeded on retry), check the Task tool result:
- Did it report success?
- Are the expected files present? (spot-check with Glob)
- Were tests passing?

### Step 3: Migration Behavioral Verification (/dso:sprint)

For each sub-agent in the batch, check if its task description contains migration keywords (`remove`, `delete`, `migrate`, `move`, `replace`). For migration tasks:

1. **Verify the replacement exists**: Run the first task-specific AC `Verify:` command. If it fails, mark the task as failed.
2. **Behavioral smoke test**: If the task migrates a command/skill/script, invoke or test the migrated artifact. Log: `"Migration behavioral check for <task-id>: <pass|fail>"`

### Step 4: Confidence Signal Parsing (/dso:sprint)

For each sub-agent result, scan for the confidence signal line (see `docs/contracts/confidence-signal.md`): # shim-exempt: internal contract reference

1. **Parse the confidence signal**: Scan the sub-agent output for a line that is exactly `CONFIDENT` or begins with `UNCERTAIN:`.
   - `CONFIDENT` — high confidence; no action needed beyond normal processing.
   - `UNCERTAIN:<reason>` — low confidence; proceed to steps below.
   - **Absent or malformed signal** (no confidence line, bare `UNCERTAIN` with no colon, `UNCERTAIN:` with empty reason) — treat as `UNCERTAIN` with reason `"no confidence signal emitted"`. Log a warning: `"Warning: task <task-id> emitted no valid confidence signal — treating as UNCERTAIN."`

2. **Only count `STATUS:pass` + `UNCERTAIN` signals toward the threshold.** `STATUS:fail` tasks already trigger revert-to-open in Step 16 through the normal failure path — the UNCERTAIN signal on a failing task does not change routing.

3. **For each task where `STATUS:pass` + `UNCERTAIN`:**
   a. Identify the parent story ID from the task's `story:<id>` field in the TASK line (from Phase E batch list).
   b. Record the signal: `.claude/scripts/dso ticket comment <story-id> "UNCERTAIN_SIGNAL: task <task-id> — <reason>"`
   c. Increment the per-story counter: `story_uncertain_counts[<story-id>] += 1` (initialize to 0 if not yet set).
   d. Log: `"UNCERTAIN signal from task <task-id> under story <story-id> — count now <N>."`

### Step 5: Integrate Discovered Tasks (/dso:sprint)

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

### Step 6: Collect Agent Discoveries (/dso:sprint)

Collect structured discovery files from sub-agent execution (propagated to next batch via `{prior_batch_discoveries}` in Phase C Step 10).

```bash
DISCOVERIES=$(.claude/scripts/dso collect-discoveries.sh 2>/dev/null) || DISCOVERIES="[]"
```

- If `collect-discoveries.sh` succeeds, `DISCOVERIES` contains a JSON array of discovery objects
- Store the result for use in Phase C Step 10 when composing the next batch's sub-agent prompts
- **Graceful degradation**: If discovery collection fails (script error, malformed JSON), log a
  warning and continue with `DISCOVERIES="[]"`. Discovery collection failure must not block the
  sprint. The script itself handles per-file validation — malformed individual files are skipped
  with warnings to stderr.

### Cleanup Recipe Phase (Post-Agent, Pre-Review)

**Worktree-isolation mode (default):** cleanup recipes run **per-worktree** inside `per-worktree-review-commit.md` (Step 3.7), where the sub-agent's `git add -A` has populated the worktree's `git diff --staged`. This orchestrator-body copy operates on the **session** worktree's staged set, which is empty in worktree-isolation mode (changes arrive via harvest commits, not staging) — so in the default mode it is a no-op and is **skipped**. The block below is the shared-directory-mode (legacy) location.

After collecting agent discoveries (Step 6) and before acceptance criteria validation (Step 7), detect and apply applicable cleanup recipes to the staged output.

```bash
RECIPE_REGISTRY_PATH="${CLAUDE_PLUGIN_ROOT}/recipes/recipe-registry.yaml"
CLEANUP_RECIPES="$(RECIPE_REGISTRY_PATH="$RECIPE_REGISTRY_PATH" bash "$PLUGIN_SCRIPTS/sprint/detect-cleanup-recipes.sh" 2>/dev/null || true)"  # shim-exempt: internal orchestration script
```

**No-op handling**: If `detect-cleanup-recipes.sh` produces no output (no applicable recipes), skip the cleanup phase entirely — no log entry.

For each applicable recipe in `CLEANUP_RECIPES`:

1. Capture a pre-cleanup snapshot for conflict detection:
   ```bash
   PRE_CLEANUP_DIFF="$(git diff --staged)"
   ```

2. Run the recipe executor:
   ```bash
   bash "$PLUGIN_SCRIPTS/recipe-executor.sh" <recipe_name> --param language=<lang>  # shim-exempt: internal orchestration script
   ```

3. **Conflict detection**: After execution, compare the new staged diff to `PRE_CLEANUP_DIFF`. If the recipe reverted sub-agent staged changes, log a WARNING and skip that recipe for those files:
   ```
   WARNING: Cleanup recipe '<name>' reverted staged changes in <file> — skipping for that file
   ```

4. **Log cleanup diff as distinct ticket comment**: Record post-cleanup state as a distinct ticket comment (NOT merged with the sub-agent diff), so completion-verifier and reviewers see the accurate post-cleanup diff:
   ```bash
   .claude/scripts/dso ticket comment <task-id> "CLEANUP_DIFF: $(git diff --staged)"
   ```

Sprint log records post-cleanup state (not pre-cleanup state), ensuring reviewers see clean code after mechanical cleanup.

### Step 7: Acceptance Criteria Validation (/dso:sprint)

**Batched shared criteria** (run ONCE per batch, not per-task):
Universal criteria (test, lint, format) are already verified by Phase F Step 17
(validate-phase.sh post-batch). Do not re-run per task.

**Per-task structural criteria**:
For each task in the batch, extract the `Acceptance Criteria` block from `.claude/scripts/dso ticket show <id>` output
and run each task-specific (non-universal) `Verify:` command:

1. File existence: `test -f {file}` — exit 0 = pass
2. Class importable: `python -c "from {module} import {class}"` — exit 0 = pass
3. Test count: `grep -c "def test_" {file}` — compare to threshold
4. Grep-verifiable: run the grep pattern — exit 0 = pass

Criteria without a `Verify:` command are logged but not machine-verified —
caught by the formal code review (Step 13).

If any machine-verifiable criterion fails:
- Log the failed criterion and its `Verify:` output
- Mark the task as failed in Step 16 (revert to open)
- Include the failed criterion text in the re-dispatch prompt

### Batch Completion Summary

Print a completion summary. Each line must show the task ID, title, and pass/fail result:

```
✓ [dso-abc1] Task title (pass)
✗ [dso-abc2] Other task (fail — reverted to open)
```

Titles are retained from the pre-launch batch list printed in Phase E — no additional `.claude/scripts/dso ticket show` calls are needed.

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

These stories are excluded from Phase B implementation-plan dispatch and Phase E sub-agent dispatch. They are surfaced here to give the user visibility into what is blocked on design. No action is required from the orchestrator — the sprint continues with non-blocked stories.

### Step 8: File Overlap Check (Safety Net) (/dso:sprint)

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
3. If conflicts are detected, resolution (same protocol as `/dso:debug-everything` Phase H Step 10):
   a. Identify the primary agent for each conflicting file (highest priority)
   b. Revert ALL secondary agents' changes to conflicting files
   c. Re-run secondary agents one at a time in priority order (not parallel),
      each with original prompt + Conflict Resolution Context (captured diff,
      instruction to respect current file state). Commit after each re-run.
   d. After each re-run: if agent only touched non-conflicting files -> merge OK.
      If it re-modified the same conflicting files -> escalate to user.
4. If no conflicts -> proceed to Step 10

### Step 9: Semantic Conflict Check (/dso:sprint)

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

### Step 10: Run Validation (/dso:sprint)

```bash
$PLUGIN_SCRIPTS/validate-phase.sh post-batch  # shim-exempt: internal orchestration script
```

If validation fails, identify which sub-agent's code is broken and note it.

#### Test Failure Sub-Agent Delegation (Phase F Step 17)

When `validate-phase.sh post-batch` fails, dispatch a debugging sub-agent BEFORE reverting tasks to open. Follow `prompts/test-failure-dispatch-protocol.md` with these caller-specific fields:
- `test_command`: the `validate-phase.sh post-batch` command that failed
- `changed_files`: files modified by the batch (`git diff --name-only`)
- `task_id`: the task ID of the sub-agent that likely caused the failure
- `context`: `sprint-post-batch`
- `batch_task_ids`: IDs of all tasks in the current batch

On `PASS`: re-run `validate-phase.sh post-batch` to confirm, then continue to Step 11.

### Step 11: Persistence Coverage Check (/dso:sprint)

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

### Step 11a: Design-MD Lint Gate (/dso:sprint)

Filter the batch's touched files for scope-eligible extensions. This list MUST match `per-worktree-review-commit.md` Step 3.6 to ensure consistent enforcement across shared-directory and worktree-isolation modes:

```bash
TOUCHED_FILES=$(git diff --name-only HEAD)
ELIGIBLE_FILES=$(echo "$TOUCHED_FILES" | grep -E '\.(css|scss|tsx|jsx|vue|svelte|html|ejs|erb|pug|hbs|j2|jinja2|twig)$' || true)
```

If `ELIGIBLE_FILES` is non-empty, run the design-md-lint check:

```bash
bash "$PLUGIN_SCRIPTS/design-md-lint.sh" $ELIGIBLE_FILES  # shim-exempt: internal orchestration script
LINT_EXIT=$?
```

If `LINT_EXIT` is non-zero:
1. Log: `"design-md-lint.sh failed — design documentation violations detected in batch files."`
2. **Do not commit.** Block the batch and surface the lint output to the orchestrator.
3. Fix all violations reported by the linter (update or add the required design-doc references in the affected files).
4. Re-run the lint check and proceed only when it exits 0.

If `ELIGIBLE_FILES` is empty, skip this step.

### Step 12: Visual Verification (UI tasks only) (/dso:sprint)

If any task in the batch modified templates, CSS, or frontend code:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cd $REPO_ROOT/app && make test-visual 2>&1
```

- **Pass** → proceed
- **Fail** → Use `/dso:playwright-debug` Tier 2. If still failing, revert task to open.
- **No baselines** → Use `/dso:playwright-debug` full 3-tier. Verify local env: `$PLUGIN_SCRIPTS/check-local-env.sh`.  # shim-exempt: internal orchestration script

### Step 12a: Visual Evaluator Post-Batch — Integration B (/dso:sprint)

Runs when `visual_evaluator.enabled=true` and at least one task in the batch modified UI files. Gated by shared preconditions and token budget. Never blocks the sprint — all failure paths exit 0. <!-- # precondition-emit-ok: preconditions are checked in visual-eval-preconditions.sh, not inline -->

```bash
RESULTS_DIR=$(bash "$PLUGIN_SCRIPTS/sprint/visual-eval-post-batch.sh" $BATCH_FILE_LIST 2>/dev/null) || true  # shim-exempt: internal orchestration script
```

- **`RESULTS_DIR` non-empty** → Feed `$RESULTS_DIR/*.json` to the 5th committee reviewer (visual-spatial-evaluator) per `${CLAUDE_PLUGIN_ROOT}/skills/ui-designer/docs/arbitration.md`. Clean up `$RESULTS_DIR` after consumption.
- **`RESULTS_DIR` empty or exit 0 with no stdout** → Degraded path; proceed to Step 13. Check stderr for `visual_eval_inapplicable:<reason>` annotations.
- **`visual_evaluator.enabled` absent or false** → Script exits 0 immediately via shared preconditions. <!-- # precondition-emit-ok -->

### Step 13: Formal Code Review (/dso:sprint) — Shared-Directory Mode Only

**This step applies only in shared-directory mode (isolation disabled).** When worktree isolation is enabled (default), review is handled per-worktree via `per-worktree-review-commit.md` (see Worktree Isolation Mode section at the top of Phase F). Skip this step in worktree isolation mode.

Execute the review workflow (REVIEW-WORKFLOW.md). If already read earlier in this conversation, use the version in context. Produces a review state file at `$(get_artifacts_dir)/review-status`.

**Do NOT dispatch any `dso:code-reviewer-*` agent directly.** You MUST execute REVIEW-WORKFLOW.md Step 3 first to obtain `REVIEW_TIER` and `REVIEW_AGENT` from the complexity classifier before dispatching. Hardcoding `dso:code-reviewer-light` or any other tier is prohibited — the classifier determines the tier based on diff characteristics.

**Snapshot exclusion**: Exclude snapshot baselines from review diffs:
```bash
".claude/scripts/dso capture-review-diff.sh" "$DIFF_FILE" "$STAT_FILE" \
  ':!app/tests/unit/templates/snapshots/*.html'
```

**Interpret results:**
- **No Critical, Important, or Fragile findings** → proceed to Step 15
- **Critical, Important, or Fragile findings found** → Enter Autonomous Resolution Loop per REVIEW-WORKFLOW.md. No inline fixes by orchestrator. Failed tasks: revert to open, add issue details, re-run with reviewer feedback. **Critical, Important, or Fragile findings are NOT a pass — do NOT suggest graceful shutdown or proceed to commit. Apply the fix or escalate.**
- **Minor issues only** → proceed (note them in ticket but don't block)
- **Autonomous resolution**: Up to `review.max_cycles` (default: 4) fix/defend attempts before tier escalation (light → standard → deep). When attempts are exhausted, upgrade to the next tier before escalating to user — the deep tier (3 sonnet + opus synthesis) must be tried before user escalation. Resolution sub-agent applies fixes, then orchestrator dispatches separate re-review sub-agent (no nesting). If issues persist after deep tier, escalate to the user — do NOT commit or initiate graceful shutdown. The review loop continues until the review passes OR the user explicitly approves proceeding.
- **Stale or invalid review findings**: If the review gate rejects a commit because findings are stale (from a different context, wrong diff hash, or prior session), do NOT work around the gate. Re-run REVIEW-WORKFLOW.md from Step 0 (which clears stale artifacts) to get a fresh review. Never dispatch a generic agent to write `reviewer-findings.json` — this is fabrication regardless of whether the orchestrator writes the file directly or delegates it to a non-reviewer agent.

> **CONTEXT ANCHOR**: When the review sub-agent returns no critical/important/fragile findings (FINDING_COUNT with all minor or 0), this is NOT a session completion signal. Proceed immediately to Step 14 → Step 15 → Step 16 → Step 17. Do NOT stop, wait for user input, or treat review completion as a stopping point.

### Step 14: Out-of-Scope Review Feedback Detection (/dso:sprint)

**Worktree-isolation mode (default):** this scope-check runs **per-worktree** inside `per-worktree-review-commit.md` (post-review), where `$WORKTREE_ARTIFACTS/reviewer-findings.json` exists and `deps.sh`/`get_artifacts_dir` is sourced. It appends to `batch_out_of_scope_findings` there (append-only; no implementation-plan routing mid-batch). In that mode the `batch_out_of_scope_findings` accumulator is already populated by the time this step is reached — skip this orchestrator-body check. The steps below are the shared-directory-mode (legacy) path; note `$(get_artifacts_dir)` requires `deps.sh` to be sourced, which the orchestrator does NOT do — so the legacy body is reachable only in shared-directory mode.

After review resolution completes (Step 13) and before proceeding to Step 15, check whether accepted review findings reference files outside the task's scope.


For each task in the batch that completed review:

1. Run `sprint-review-scope-check.sh` with the reviewer-findings path and task ID:
   ```bash
   SCOPE_RESULT=$(.claude/scripts/dso sprint/sprint-review-scope-check.sh "$(get_artifacts_dir)/reviewer-findings.json" "<task-id>")  # shim-exempt: internal orchestration script
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
   d. **DO NOT route to implementation-plan here.** Out-of-scope findings are collected during the batch and processed only between batches (Step 20) to avoid mid-batch task injection conflicts.
3. If `IN_SCOPE` → no action needed; proceed normally.
4. If the script fails (non-zero exit) → log a warning and continue. Scope checking failure must not block the sprint.

### Step 15: Update Ticket Notes (/dso:sprint)

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

### Step 16: Handle Failures (/dso:sprint)

For tasks that failed:
- Revert to open: `.claude/scripts/dso ticket transition <id> open`
- Record the failure reason in notes (already done in Step 15)

### Step 17: Commit & Push (/dso:sprint) — Shared-Directory Mode Only

**This step applies only in shared-directory mode (isolation disabled).** When worktree isolation is enabled (default), commits are made per-worktree via `per-worktree-review-commit.md` (see Worktree Isolation Mode section at the top of Phase F). Skip this step in worktree isolation mode.

The `.sprint-active` marker file at the repo root signals sprint context to pre-commit hooks (e.g., `check-sprint-trailer.sh`) — no environment variable export is needed.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md`.

**SIZE_WARNING path**: When SIZE_ACTION=warn, log the SIZE_WARNING to the user and continue with review dispatch. Do NOT halt, split, or escalate based on warn alone.

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
Do NOT proceed to Step 19 until Step 18 (completion-verifier dispatch) has completed and Gate 1 (`check-verifier-verdict.sh`) has returned a verdict (`P1` field populated). The orchestrator is biased toward confirming its own work — CLAUDE.md `rule:dispatch-verifier` exists because this step has been skipped in past sessions. "All tests pass" and "all tasks closed" do NOT substitute for independent verification.

Do NOT rationalize skipping Step 18. Prior evidence ("RED tests are GREEN", "CI passes", "AC verified") does not satisfy the completion-verifier requirement. The verifier checks done-definitions that task-level AC verification does not cover.

Do NOT fabricate artifacts to satisfy done definitions or closure checks (bug cc4d-85c5). "Test alert triggered and received" means the GHA workflow fires and produces the artifact — NOT that the orchestrator creates the artifact by hand via `gh issue create`, `gh api`, or any other manual construction. Satisfying a DD requires the ACTUAL SYSTEM to produce the expected output. Constructing the expected output yourself is fabrication, regardless of framing ("simulating the logic directly", "verifying it fires by creating the output").

Do NOT use the `/dso:commit` Skill tool here — read and execute COMMIT-WORKFLOW.md inline to avoid nested skill invocations that may not return control.
</HARD-GATE>

After `git push -u origin HEAD` and blackboard cleanup are done, proceed to **Step 18** then Step 19 then Step 20. Do NOT close the epic or invoke `/dso:end-session` here.

> **CONTINUE:** After commit and push, proceed immediately to Step 18. Do NOT stop, wait for user input, or initiate graceful shutdown here.

### Step 18: Close Completed Tasks (/dso:sprint)

After the batch commit and `git push -u origin HEAD` succeed, close each task whose code was successfully committed:

**Unacked-degradation pre-check (Step 18 prerequisite):**
Before verifying open children, check whether any PRECONDITIONS degradation entries are unacknowledged for this story:

```bash
bash "$PLUGIN_SCRIPTS/check-unacked-degradations.sh" <story-id>  # shim-exempt: internal orchestration script
```

- If exit 0: no unacked degradation entries — continue to the OPEN_CHILDREN check below.
- If exit 1: the script prints each unacked decision_id on a separate line. Do NOT dispatch dso:completion-verifier.

**When check-unacked-degradations.sh exits 1:**

1. Parse the output lines (each line is one unacked decision_id, e.g., `sess:abc123`)
2. Present to the user:
   > "Story <story_id> has N unacked degradation(s):
   > - <decision_id_1>: <gate_name> — <condition_text_snippet>
   > - <decision_id_2>: ...
   > 
   > To proceed, acknowledge each degradation using:
   >   `.claude/scripts/dso preconditions-ack <story_id> <decision_id> --if-skipped \"<your rationale>\"`
   > 
   > Or acknowledge a full class (>=4 entries) using:
   >   `.claude/scripts/dso preconditions-ack <story_id> --sample-ack --class=<class> --if-skipped \"<rationale>\"`
   > 
   > Options: (a) I have acknowledged — re-check, (b) Skip story closure (leave open), (c) Force close anyway"
3. Wait for user response:
   - (a) Re-check: re-run check-unacked-degradations.sh; if clean → proceed to OPEN_CHILDREN check; if still fails → show prompt again (max 3 re-check cycles)
   - (b) Skip: log STORY_CLOSURE_DEFERRED:<story_id>; do not close story; continue to next story
   - (c) Force: log STORY_CLOSURE_FORCED:<story_id> REASON:user_override; proceed to OPEN_CHILDREN check

Note (ordering): this check runs BEFORE dso:completion-verifier dispatch — stories with unreviewed graceful-degradation fallthroughs must not consume opus verification calls.
Note (fail-open): if check-unacked-degradations.sh exits with an unexpected non-1 error code, log the failure to stderr and treat the check as clean (proceed to OPEN_CHILDREN check). Fail-open prevents the check from becoming a deployment blocker on unrelated infrastructure errors.
Note (dso-94ya boundary): see ticket dso-94ya in the ticket system. If the dso-94ya preflight harness ships first and integrates this check, replace this standalone bash call with the harness invocation. Ship standalone for now; dso-94ya integrates on landing.

**Pre-dispatch child closure check (Step 18 prerequisite):**
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
- Add a comment: `.claude/scripts/dso ticket comment <story-id> "Step 18 blocked: <N> child tasks still open: <list IDs>. Complete them before closure."`
- Resume Phase C to close the remaining tasks

Only when OPEN_CHILDREN == 0, proceed to the pre-verifier execution step below.

**Pre-verifier execution (Step 18 prerequisite — intent-fidelity-pipeline Phase 1):**

<HARD-GATE>
Before dispatching dso:completion-verifier, run the pre-verifier execution script.
This is NOT optional. "All tests pass" and "all tasks closed" do not substitute
for DD-level verification. The script executes each DD's Verify command and
produces a structured execution trace.

```bash
VERIFY_TRACE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/pre-verifier-execute.sh" <story-id>)  # shim-exempt: sub-agent instruction block
```

Pass `VERIFY_TRACE_PATH=$VERIFY_TRACE` in the completion-verifier prompt.

If VERIFY_TRACE is empty or the script exits non-zero, log the error and pass
`VERIFY_TRACE_PATH=""` to the verifier (backward-compat path). Do NOT skip the
verifier dispatch because the trace script failed.

**Simplified remediation for clear errors (intent-fidelity-pipeline Phase 4):**

After `pre-verifier-execute.sh` produces the trace and BEFORE dispatching the completion-verifier, check the trace for FAIL outcomes with clear-error patterns. If found, attempt a direct fix to avoid the full planner dispatch chain.

Read the trace file at `$VERIFY_TRACE`. For each result with `outcome: FAIL`, check whether `stderr_tail` matches any of these exact patterns:
- `NotImplementedError` or `raise NotImplementedError`
- `# stub` or `# TODO`
- `pass  # placeholder`
- `AttributeError: module .* has no attribute`
- `ImportError: cannot import name`

If a match is found AND this is the first simplified remediation for this story (check ticket comments for prior `SIMPLIFIED_REMEDIATION:` entries):
1. Dispatch a single fix sub-agent with the failing DD description and AC as context. Do NOT pass the Verify command's expected output.
2. After the fix sub-agent returns, re-run `pre-verifier-execute.sh` for ALL DDs.
3. If ALL DDs now PASS → update `$VERIFY_TRACE` with the new trace and proceed to verifier dispatch.
4. If ANY DD still fails → abandon this path, proceed to verifier dispatch with the original trace (the verifier + planner will handle it).
5. Record: `.claude/scripts/dso ticket comment <story-id> "SIMPLIFIED_REMEDIATION: clear error (<pattern>) — dispatched direct fix sub-agent"`

If no clear-error match or this is not the first remediation attempt → skip this block and proceed to verifier dispatch.
</HARD-GATE>

**Manual story sentinel path (Step 18)**: When the story has the `manual:awaiting_user` tag, `dso:completion-verifier` reads the `MANUAL_PAUSE_SENTINEL` comment written by `sprint-manual-drain.sh` to determine the verdict (see `completion-verifier.md` Step 9). The orchestrator takes no special action — dispatch the verifier normally and let it apply the sentinel verdict rules automatically.

<HARD-GATE>
Do NOT close this story, do NOT transition it to closed, and do NOT proceed to Step 19 until dso:completion-verifier has been dispatched via Task tool and its verdict received. This gate applies regardless of whether:
- All RED tests are GREEN
- All child tasks are closed
- CI passes
- The orchestrator believes the story is complete

"All tests pass" is not a substitute for the completion-verifier dispatch. Dispatch the verifier NOW before reading any further.
</HARD-GATE>

**MANDATORY (3f26-4c70 gate)**: First confirm OPEN_CHILDREN == 0 from the check above. If OPEN_CHILDREN > 0 at this point, STOP — do NOT dispatch the verifier; follow the blocked path above instead. Only when OPEN_CHILDREN is confirmed 0, dispatch the verifier exactly as specified below.

<HARD-GATE>
**Verifier dispatch shape — DO NOT DEVIATE (bug c716-952a)**

The Agent tool call MUST use the named agent type. Hand-written prompts that paraphrase the agent file — even prompts starting "You are the dso:completion-verifier agent..." — are fabrication and violate CLAUDE.md `rule:dispatch-verifier`. The named-agent dispatch loads the canonical rubric, schema, and verification questions; an inline prompt cannot reproduce them faithfully and skips the structural output contract.

The ONLY two valid dispatch forms are:

1. **Primary form** — named subagent_type (use this unless it errors):
   ```
   Agent({
     description: "Verify story <story-id> completion",
     subagent_type: "dso:completion-verifier",
     model: "sonnet",
     prompt: "<story-id>\nVERIFY_TRACE_PATH=$VERIFY_TRACE\n+ any additional context the verifier needs"
   })
   ```

2. **Fallback form** — only when subagent_type "dso:completion-verifier" returns an "Unknown agent" / dispatch error in this exact session. Read `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md` verbatim with the Read tool and pass the ENTIRE file contents as the first element of the prompt under subagent_type "general-purpose". The agent file is plugin-shipped at `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md` — use that absolute resolution; a bare `agents/completion-verifier.md` relative path will not resolve correctly from a host-project worktree (false-positive review finding observed on PR #182 due to this ambiguity).
   ```
   Agent({
     description: "Verify story <story-id> completion (fallback)",
     subagent_type: "general-purpose",
     model: "sonnet",
     prompt: "<verbatim contents of ${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md>\n\n---\n\nStory ID: <story-id>\nVERIFY_TRACE_PATH=$VERIFY_TRACE"
   })
   ```

What is NOT acceptable (all of these are CLAUDE.md `rule:dispatch-verifier` violations):
- Hand-written check lists or ad-hoc rubrics in the prompt
- Prompts that reference the agent file by name without loading its contents
- Prompts that summarize the agent file's instructions in your own words
- Dispatching `subagent_type: "general-purpose"` with anything other than the verbatim agent file as a fallback for a named-type failure

If neither form is achievable (e.g., Agent tool unavailable), STOP and surface to the user — do not synthesize a verifier prompt yourself.
</HARD-GATE>
- `P1: PASS` → compute verdict hash and proceed with closure:
  ```bash
  VERDICT_HASH=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/compute-verdict-hash.sh" <story-id> PASS)  # shim-exempt: sub-agent instruction block
  ```
  Pass `--verdict-hash=$VERDICT_HASH` to the `ticket transition ... closed` command.
- `P1: EVIDENCE_PENDING` → see **EVIDENCE_PENDING escalation protocol** below.
- `P1: FAIL` / `P1: BLOCKED` / `P1: INCONCLUSIVE` → see **Planner-dispatch HARD-GATE** below; do NOT create any ticket until the planner returns.
- **Fallback (technical failure only)**: On timeout/unparseable JSON (`check-verifier-verdict.sh` exit 2), log warning and proceed with closure.

**EVIDENCE_PENDING escalation protocol (intent-fidelity-pipeline Phase 1):**

When the verifier returns `P1: EVIDENCE_PENDING`:

1. Re-run `pre-verifier-execute.sh` once (transient timeout may have resolved):
   ```bash
   VERIFY_TRACE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/pre-verifier-execute.sh" <story-id>)  # shim-exempt: sub-agent instruction block
   ```
2. Re-dispatch the completion-verifier with the new trace.
3. If `P1` is still `EVIDENCE_PENDING` after retry, **escalate to user**:
   ```
   HALT_FOR_USER: Story <story-id> has EVIDENCE_PENDING verification.
   DDs pending:
   - <dd-id>: <outcome> (<reason>)
   Action needed: fix the timeout, add a Verify command, or approve closure without trace.
   ```
4. Do NOT attempt autonomous remediation of EVIDENCE_PENDING. It signals infrastructure problems (slow tests, missing fixtures, absent commands), not code defects.

**Verify command mutability (intent-fidelity-pipeline Phase 4):**

When a sub-agent's implementation diverges from the plan (approach changes, test files move, module restructured), the sub-agent SHOULD update the Verify command via `set-verify-commands` as part of its task completion report. Updated commands must pass the same negative-constraint validation as originals (no grep/find/ls/stat/test -f). A `VERIFY_COMMAND_UPDATED` ticket comment records the change for audit trail:

```bash
.claude/scripts/dso ticket comment <story-id> "VERIFY_COMMAND_UPDATED: dd-N command changed from '<old>' to '<new>'"
```

**Re-dispatch rule (d039-ac65)**: If the completion-verifier returned a non-PASS `P1` on ANY prior run during this story's lifecycle AND a fix was subsequently applied (remediation tasks completed, Phase C re-entry executed), you MUST re-dispatch the completion-verifier before closing the story — even when confidence is high that the fix addressed the failing criterion. High confidence is NOT a valid bypass. The verifier must confirm the fix did not introduce regressions on other criteria. Only technical failure (timeout, unparseable JSON) permits proceeding without re-verification. "I fixed the exact criterion that failed" is NOT a substitute for re-dispatch. **The Planner-dispatch HARD-GATE below applies to the re-dispatched verdict as well** — every P1 != PASS verdict, including those returned on a re-dispatch invocation under this rule, MUST route through `dso:verification-remediation-planner` before any remediation ticket creation. The re-dispatch site does NOT bypass the planner gate; the third dispatch path (re-dispatch) is held to the same invariant as the first.

<HARD-GATE id="planner-dispatch-story-level">
**Planner-dispatch HARD-GATE (SC3 caller-side) — story-level (Phase F Step 18)**

When `P1` is non-PASS (`FAIL`, `BLOCKED`, or `INCONCLUSIVE`), the orchestrator MUST dispatch `dso:verification-remediation-planner` BEFORE creating any remediation ticket. The "no ticket creation between verifier-result and planner-result" invariant is load-bearing — adding even a placeholder ticket here violates SC3 and corrupts producer-fidelity. Order matters: read verifier → dispatch planner → read planner output → only then route to a remediation skill or HALT.

**Step 1 — Save verifier output to a stable path.** Write the verifier JSON to `VERIFIER_JSON_PATH` (the same path used for the gate scripts). Do NOT call `.claude/scripts/dso ticket create`, `.claude/scripts/dso ticket comment`, or any other ticket-CLI mutation between this step and Step 4.

```bash
VERIFIER_JSON_PATH=$(mktemp /tmp/verifier-output.XXXXXX)
# <write verifier JSON to $VERIFIER_JSON_PATH>
```

**Step 2 — Dispatch the planner.** The Agent tool call MUST use the named agent type (`dso:verification-remediation-planner`). Hand-written prompts or generic-purpose substitutions are prohibited (same fabrication rule as the completion-verifier dispatch, per CLAUDE.md `rule:dispatch-verifier`).

```
Agent({
  description: "Classify verifier failure for story <story-id>",
  subagent_type: "dso:verification-remediation-planner",
  model: "opus",
  prompt: "VERIFIER_ARTIFACT_PATH: $VERIFIER_JSON_PATH\nSTORY_ID: <story-id>\nEPIC_ID: <epic-id>"
})
```

Fallback form (only on "Unknown agent" error): read `${CLAUDE_PLUGIN_ROOT}/agents/verification-remediation-planner.md` verbatim and pass its full contents as the first element of the prompt under `subagent_type: "general-purpose"` with `model: "opus"`.

**Step 3 — Parse planner output.** The planner emits a single JSON envelope: `scope`, `target_id`, `decomposer_context`, `escalation_upstream`, `confidence`. Save the JSON to `PLANNER_JSON_PATH`:

```bash
PLANNER_JSON_PATH=$(mktemp /tmp/planner-output.XXXXXX)
# <write planner JSON to $PLANNER_JSON_PATH>
PLANNER_SCOPE=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['scope'])")
PLANNER_CONFIDENCE=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['confidence'])")
PLANNER_UPSTREAM=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['escalation_upstream'])")
PLANNER_TARGET=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['target_id'])")
```

**No-ticket-creation invariant**: Between writing `$VERIFIER_JSON_PATH` (Step 1) and reading `$PLANNER_JSON_PATH` (Step 3), the orchestrator MUST NOT invoke `.claude/scripts/dso ticket create` or any equivalent ticket-mutating CLI (no draft, placeholder, or precursor tickets — none). The conformance fixture asserts this textually at all three planner-dispatch sites (Phase F Step 18, Phase G Step 2, and the d039-ac65 re-dispatch site, which reuses Step 18's plumbing on re-invocation).

**Step 4 — Route by planner output.**

- **If `PLANNER_CONFIDENCE == "LOW"` (or `PLANNER_SCOPE == "PROTOCOL_ERROR"`)** — emit `HALT_FOR_USER` surfacing planner evidence and STOP. Do NOT create remediation tickets. The HALT message MUST include the planner's `decomposer_context.remediation_summary`, the `failing_criteria` list, and the `verifier_artifact_path` so the user can investigate.

  ```bash
  echo "HALT_FOR_USER: planner returned $PLANNER_CONFIDENCE confidence for story <story-id>"
  python3 -c "import json; d=json.load(open('$PLANNER_JSON_PATH')); print('  scope:', d['scope']); print('  summary:', d['decomposer_context']['remediation_summary']); print('  failing_criteria:', d['decomposer_context']['failing_criteria']); print('  verifier_artifact_path:', d['decomposer_context']['verifier_artifact_path'])"
  ```

  HALT-vs-REPLAN exclusivity (per `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md` Section 4): `HALT_FOR_USER` (this token) is structurally exclusive with `REPLAN_ESCALATE` — never emit both in the same execution.

- **If `PLANNER_CONFIDENCE != "LOW"`** — dispatch the indicated decomposer with the planner's `decomposer_context`. Route by `PLANNER_SCOPE`:

  | `scope` | Decomposer dispatch | Notes |
  |---------|---------------------|-------|
  | `replan_story` | `/dso:implementation-plan <story-id>` via Skill tool, with `decomposer_context` from `$PLANNER_JSON_PATH` | Re-plans the current story. `escalation_upstream: preplanning`. |
  | `new_tasks_in_story` | Orchestrator creates tasks directly under `<story-id>` per `decomposer_context.remediation_summary` (planner-supplied tasks) — see **Implement-vs-marker discipline** below before creating tasks | `escalation_upstream: planner_supplied`. No re-planning skill needed. |
  | `new_story_in_epic` | `/dso:preplanning <epic-id>` via Skill tool, with `decomposer_context` | Adds a new story under the same epic. `escalation_upstream: preplanning`. |
  | `replan_epic` | `/dso:brainstorm <epic-id>` via Skill tool, with `decomposer_context` | Re-examines epic scope. `escalation_upstream: brainstorm`. |

  **Implement-vs-marker discipline (applies when `PLANNER_SCOPE == "new_tasks_in_story"`):**

  Before creating remediation tasks, read `decomposer_context.remediation_summary` from `$PLANNER_JSON_PATH`. The planner encodes the recommended approach in the summary — act on it directly:

  - **If the summary recommends implementing the feature** (`remediation_approach: implement_feature`, or the summary text says "Implement [X] to make tests GREEN"): create a task whose `title` describes implementing the feature (e.g., "Implement ProvenanceLedger re-export and compute_mutations_with_ledger wrapper"), NOT a marker-registration task. This is the correct path when the planner identified that implementing the feature is smaller and resolves the failing tests directly.
  - **If the summary recommends marker registration** (`remediation_approach: legitimize_marker`, or the summary text says "Register RED marker for [tests] in .test-index"): create a marker-registration task.

  **Cycle-aware blockage detection (applies on remediation cycle ≥ 2):** Before creating any `new_tasks_in_story` task, check the story's ticket comments for previous `REPLAN_RESOLVED: planner — scope=new_tasks_in_story` entries. If ≥ 2 such entries exist AND none of the prior cycle's remediation tasks produced a P1=PASS result, the marker-registration path is structurally blocked — the same approach has failed repeatedly. In this case:
  1. Log: `"IMPLEMENT_INSTEAD: marker-registration path blocked after N cycles — creating implementation task instead."`
  2. Create an implementation task regardless of the planner's summary (the planner's earlier recommendation was based on the same incomplete context that produced the loop).
  3. Record on the story ticket: `.claude/scripts/dso ticket comment <story-id> "IMPLEMENT_INSTEAD: switched from legitimize_marker to implement_feature after N blocked cycles"`.

  Record a REPLAN_TRIGGER comment on the epic BEFORE invoking the chosen decomposer (audit trail) — this is the FIRST ticket-CLI mutation permitted after the planner returns:

  ```bash
  .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: planner — scope=$PLANNER_SCOPE target=$PLANNER_TARGET upstream=$PLANNER_UPSTREAM confidence=$PLANNER_CONFIDENCE"
  ```

  After the decomposer returns (no `REPLAN_ESCALATE`), record resolution:

  ```bash
  .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: planner — scope=$PLANNER_SCOPE remediation tasks created for $PLANNER_TARGET."
  ```

  Then return to Phase C (Batch Preparation) to execute the new remediation tasks.

  **`REPLAN_ESCALATE` handling**: If the decomposer emits `REPLAN_ESCALATE: <upstream>`, follow the upstream-enum routing in `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md` Section 6. The cascade counter (`sprint.max_replan_cycles`) applies — escalate to the user when the cap is reached.

**Remediation loop protocol (sprint verifier-fail touchpoint — story-level)**

When the decomposer returns `REPLAN_ESCALATE: <upstream>` and the orchestrator re-dispatches the verifier, it enters a remediation loop governed by the shared protocol. Source `MAX_CYCLES` from `get_max_remediation_cycles()` in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` before entering the loop.

**Per-cycle declaration**: At the start of every remediation cycle, emit exactly:
`Current cycle: N of MAX_CYCLES`
where `N` is the 1-based cycle counter and `MAX_CYCLES` is the resolved maximum. This line is required before any findings, deltas, or token emissions within that cycle.

**Oscillation-check hard gate (cycle >= 2)**: On any cycle where `N >= 2`, the orchestrator MUST invoke `/dso:oscillation-check` (Skill) before proceeding with findings analysis. Skipping this gate requires an explicit `OSCILLATION_CHECK_SKIPPED: <reason>` ticket comment capturing the rationale; no other skip reason is permitted.

**Mid-loop success exit**: If the verifier returns `P1: PASS` on any cycle (before reaching `MAX_CYCLES`), the loop exits immediately and story closure proceeds. No terminal token is emitted on success.

**HALT-vs-REPLAN exclusivity check**: `REPLAN_ESCALATE` MUST be emitted IFF `cycle_count == MAX_CYCLES AND findings non-empty`. No other condition may emit `REPLAN_ESCALATE`. All other terminal states use a different token — human-input required → `HALT_FOR_USER`; oscillation detected → `OSCILLATION_HALT`; illegal state transition → `PROTOCOL_ERROR`. Emitting `REPLAN_ESCALATE` under any other condition, or emitting it together with `PROTOCOL_ERROR`, is itself a `PROTOCOL_ERROR`.

**Terminal REPLAN_ESCALATE with dynamic upstream**: On cycle `MAX_CYCLES` with the verifier still non-PASS, emit (per the canonical `${CLAUDE_PLUGIN_ROOT}/docs/contracts/replan-escalate-signal.md` colon-space prefix):
`REPLAN_ESCALATE: <escalation_upstream> EXPLANATION:<explanation text>`
The `<escalation_upstream>` value MUST be sourced dynamically from the planner's `escalation_upstream` field in its JSON output (`$PLANNER_JSON_PATH`) — it is NOT hardcoded. The planner determines the correct upstream per-dispatch based on the verifier failure context. See `${CLAUDE_PLUGIN_ROOT}/agents/verification-remediation-planner.md` for the field definition and the upstream enum (`brainstorm` / `preplanning` / `planner_supplied`) in Section 6 of the protocol doc. Emit this as a standalone ticket comment so the orchestrator's parent session can detect and route the escalation. The literal prefix `REPLAN_ESCALATE: ` (colon followed by a single space) and the `EXPLANATION:` field label are fixed by contract — do not vary them.

**PROTOCOL_ERROR on invariant violation**: Any illegal state transition — emitting `REPLAN_ESCALATE` when `cycle_count < MAX_CYCLES`, emitting multiple terminal tokens, or violating the HALT-vs-REPLAN exclusivity invariant — MUST emit `PROTOCOL_ERROR` and halt remediation immediately.

See: `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md`

**Per-cycle scratch write (9a9a/21f3 block — cycle recorder)**

After each cycle's re-dispatch and verifier run, atomically write a cycle-recorder entry to the scratch store using the scratch CLI. The sub-agent writes the payload and returns ONLY a 3-field receipt — it must NOT embed the payload in its return block.

**Namespacing constants (set once before the remediation loop; do NOT alter per-cycle):**

```bash
SCRATCH_TICKET_ID="<story_id>"   # SCRATCH_TICKET_ID — ticket namespace for scratch isolation
SCRATCH_KEY="sprint:step18:batch-plan"   # SCRATCH_KEY — authoritative key per ticket-scratch-cli.md
```

**Sub-agent write (inside sub-agent prompt — cycle recorder):**

The sub-agent constructs the cycle JSON payload and writes it via the scratch CLI:

```bash
# Sub-agent: write cycle entry to scratch store (do NOT return the payload inline)
CYCLE_PAYLOAD=$(python3 -c "import json; print(json.dumps({
  'n': <cycle-number>,
  'draft_hash': '<sha256 of planner output>',
  'findings_count': <int>,
  'verdict': '<pass|fail|escalate>'
}))")
bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" set "$SCRATCH_TICKET_ID" "$SCRATCH_KEY" "$CYCLE_PAYLOAD"  # shim-exempt: internal orchestration script
```

<output_contract>
The sub-agent MUST return ONLY the following 3-field receipt JSON. No other content, no payload body, no cycle details. Embedding the cycle payload in the return block is a contract violation and will produce RECEIPT_PARSE_ERROR.

```json
{"ticket_id": "<SCRATCH_TICKET_ID>", "key": "<SCRATCH_KEY>", "byte_count": <N>}
```

Example (valid):
```json
{"ticket_id": "abcd-1234-efgh-5678", "key": "sprint:step18:batch-plan", "byte_count": 142}
```

Example (INVALID — payload embedded, contract violation):
```json
{"ticket_id": "abcd-1234-efgh-5678", "key": "sprint:step18:batch-plan", "byte_count": 142, "n": 1, "verdict": "fail"}
```
</output_contract>

**Orchestrator-side: validate receipt, then read payload:**

After the sub-agent returns, parse the receipt with `receipt-parse.sh` and halt on any contract violation:

```bash
# Validate receipt — halt on RECEIPT_PARSE_ERROR (exit 2)
_parsed=$(echo "<sub_agent_output>" | bash "$PLUGIN_SCRIPTS/receipt-parse.sh" sprint:step18 dso:verification-remediation-planner) || {  # shim-exempt: internal orchestration script
  echo "ERROR: RECEIPT_PARSE_ERROR from dso:verification-remediation-planner at sprint:step18 — halting workflow" >&2
  exit 1
}
# _parsed = "<ticket_id> <key>" (space-separated) on success

# Read cycle payload from scratch store (SCRATCH_MISS guard — co-located with get)
_raw=$(bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" get "$SCRATCH_TICKET_ID" "$SCRATCH_KEY")  # shim-exempt: internal orchestration script
_status=$(echo "$_raw" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
if [ "$_status" = "miss" ]; then
  # SCRATCH_MISS: sub-agent did not write the key before returning receipt.
  # Example of a miss (key absent): {"status":"miss","ticket_id":"abcd-1234-efgh-5678","key":"sprint:step18:batch-plan"}
  # This is NOT a valid input — treat as a contract violation and halt.
  echo "ERROR: SCRATCH_MISS for $SCRATCH_TICKET_ID/$SCRATCH_KEY — sub-agent returned receipt but key not present; halting." >&2
  # Inline cleanup: remove any partial scratch state before exit
  bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID" "$SCRATCH_KEY" 2>/dev/null || true  # shim-exempt: internal orchestration script
  exit 1
fi
CYCLE_JSON=$(echo "$_raw" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
```

After reading `CYCLE_JSON`, record the cycle artifact via the recorder:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/append_review_cycle.py \  # shim-exempt: internal orchestration script
  --artifact <path-to-verifier-cycle-artifact-for-story> \
  --n <cycle-number> \
  --draft-hash <sha256 of planner output> \
  --findings-count <int> \
  --verdict <pass|fail|escalate>
```

After the append, emit exactly ONE ticket comment per cycle that references the scratch key (not a file path):

```bash
.claude/scripts/dso ticket comment <ticket-id> "Remediation cycle <n> recorded at scratch:$SCRATCH_TICKET_ID/$SCRATCH_KEY"
```

**Single-comment policy (SC6)**: The ticket comment references the scratch key and does NOT duplicate the cycle body — cycle entries live in the scratch store under `$SCRATCH_KEY`, not in ticket comments. One comment per cycle; no further detail in the comment body.

Do NOT rationalize around a non-PASS P1 verdict. The verifier's verdict is final — scope-scoping arguments ("pre-existing failures," "out-of-scope tests," "RED marker tolerance," "already tracked as a separate bug") do not override the planner-gate → Phase C path. The orchestrator's judgment about whether the verdict "really applies" is exactly the bias the verifier+planner pair was designed to counteract. Only `P1: PASS` or technical failure (timeout/unparseable JSON) permits proceeding past this step.
</HARD-GATE>

**RED marker cleanup (before closure)**: After `P1: PASS`, check `.test-index` for stale RED markers associated with tests from this story's scope. If any `[test_name]` entries exist for tests that now pass (GREEN), remove them before closing the story. Stale markers accumulate across story completions and block epic closure.

```bash
# Check for stale RED markers
grep -n "\[.*\]" .test-index || true
# Remove any markers for tests that are now passing
```

**Worktree-isolation-mode note (bug 38b4-e9f6)**: in the default worktree-isolation mode, the story branch's tip equals the session-branch tip at this point — all of the story's tasks already harvested via Phase F Step 5 (see "Cross-Layer File Visibility Invariant" in the Phase F preamble). The `merge-to-main.sh` call below is structurally a no-diff merge in that mode; its purpose is preserving the P1-PASS attribution and trailer chain, NOT moving files. Do NOT skip the call — `merge-to-main.sh` internally detects the no-diff case and exits cleanly.

**Story branch merge (before closure)**: After RED marker cleanup and before closing the story, merge the story branch. The merge path depends on `SPRINT_MODE`:
- `ci-pr` mode: route through `merge-to-main.sh` to create a GitHub PR — do NOT perform a direct local merge
- `local` mode (default): direct local merge with `DSO-Story-Merge` trailer via `merge-story-branch.sh`

**SPRINT_MODE re-read (bug 570a-b3b9)**: Re-resolve `SPRINT_MODE` from config before routing. `SPRINT_MODE` is set once at Phase A activation and held only in LLM context — after context compaction, the value is lost and the routing condition silently falls through to local mode. Re-reading here mirrors the pattern in `per-worktree-review-commit.md` (line 51) which reads `dso.workflow` fresh on every invocation.

```bash
# Re-read SPRINT_MODE from config (bug 570a-b3b9: value lost after compaction)
SPRINT_MODE=$(bash "$PLUGIN_SCRIPTS/mode-detect.sh")  # shim-exempt: SPRINT_MODE must be re-resolved before story-merge routing
```

<HARD-GATE>
**ci-pr merge enforcement**: When `SPRINT_MODE=ci-pr`, you MUST use `merge-to-main.sh` with `STORY_PR_BASE=$SESSION_BRANCH` for EVERY story merge. NEVER use `merge-story-branch.sh` in ci-pr mode — it produces local direct merges with `DSO-Story-Merge` trailers that bypass the GitHub PR flow. Execute the bash block below VERBATIM — do NOT substitute merge-story-branch.sh for merge-to-main.sh.
</HARD-GATE>

```bash
# Conflict queue precondition (in-memory orchestrator check):
if [[ ${#CONFLICT_QUEUE[@]} -gt 0 ]]; then
  echo 'ERROR: conflict queue non-empty — resolve conflicts before merging story branch' >&2
  exit 1
fi
if [[ -z "${SPRINT_MODE:-}" ]]; then
  echo "ERROR: SPRINT_MODE is unset — re-read from config failed. Cannot route story merge." >&2
  exit 1
fi
if [[ "${SPRINT_MODE}" == "ci-pr" ]]; then
  # ci-pr mode: merge via GitHub PR — do NOT perform a local direct merge.
  # Resolve session branch via 3-step fallback — fail-fast, never silently
  # default to main. Per-story LLM review is provided by review-sub-pr.yml
  # (fires on PRs targeting worktree-** session branches). ci.yml's llm-review
  # job (gated to base_ref == 'main') provides cumulative session→main review.
  # /dso:review is HARD-GATED to no-op under dso.workflow=ci-pr.
  # Branch naming dependency: review-sub-pr.yml trigger patterns must match
  # the session branch naming convention (currently worktree-YYYYMMDD-HHMMSS).
  # per-worktree-review-commit.md Step 2 has a fallback that detects mismatches.
  SESSION_BRANCH=$(bash "$PLUGIN_SCRIPTS/resolve-session-branch.sh") || { # shim-exempt: SKILL.md orchestrator instruction — sprint runs plugin scripts via $PLUGIN_SCRIPTS directly
    echo "ERROR: SESSION_BRANCH resolution failed — cannot open story PR against session branch" >&2
    exit 1
  }
  # Open story/* PR against session branch (not main) via STORY_PR_BASE env var.
  # merge-to-main-pr.sh reads STORY_PR_BASE and passes it as --base to gh pr create.
  #
  # Trailer-injection in ci-pr mode (bug e349-6b4e-13c5-4e23):
  # Before queueing gh pr merge --auto, merge-to-main-pr.sh's inject_trailer
  # function uses an ephemeral git worktree to amend (or empty-commit) the
  # DSO-Story-Merge trailer onto the story branch's last commit, then
  # force-push --force-with-lease. The ephemeral worktree has no .sprint-active
  # marker, so the check-session-merge-only.sh hook does not fire. The trailer
  # survives squash/rebase/merge modes. STORY_EPIC_ID + STORY_ID are sourced
  # from emit-story-merge-env.sh; merge-to-main-pr.sh reads both via env.
  #
  # Defense in depth: ci.yml's compute-cross-branch-from-api.sh provides a
  # GitHub API fallback for trailer-less merges (pre-Fix-D sessions or
  # DSO_TRAILER_INJECTION_MODE=disabled). Per-PR review-sub-pr check-run
  # conclusion is verified before subtracting files from INTEGRATION_SCOPE;
  # non-success conclusions cause files to be re-included for full review
  # at integration tier (load-bearing llm-review coverage guarantee).
  source "${CLAUDE_PLUGIN_ROOT}/scripts/emit-story-merge-env.sh" "$STORY_ID" || {  # shim-exempt: internal orchestration script
    echo "ERROR: emit-story-merge-env.sh failed for story $STORY_ID — aborting" >&2
    exit 1
  }
  export BRANCH="$STORY_BRANCH"
  export STORY_PR_BASE="$SESSION_BRANCH"
  bash "$PLUGIN_SCRIPTS/merge-to-main.sh" || { # shim-exempt: SKILL.md orchestrator instruction — sprint runs plugin scripts via $PLUGIN_SCRIPTS directly
    echo "ERROR: merge-to-main.sh failed in ci-pr mode — aborting story merge" >&2
    exit 1
  }
  unset STORY_PR_BASE BRANCH STORY_EPIC_ID
else
  # local mode: direct local merge with DSO-Story-Merge trailer
  bash "$PLUGIN_SCRIPTS/merge-story-branch.sh" "$STORY_BRANCH" "$STORY_ID" || { # shim-exempt: SKILL.md orchestrator instruction — sprint runs plugin scripts via $PLUGIN_SCRIPTS directly
    echo "ERROR: merge-story-branch.sh failed in local mode — aborting story merge" >&2
    exit 1
  }
fi
```

<HARD-GATE>
**DSO-Story-Merge trailer-presence invariant (bug db71-e078-ec99-4fbf)**

After the merge call above (whether `merge-story-branch.sh` in local mode or `merge-to-main.sh` in ci-pr mode) AND before the `ticket transition <story-id> ... closed` call below, you MUST invoke `verify-story-merge-trailer.sh` and abort the story-close path on non-zero exit.

This is a **positive trailer-presence invariant**, NOT a verb ban on `git merge`. Other scripts in this repo (notably `merge-to-main-pr.sh`) legitimately use `git merge --no-edit` and `git merge --ff-only`; a verb-level check would false-positive against them. The gate asserts only what matters for downstream provenance — that a `DSO-Story-Merge: <story-id>` trailer exists somewhere in `<base>..HEAD`.

Background: in worktree-isolation mode, the story branch tip equals the session tip at this point, and a naive `git merge --no-ff` no-ops with "Already up to date." (zero commit, zero trailer). F3 of bug db71 fixed `merge-story-branch.sh` to emit an empty trailer commit in that case; this gate is the load-bearing positive check that catches future regressions or bypasses.
</HARD-GATE>

```bash
# Trailer-presence gate (bug db71-e078-ec99-4fbf): fail-fast before close.
# In ci-pr mode the trailer lands when GitHub auto-merges the story PR;
# the gate scans <base>..HEAD which includes the PR merge commit once it
# has been pulled into the session branch. If the PR is still open at
# this point the gate fails and the story transition is blocked until
# the PR merges and the session re-pulls.
bash "$PLUGIN_SCRIPTS/verify-story-merge-trailer.sh" "$STORY_ID" || { # shim-exempt: SKILL.md orchestrator instruction — sprint runs plugin scripts via $PLUGIN_SCRIPTS directly
  echo "ERROR: trailer-presence gate failed for story $STORY_ID — see recovery guidance above (bug db71-e078-ec99-4fbf)" >&2
  exit 1
}
```

### Leakage Detection

After merging the story branch, run the leakage detector to catch any non-merge commits that bypassed `check-session-merge-only.sh` during this story's execution:

```bash
PLUGIN_SCRIPTS="${PLUGIN_SCRIPTS:-$PLUGIN_ROOT/scripts}"
bash "$PLUGIN_SCRIPTS/detect-session-leakage.sh" || { # shim-exempt: SKILL.md orchestrator instruction — sprint runs plugin scripts via $PLUGIN_SCRIPTS directly
    echo "WARN: session leakage detected — see output above for attribution steps" >&2
    # Non-blocking: leakage is reported but does not abort the sprint.
    # The operator must manually re-attribute flagged commits.
}
```

Leakage detection is non-blocking: it surfaces commits that need re-attribution but does not abort Phase F. The sprint continues; operators must address flagged commits before merge-to-main.

Before closing a bug with `Fixed:`, invoke the bug classifier (3-step): dispatch `bug-classifier-haiku` sub-agent with the ticket ID → extract slug → `CLASSIFIER_OUTPUT=<slug> .claude/scripts/dso classify-bug-at-closure.sh <id> "Fixed:"`.

```bash
.claude/scripts/dso ticket comment <id> "Fixed: <summary>"
.claude/scripts/dso ticket transition <id> open closed --reason="Fixed: <summary>"
```

Do NOT close tasks that are still open or in a failed state.

### Step 19: Context Compaction Check (/dso:sprint)

**Pre-Step 19 gate (5b10-0d02):** Before doing anything else in Step 19, confirm that Step 18 completed successfully this story cycle: dso:completion-verifier was dispatched via the Task tool AND Gate 1 (`check-verifier-verdict.sh`) returned a verdict (exit 0 for `P1: PASS`, or exit 1/2 for non-PASS/invalid). If you cannot confirm this (e.g., Step 18 was skipped or the verifier result is not in context), STOP and return to Step 18 now. Do NOT proceed to Step 19 without the verifier verdict.

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
| `CONTEXT_LEVEL: normal` | 0 | <70% usage | Proceed to Step 20 normally |
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
5. After compaction, check for `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>`. **Continue directly to Phase C** after re-resolving session variables (step 5a below). Do NOT go to Phase I.
5a. **Re-resolve session-scoped variables (bug 570a-b3b9)**: Context compaction drops all LLM-held session variables set during Phase A Config Resolution. Before proceeding to Phase C, re-execute the Config Resolution block from the top of this skill file (the block that sets `TEST_CMD`, `LINT_CMD`, `FORMAT_CHECK_CMD`, `VISUAL_CMD`, `E2E_CMD`, and `SPRINT_MODE` via `read-config.sh` and `mode-detect.sh`). Log: `"Post-compaction: re-resolved SPRINT_MODE=<value>, TEST_CMD, LINT_CMD, FORMAT_CHECK_CMD."` This prevents the class of bugs where session variables lost during compaction cause silent fallback to default values (e.g., `${SPRINT_MODE:-local}` routing to the wrong merge path).
6. **Agent-count after compact**: No special action needed — Phase C Step 2's pre-check re-evaluates `MAX_AGENTS` (may return `unlimited`, `N`, or `0`) automatically.

---

### Step 20: Continuation Decision (/dso:sprint)

#### Out-of-Scope Review Feedback Routing (between batches)

Before evaluating the continuation decision, process any out-of-scope review findings collected during the batch (Step 14). This fires ONLY between batches — never mid-batch.

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
   d. Invoke `/dso:implementation-plan <story-id>` via the Skill tool to create tasks covering the out-of-scope files. When the Skill tool returns, proceed immediately to step e.

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
     Skip the brainstorm cascade entirely. Do NOT write `REPLAN_RESOLVED`. Continue to step 3 below (clear accumulator and return to Phase C). See `docs/contracts/replan-observability.md` for the INTERACTIVITY_DEFERRED signal format. # shim-exempt: internal documentation reference
   - **If `replan_cycle_count >= max_replan_cycles`:** Present the **cap-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "skip re-planning for these stories and continue sprint execution".
   - **If cap is not yet exhausted:** Present the **cap-not-exhausted** user prompt from `prompts/replan-user-prompt.md`, substituting the story list and using `{{proceed_label}}` = "accept the current state and continue sprint with these stories as-is".
     - **If user selects (b) or (c):** act accordingly — proceed or abort. Do not enter cascade.
     - **If user selects (a):** Enter the cascade replan per `skills/sprint/docs/cascade-replan-protocol.md`: # shim-exempt: internal documentation reference
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
4. Return to Phase C (Batch Preparation) to include the newly created tasks.

If `batch_out_of_scope_findings` is empty, proceed to the standard continuation decision below.

#### Standard Continuation Decision

<HARD-GATE>
Do NOT present any AskUserQuestion that proposes narrowing sprint scope between batches — no scope-reduction menus, no "how far do you want to take this session?" prompts, no multi-option menus asking the user to select the next story or next batch. The user's invocation of `/dso:sprint <epic-id>` is the scope decision; mid-sprint scope-narrowing prompts are an anti-pattern (bug 15a4-5150-91dd-4737).

If context pressure is the motivation for pausing: compute usage as a percentage of the announced session context window (e.g., 250,000 / 1,000,000 = 25%). If usage_pct < 70%, proceed to the next batch WITHOUT compacting and WITHOUT asking the user. If usage_pct >= 70%, the ONLY valid action is Phase F Step 19 (Context Compaction Check — run `/compact`), not a user prompt. Context anxiety at < 70% usage is not a legitimate reason to pause.

AskUserQuestion between batches is ONLY permitted for:
- Documented user escalation gates (cascade replan cap exhausted, conflict resolution, Phase F Step 19 involuntary compaction detected)
- Explicit blocking conditions defined in this SKILL (all tasks blocked/failed with no resolution path)
</HARD-GATE>

```
Decision: Involuntary compaction detected? → Yes: P8 (Graceful Shutdown)
          → No: More ready tasks? → Yes: Return to P3
                                  → No: P6 (Validation)
```

**Voluntary vs involuntary compaction**: If `${TMPDIR:-/tmp}/sprint-compact-intent-<epic-id>` exists, delete it and continue to Phase C. If no intent file exists, the compaction was involuntary — go to Phase I.

- If **involuntary** context compaction has occurred (no intent file) → Phase I (graceful shutdown)
- If more ready tasks exist (`.claude/scripts/dso ticket ready --epic=<epic-id>`) → return to Phase C
- If no more ready tasks and some tasks are still blocked → report blocking chain, Phase I
- If all tasks are closed → **run the sprint-bypass redistribute check below, then proceed to Phase G**. Phase G has a HARD-GATE requiring completion-verifier dispatch (Phase G Step 2) before any other Phase G step executes. Do NOT skip the Phase G HARD-GATE.

#### Sprint-bypass redistribute check (bug 85f3) — runs after the batch loop terminates, before Phase G

When sub-agents commit directly to the session branch under the `DSO_SPRINT_ACTIVE=0` escape hatch (instead of dispatching into per-story sub-branches), the resulting session→main PR receives a single monolithic LLM review on the full sprint diff. This is the failure mode reported in bug 85f3 (PR #140 hit a 1095-line diff with 4/4 critical false positives). The `redistribute-session-commits.sh` script splits such commits into per-story branches so each gets a scoped review. This check detects the condition at the natural choke point: after all batches have processed, before validation begins.

**Orchestrator substitution**: before executing the block below, substitute `<epic-id>` with the primary-ticket ID currently being processed. This mirrors the convention used elsewhere in this skill (e.g., `ticket ready --epic=<epic-id>` at line 2811) — placeholders in literal angle-brackets are LLM-substituted at execution time, not bash-expanded.

```bash
<!-- # precondition-emit-ok: the resolve-default-branch call below is a read-only resolution, not a graceful-degradation gate. -->
WORKFLOW=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" dso.workflow 2>/dev/null || echo "local")  # shim-exempt: internal orchestration script
if [[ "$WORKFLOW" == "ci-pr" ]]; then
    # Resolve default branch via the canonical resolver, which handles all four
    # tiers (dso.default_branch config → git symbolic-ref → gh repo view → "main"
    # fallback). Re-implementing the precedence chain here would diverge from
    # the resolver used by every DSO merge script and silently skip detection
    # on projects whose default branch is master/develop/trunk when origin/HEAD
    # isn't configured.
    _default_branch=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/resolve-default-branch.sh" --no-warn 2>/dev/null)  # shim-exempt: sub-agent instruction block
    [[ -z "$_default_branch" ]] && _default_branch="main"

    # Count direct (non-merge) commits on the session branch's FIRST-PARENT history
    # carrying a DSO-Story trailer. The --first-parent flag is critical: without it,
    # `git log --no-merges` walks both parents of merge commits and exposes the
    # per-story-branch commits (which DO carry DSO-Story trailers injected by
    # merge-to-main-pr.sh) as if they were direct-to-session commits. With
    # --first-parent, the walk follows only the session branch's mainline history,
    # so only commits authored directly to the session branch under
    # DSO_SPRINT_ACTIVE=0 are counted. Per-story PR merges appear as merge commits
    # on the first-parent line and are excluded by --no-merges. This assumes the
    # established DSO merge mode (`gh pr merge --merge`, true merge commit — see
    # merge-to-main-pr.sh). Squash-merge mode would invert the semantics.
    _bypass_count=$(git log --no-merges --first-parent --pretty='%H %(trailers:key=DSO-Story,valueonly=true)' "origin/${_default_branch}..HEAD" 2>/dev/null \
        | awk 'NF>1 {c++} END {print c+0}')
    if [[ "$_bypass_count" -gt 0 ]]; then
        echo "REDISTRIBUTE-RECOMMENDED: detected ${_bypass_count} direct-to-session commit(s) with DSO-Story trailers (sprint bypass via DSO_SPRINT_ACTIVE=0)."
        echo "  In ci-pr workflow these produce a monolithic LLM review on the full sprint diff (bug 85f3)."
        echo "  Recommended action (run BEFORE Phase G's completion-verifier dispatches, to avoid attesting against soon-rewritten SHAs):"
        echo "    bash \${CLAUDE_PLUGIN_ROOT}/scripts/redistribute-session-commits.sh --epic <epic-id> --dry-run"  # shim-exempt: sub-agent instruction block
        echo "  Run with --dry-run first to preview the per-story PR split, then re-run without --dry-run to publish."
        # Pause for interactive abort only when running attached to a TTY. In
        # nested-orchestrator / sub-agent contexts (no terminal), the Ctrl-C
        # guidance is meaningless — skip the sleep to avoid dead time per epic.
        if [[ -t 0 ]]; then
            echo "  Proceeding to Phase G in 5s (Ctrl-C to abort and redistribute now)."
            sleep 5 2>/dev/null || true
        else
            echo "  Non-interactive context — proceeding to Phase G immediately. Orchestrator may parse REDISTRIBUTE-RECOMMENDED to act."
        fi
    fi
fi
```

This is a recommendation, not a hard gate. The `DSO_SPRINT_ACTIVE=0` bypass is a documented escape hatch in CLAUDE.md — accepting a monolithic review is sometimes a legitimate tradeoff (small sprint, single-author session, intentional bypass). The recommendation surfaces the bug 85f3 failure mode without forcing redistribution; users who want per-story scoped reviews abort the 5-second pause and run the redistribute script before Phase G runs. Re-entry via `--resume` re-runs the detection idempotently (the check is a read-only git query).

---

## Phase G: Post-Primary Ticket Validation (/dso:sprint)

**Triggered when**: all child tasks are closed (or all remaining are failed/blocked).

<HARD-GATE>
Do NOT execute any Phase G step until Step 2 (completion-verifier dispatch) has completed and Gate 1 (`check-verifier-verdict.sh`) has returned a `P1` verdict for the epic. Do NOT skip Step 2 because "all stories are closed" or "all tasks passed" — those are orchestrator-level observations, not independent verification. CLAUDE.md `rule:dispatch-verifier`: the verifier exists because the orchestrator is biased toward confirming its own work.

Do NOT proceed to Step 3 (/dso:validate-work) or Phase I (Session Close) without the completion-verifier result. Phase G steps must execute in order: Step 2 → Step 3 → Step 4 → Step 5 → Step 6 → Step 7.
</HARD-GATE>

### Step 1: Integration Test Gate, CI Verification, and E2E Tests

Read and execute `prompts/epic-ci-and-e2e-gates.md` for the integration test gate, CI verification, and E2E testing. After completing those steps, proceed to Step 2 below.

### Step 2: Completion Verification (/dso:sprint)

<!-- DD4: self-application validation deferred to S11 (684d-ed77-c6ce-442b) -->

**MANDATORY**: Dispatch the completion-verifier using the same shape defined in Phase F Step 18's "Verifier dispatch shape" HARD-GATE — primary form uses `subagent_type: "dso:completion-verifier"` with `model: "opus"` (epic-level verification requires deeper judgment than story-level); fallback form reads `agents/completion-verifier.md` verbatim and passes its full contents under `subagent_type: "general-purpose"` with `model: "opus"`. Hand-written paraphrases of the agent file are CLAUDE.md `rule:dispatch-verifier` violations (bug c716-952a). Pass the epic ID instead of a story ID.

After receiving the verifier JSON output, render the closure narrative FIRST, then run the gate checks:

**Render closure narrative (before gate checks)**

```bash
# Save verifier JSON output to a temp file
VERIFIER_JSON_PATH=$(mktemp /tmp/verifier-output.XXXXXX)
# <write verifier JSON to $VERIFIER_JSON_PATH>
# Render deterministic closure narrative — use this output verbatim in any closure summary; do NOT paraphrase or summarize LLM-style
CLOSURE_NARRATIVE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/render-closure-narrative.sh" "$VERIFIER_JSON_PATH")  # shim-exempt: internal orchestration script
echo "Closure narrative: $CLOSURE_NARRATIVE"
```

**Gate 1: Machine-readable verdict check**
<!-- Consumer migrated to schema_version=2 P1 typed-enum field (S1b). Backward-compat for schema_version<2 payloads is handled inside check-verifier-verdict.sh (falls back to overall_verdict with a deprecation warning). -->

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-verifier-verdict.sh" "$VERIFIER_JSON_PATH"  # shim-exempt: internal orchestration script
```

- Exit 0 (`P1=PASS`): continue to story closure
- Exit 1 (non-PASS: `FAIL`/`BLOCKED`/`INCONCLUSIVE`): **HALT** — do not close story; emit `CLOSURE_BLOCKED: P1=<value>`
- Exit 2 (missing/invalid): **HALT** — emit `CLOSURE_BLOCKED: verifier output invalid`

**Gate 2: Manifest completeness check**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-manifest-completeness.sh" "$VERIFIER_JSON_PATH"  # shim-exempt: internal orchestration script
```

- Exit 0 (complete): continue
- Exit 1 (incomplete): **HALT** — emit `MANIFEST_INCOMPLETE: missing field <field>`
- Exit 2 (invalid): **HALT** — emit `MANIFEST_INCOMPLETE: verifier output unreadable`

Only when both gates exit 0, interpret the verdict:

- `P1: PASS` → proceed to Step 3
- `P1: FAIL` or `P1: BLOCKED` or `P1: INCONCLUSIVE` → **STOP. Do NOT proceed to Phase H or epic closure under ANY circumstances.** Route through the **Planner-dispatch HARD-GATE** below; do NOT create any remediation ticket until the planner returns.
- **Fallback (technical failure only)**: On timeout/unparseable JSON (Gate 1 exit 2), log warning and proceed to Step 3.

<HARD-GATE id="planner-dispatch-epic-level">
**Planner-dispatch HARD-GATE (SC3 caller-side) — epic-level (Phase G Step 2)**

When `P1` is non-PASS at the epic level, the orchestrator MUST dispatch `dso:verification-remediation-planner` BEFORE creating any remediation ticket. The "no ticket creation between verifier-result and planner-result" invariant is load-bearing here as well — adding even a placeholder ticket violates SC3.

**Step 1 — Verifier JSON already persisted.** `$VERIFIER_JSON_PATH` was written above (before Gate 1). Do NOT call `.claude/scripts/dso ticket create`, `.claude/scripts/dso ticket comment`, or any other ticket-CLI mutation between the Gate 1 verdict and Step 4 below.

**Step 2 — Dispatch the planner.** Pass the EPIC ID as both `STORY_ID` and `EPIC_ID` (epic-level invocation — the planner's decision tree treats the epic as its own scope context).

```
Agent({
  description: "Classify epic-level verifier failure for epic <epic-id>",
  subagent_type: "dso:verification-remediation-planner",
  model: "opus",
  prompt: "VERIFIER_ARTIFACT_PATH: $VERIFIER_JSON_PATH\nSTORY_ID: <epic-id>\nEPIC_ID: <epic-id>"
})
```

Fallback form (only on "Unknown agent" error): read `${CLAUDE_PLUGIN_ROOT}/agents/verification-remediation-planner.md` verbatim and pass its full contents under `subagent_type: "general-purpose"` with `model: "opus"`.

**Step 3 — Parse planner output.**

```bash
PLANNER_JSON_PATH=$(mktemp /tmp/planner-output.XXXXXX)
# <write planner JSON to $PLANNER_JSON_PATH>
PLANNER_SCOPE=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['scope'])")
PLANNER_CONFIDENCE=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['confidence'])")
PLANNER_UPSTREAM=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['escalation_upstream'])")
PLANNER_TARGET=$(python3 -c "import json,sys; print(json.load(open('$PLANNER_JSON_PATH'))['target_id'])")
```

**No-ticket-creation invariant**: Between writing `$VERIFIER_JSON_PATH` (Step 1) and reading `$PLANNER_JSON_PATH` (Step 3), the orchestrator MUST NOT invoke `.claude/scripts/dso ticket create` or any equivalent ticket-mutating CLI. The conformance fixture asserts this at the epic-level site independently of the story-level site.

**Step 4 — Route by planner output.**

- **If `PLANNER_CONFIDENCE == "LOW"` (or `PLANNER_SCOPE == "PROTOCOL_ERROR"`)** — emit `HALT_FOR_USER` surfacing planner evidence and STOP. Do NOT create remediation tickets.

  ```bash
  echo "HALT_FOR_USER: planner returned $PLANNER_CONFIDENCE confidence for epic <epic-id>"
  python3 -c "import json; d=json.load(open('$PLANNER_JSON_PATH')); print('  scope:', d['scope']); print('  summary:', d['decomposer_context']['remediation_summary']); print('  failing_criteria:', d['decomposer_context']['failing_criteria']); print('  verifier_artifact_path:', d['decomposer_context']['verifier_artifact_path'])"
  ```

  HALT-vs-REPLAN exclusivity (per `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md` Section 4): `HALT_FOR_USER` and `REPLAN_ESCALATE` are structurally exclusive — never emit both.

- **If `PLANNER_CONFIDENCE != "LOW"`** — dispatch the indicated decomposer with the planner's `decomposer_context`:

  | `scope` | Decomposer dispatch | Notes |
  |---------|---------------------|-------|
  | `replan_story` | `/dso:implementation-plan <target_id>` via Skill tool (target is a story under this epic) | `escalation_upstream: preplanning`. |
  | `new_tasks_in_story` | Orchestrator creates tasks directly under `<target_id>` per `decomposer_context.remediation_summary` — see **Implement-vs-marker discipline** (Phase F Step 18, `new_tasks_in_story` branch) before creating tasks | `escalation_upstream: planner_supplied`. |
  | `new_story_in_epic` | `/dso:preplanning <epic-id>` via Skill tool, with `decomposer_context` | Adds a new story to this epic. `escalation_upstream: preplanning`. |
  | `replan_epic` | `/dso:brainstorm <epic-id>` via Skill tool, with `decomposer_context` | Re-examines epic scope. `escalation_upstream: brainstorm`. |

  Record REPLAN_TRIGGER on the epic BEFORE invoking the chosen decomposer (this is the FIRST permitted ticket-CLI mutation after the planner returns):

  ```bash
  .claude/scripts/dso ticket comment <epic-id> "REPLAN_TRIGGER: planner (epic-level) — scope=$PLANNER_SCOPE target=$PLANNER_TARGET upstream=$PLANNER_UPSTREAM confidence=$PLANNER_CONFIDENCE"
  ```

  After the decomposer returns (no `REPLAN_ESCALATE`), record resolution:

  ```bash
  .claude/scripts/dso ticket comment <epic-id> "REPLAN_RESOLVED: planner (epic-level) — scope=$PLANNER_SCOPE remediation tasks created for $PLANNER_TARGET."
  ```

  Then return to Phase C (Batch Preparation) to execute the new remediation tasks.

Do NOT rationalize around a non-PASS P1 verdict (7c1d-9acf). The verifier's verdict is final — scope-scoping arguments ("pre-existing failures," "out-of-scope tests," "RED marker tolerance," "already tracked as a separate bug") do not override the planner-gate → Phase C path. The orchestrator's judgment about whether the verdict "really applies" is exactly the bias the verifier+planner pair was designed to counteract. Only `P1: PASS` (Gate 1 exit 0) or technical failure (timeout/unparseable JSON) permits proceeding to Step 3.

On non-PASS: the ONLY valid responses are (a) route through this Planner-dispatch HARD-GATE and return to Phase C to create and complete remediation tasks, or (b) if the user explicitly says to stop the sprint (not "close the epic anyway"), escalate for sprint abort. Do NOT present non-PASS findings with waiver arguments. Do NOT ask the user if criteria can be skipped. Do NOT proceed to Phase H.
</HARD-GATE>

**Sprint abort with successor-handoff (bug 3487-9521)**: When the user chooses option (b) — stop the sprint — present each failing SC with its `failure_category` from the verifier output (see completion-verifier.md Step 3 item 6). For each failing SC, require the user to declare a disposition:
- **(a) abandoned** — the SC is intentionally dropped; no successor will pick it up
- **(b) inherited by successor** — the SC will be carried by a named successor epic (user must provide the epic ID or confirm one will be created)
- **(c) deferred** — the SC is deferred to a future unspecified effort

Record the SC dispositions as a ticket comment on the epic: `.claude/scripts/dso ticket comment <epic_id> "SPRINT_ABORT SC dispositions: <SC>: <disposition> ..."`. For SCs with disposition (b), verify the named successor epic exists and is `open` before accepting. Do NOT collapse `internal_architecture_gap` failures into `external_blocker` framing — if the epic's own scope did not ship the required capability, name the architecture gap as the proximate cause.

### Step 3: Run /dso:validate-work (/dso:sprint)

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
- **All 5 domains PASS** → proceed to Step 4
- **Any domain FAIL** → create remediation tasks and return to Phase C (Batch Preparation)
- **Staging test SKIPPED** (staging down) → proceed to Step 4 but note in the final report that staging was not verified

### Step 4: Determine Epic Type (/dso:sprint)

Scan the epic description and child task titles for UI keywords:
- **UI keywords**: `template`, `page`, `route`, `component`, `CSS`, `frontend`, `upload`, `form`, `layout`, `button`, `HTML`, `style`, `responsive`, `modal`, `dialog`
- **Classification**: If any UI keyword found → **UI epic**; otherwise → **backend-only epic**

### Step 5: Gather Changed Files (/dso:sprint)

```bash
git diff --name-only main...HEAD
```

### Step 6: Launch Epic-Specific Validation Sub-Agent (/dso:sprint)

Launch a Task tool with the appropriate subagent type:
- UI epic: `subagent_type="full-stack-orchestration:test-automator"`
- Backend-only epic: `subagent_type="general-purpose"` (use routing category `test_write` via `discover-agents.sh` to resolve the appropriate agent)

**Validation Agent Prompt**: Read and fill in the externalized prompt template:
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Read: $PLUGIN_ROOT/skills/sprint/prompts/epic-validation-review.md
# Placeholders: {title}, {id}, {epic-type}, {repo_root}, {list of files from git diff}
```

### Step 7: Parse Validation Output (/dso:sprint)

Extract the SCORE from the validation agent's output:
- **Score = 5** → Phase I (completion)
- **Score < 5** → Phase H (remediation)

---

## Phase H: Remediation Loop (/dso:sprint)

**Trigger**: Epic validation score < 5 (from Phase G Step 7).

Read and execute `prompts/remediation-loop.md` for the full remediation protocol (gap classification, oscillation check, user confirmation, task creation, and safety bounds).

---

## Stage-Boundary Exit Write

Before entering Phase I (Primary Ticket Closure), write the preconditions exit event for the sprint stage (fail-open):

```bash
_dso_pv_exit_write "sprint" "${_UPSTREAM_EVENT_ID:-}" "${SPEC_HASH:-}" "${primary_ticket_id:-}" || true
```

## Phase I: Primary Ticket Closure (/dso:sprint)

Remove the `.sprint-active` marker so post-session commits (e.g., release pipeline) are not blocked by the merge-only hook.
```bash
# Remove sprint-active marker — session complete
rm -f "$(git rev-parse --show-toplevel)/.sprint-active"
```

**Bypass log requirement**: When a closure gate is overridden, record a bypass log entry in the artifact bundle before proceeding:
```json
{
  "gate_overrides": [
    {
      "gate_name": "<name>",
      "bypass_log": {
        "rationale": "<reason the gate was overridden>",
        "caller_context": "<who/what triggered this override>",
        "timestamp": "<ISO 8601 timestamp>"
      }
    }
  ]
}
```
Overrides without a complete `bypass_log` (both `rationale` and `caller_context` required) are a hard error. Validate with:
```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/bypass-log-check.sh" --artifact-file="<artifact-bundle-path>"  # shim-exempt: internal orchestration script
```

Phase I delegates to `/dso:end-session`, which handles closing issues, committing, running `merge-to-main.sh`, and reporting.

### On Success (Score = 5)

**Pre-condition**: Phase G Step 2 must have returned `P1: PASS` (Gate 1 exit 0) during this session. If the completion-verifier returned a non-PASS P1 at any point and no remediation batch was executed after the non-PASS (i.e., the failure was not addressed via Phase C re-entry), do NOT proceed with epic closure — return to Phase C to address the FAIL findings first.

**Non-PASS P1 is unconditionally blocking.** If the completion-verifier returned `P1: FAIL`, `P1: BLOCKED`, or `P1: INCONCLUSIVE` at any point (Phase F Step 18 story-level or Phase G Step 2 epic-level) and no subsequent remediation batch resolved the findings, do NOT proceed to epic closure. Do NOT:
- Present the non-PASS verdict to the user with rationalizations
- Ask the user whether failing criteria can be waived
- Suggest that "most" criteria passing is sufficient
- Offer to close the epic with caveats

The only valid actions on non-PASS are: (a) return to Phase C to address the findings, or (b) explicitly confirm with the user that they want to STOP the sprint entirely (not close the epic as "done").

**Narrative framing discipline (bug 8f43-e219)**: Non-PASS SC failure presentation and successor-handoff enforcement are defined in the Phase G Step 2 HARD-GATE sprint abort path (bug 3487-9521). The verifier's `failure_category` field (external_blocker / internal_architecture_gap / evidence_pending) drives the disposition dialog. This section (On Success) is only reachable when P1=PASS — failing SC guidance belongs at the abort site, not here.

<HARD-GATE>
Before closing the epic, confirm that dso:completion-verifier was dispatched at Phase G Step 2 with the EPIC ID (not a story ID) and Gate 1 (`check-verifier-verdict.sh`) returned exit 0 (`P1: PASS`) during THIS session. Story-level verifier results from Phase F Step 18 do NOT satisfy this requirement — each story verifier runs against one story's done definition; only the epic-level verifier (Phase G Step 2) runs against all epic-level success criteria simultaneously. If Phase G Step 2 has not yet been dispatched for the epic, stop and return to Phase G Step 2 NOW. Do NOT proceed to epic closure until the epic-level verifier verdict is received.
</HARD-GATE>

1. **Verify all changes are merged before closing the epic** (399f-abad):
   ```bash
   git merge-base --is-ancestor HEAD main
   ```
   If this exits non-zero, do NOT close the epic — changes have not been merged to main. Run `merge-to-main.sh` first and resolve any conflicts before proceeding. Only close the epic after `merge-base --is-ancestor` exits 0. When merge-to-main.sh completes, proceed immediately to step 2 — merge-to-main.sh returning is NOT a sprint completion signal. Exception: if its output begins with `ESCALATE:`, stop and surface the escalation to the user per end-session Step 4.

2. Close the epic:
   ```bash
   .claude/scripts/dso ticket comment <epic-id> "Epic complete: all tasks closed, validation score 5/5, branch merged to main"
   .claude/scripts/dso ticket transition <epic-id> in_progress closed
   ```
   After `ticket transition` completes, proceed immediately to step 3. Closing the epic ticket is NOT a sprint completion signal. The command emits `REMINDER: Epic closed — run /dso:end-session to complete the sprint cleanly.` — this REMINDER is purely informational; it is satisfied by steps 3–5 below. Do NOT relay it to the user or stop here.

3. Set sprint context for `/dso:end-session` report:
   - Epic ID and title
   - Total tasks completed this session
   - Validation score: 5/5
4. **Multi-sprint routing check** — ask the user exactly this question before invoking session close:
   <MULTI-SPRINT-ROUTING>
   Present to the user:

   > **Epic <epic-title> is complete.**
   > Is there another epic to sprint in this session, or should I close the session now?
   > - To sprint another epic: `/dso:sprint <next-epic-id>`
   > - To close the session: reply "close" or just press Enter

   Wait for the user's response:
   - If the user provides a next epic ID or says they want to continue sprinting: print
     `/dso:sprint <next-epic-id>` as a reminder and EXIT Phase I here. Do NOT invoke
     `/dso:end-session` — the session is not ending.
   - If the user replies "close", presses Enter, or gives no further epic to sprint:
     proceed to step 5.

   This question is a **workflow routing decision**, not permission-seeking for
   /dso:end-session. Asking "Is there another epic?" is required. Asking "Would you
   like me to run /dso:end-session?" is the sycophantic anti-pattern (c26f-be3f) that
   is still prohibited.
   </MULTI-SPRINT-ROUTING>
5. Invoke `/dso:end-session --bump minor` via the Skill tool:
   ```
   Skill({skill: "dso:end-session", args: "--bump minor"})
   ```
   If `version.file_path` is not configured in `dso-config.conf`, the `--bump minor` flag is a no-op.
   <HARD-GATE>
   This MUST be done using the Skill tool — not interpreted as a bash command, not
   printed as text, and not deferred for the user to run. The slash-command notation
   above is a Skill tool invocation shorthand. Use the Skill tool directly.
   Do NOT ask the user "Would you like me to run /dso:end-session?" — that phrasing is
   the sycophantic permission-seeking anti-pattern (c26f-be3f). The multi-sprint routing
   question in step 4 is the ONLY permitted user interaction at this point. If the user
   chose to close the session (step 4), invoke /dso:end-session immediately — do not ask
   again.
   Closing the epic in step 2 and running merge-to-main.sh in step 1 do NOT complete
   Phase I — they are prerequisites for /dso:end-session, not substitutes. Exiting
   after steps 1–4 without invoking /dso:end-session (when the user chose session close)
   is the specific anti-pattern this gate prevents (bug 89fe-bad1).
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
6. Invoke `/dso:end-session` via the Skill tool. Pass `--bump minor` if the epic reached Phase G completion-verifier PASS this session; omit `--bump` for incomplete sprints (no version bump earned):
   ```
   Skill({skill: "dso:end-session", args: "--bump minor"})   # on success
   Skill({skill: "dso:end-session"})                         # on graceful shutdown
   ```
   <HARD-GATE>
   This MUST be done using the Skill tool — not interpreted as a bash command.
   Do NOT ask the user whether to run /dso:end-session. Invoke it directly.
   </HARD-GATE>

---

## Visual Evaluator Integration (Integration B — Post-Batch)

After `VISUAL_CMD` (or `make test-visual`) completes in Phase F validation, the sprint orchestrator dispatches the visual-evaluator agent at **Opus 4.7** for a post-batch review pass over all UI files modified in the batch. This is **Integration B** — the post-batch dispatch with token-budget guard.

### Activation Gate

Activates when:
- `visual_evaluator.enabled=true` (default false — opt-in via `.claude/dso-config.conf`), AND
- At least one task in the completed batch modified UI files (via `detect-ui-files.sh`), AND
- The shared preconditions pass (via `visual-eval-preconditions.sh --route-map-required`) <!-- # precondition-emit-ok -->

Implementation: `.claude/scripts/dso sprint/visual-eval-post-batch.sh` (called at Phase F Step 12a).

### Token-Budget Guard

Two-tier budget (soft-warn + hard-stop) prevents runaway Opus 4.7 spend:

| Config Key | Default | Behavior |
|---|---|---|
| `visual_evaluator.post_batch_token_budget` | `50000` | Soft-warn threshold |
| `visual_evaluator.post_batch_token_hard_stop_multiplier` | `3` | Hard-stop = soft × multiplier (default 150000) |

**Soft-warn path**: When projected dispatch tokens exceed `post_batch_token_budget`, emit `degradation_type=visual_eval_post_batch_nearing_budget` to the integration gate. **Dispatch proceeds** — this is informational only.

**Hard-stop path**: When projected tokens exceed `post_batch_token_budget × multiplier`, SKIP the dispatch entirely. Emit `degradation_type=visual_eval_post_batch_skipped_budget_exceeded`. Annotate the epic ticket with `visual_eval_inapplicable:post_batch_budget`. **The 5th committee reviewer (visual-spatial-evaluator) is not invoked**; arbitration falls back to the 4-reviewer committee per `${CLAUDE_PLUGIN_ROOT}/skills/ui-designer/docs/arbitration.md`.

### Degradation Types

| Token Range | degradation_type | Dispatch | 5th Reviewer |
|---|---|---|---|
| ≤ `post_batch_token_budget` | (none) | YES | YES |
| ∈ (budget, budget × multiplier] | `visual_eval_post_batch_nearing_budget` | YES | YES |
| > budget × multiplier | `visual_eval_post_batch_skipped_budget_exceeded` | NO | NO (4-reviewer fallback) |

### Regression Tests

See `tests/skills/test-sprint-post-batch-visual-eval.sh` for the three required test cases:

1. `test_soft_warn_below_threshold`: projected 47000 tokens → no warning logged, dispatch proceeds
2. `test_soft_warn_above_threshold`: projected 60000 tokens (between 50000 and 150000) → `visual_eval_post_batch_nearing_budget` logged, dispatch proceeds
3. `test_hard_stop_above_3x`: projected 160000 tokens (>150000) → dispatch SKIPPED, `visual_eval_post_batch_skipped_budget_exceeded` logged, 4-reviewer fallback path activated

