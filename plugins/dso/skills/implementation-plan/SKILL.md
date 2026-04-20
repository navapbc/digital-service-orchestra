---
name: implementation-plan
description: Use when a user story or simple epic needs to be broken into atomic, TDD-driven implementation tasks with architectural review, or when planning how to implement a specific ticket item
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
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
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)  # shim-exempt: internal orchestration script
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)  # shim-exempt: internal orchestration script
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)  # shim-exempt: internal orchestration script
APPROACH_RESOLUTION=$(bash "$PLUGIN_SCRIPTS/read-config.sh" implementation_plan.approach_resolution)  # shim-exempt: internal orchestration script
# APPROACH_RESOLUTION: "autonomous" (default) | "interactive"
# When absent or empty, defaults to "autonomous"
APPROACH_RESOLUTION="${APPROACH_RESOLUTION:-autonomous}"
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

**Supports dryrun mode.** Use `/dso:dryrun /dso:implementation-plan` to preview without changes.

## Observability: SKILL_ENTER Breadcrumb

Immediately after config resolution above, emit the SKILL_ENTER trace breadcrumb:

```bash
_DSO_TRACE_SESSION_ID="${DSO_TRACE_SESSION_ID:-$(date +%s%N 2>/dev/null || date +%s)}"
_DSO_TRACE_LOG="/tmp/dso-skill-trace-${_DSO_TRACE_SESSION_ID}.log"
_DSO_SKILL_ENTER_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
_DSO_SKILL_FILE_SIZE=$(wc -c < "${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md" 2>/dev/null || echo "null")
_DSO_NESTING_DEPTH="${DSO_TRACE_NESTING_DEPTH:-1}"
_DSO_SESSION_ORDINAL="${DSO_TRACE_SESSION_ORDINAL:-1}"
_DSO_TOOL_CALL_COUNT="${DSO_TRACE_TOOL_CALL_COUNT:-null}"
_DSO_CUMULATIVE_BYTES="${DSO_TRACE_CUMULATIVE_BYTES:-null}"
echo "{\"type\":\"SKILL_ENTER\",\"timestamp\":\"${_DSO_SKILL_ENTER_TS}\",\"skill_name\":\"implementation-plan\",\"nesting_depth\":${_DSO_NESTING_DEPTH},\"session_ordinal\":${_DSO_SESSION_ORDINAL},\"tool_call_count\":${_DSO_TOOL_CALL_COUNT},\"skill_file_size\":${_DSO_SKILL_FILE_SIZE},\"elapsed_ms\":null,\"cumulative_bytes\":${_DSO_CUMULATIVE_BYTES},\"termination_directive\":null,\"user_interaction_count\":0}" >> "${_DSO_TRACE_LOG}" || true
```

Field notes:
- `skill_name`: hardcoded `"implementation-plan"`
- `nesting_depth`: read from `DSO_TRACE_NESTING_DEPTH` env var (set by parent via `DSO_TRACE_NESTING_DEPTH=<N>` in invocation args); defaults to `1` if absent
- `skill_file_size`: byte count of this SKILL.md via `wc -c`, resolved through `CLAUDE_PLUGIN_ROOT`; `null` on error
- `tool_call_count`: read from `DSO_TRACE_TOOL_CALL_COUNT` env var (approximate, best-effort); `null` if absent
- `session_ordinal`: read from `DSO_TRACE_SESSION_ORDINAL` env var (best-effort, resets on compaction); defaults to `1`
- `cumulative_bytes`: read from `DSO_TRACE_CUMULATIVE_BYTES` env var (running total maintained by session context); `null` if absent
- `elapsed_ms`: always `null` at SKILL_ENTER (not yet known)
- `termination_directive`: always `null` at SKILL_ENTER
- `user_interaction_count`: `0` at SKILL_ENTER (no interactions yet)

## Stage-Boundary Entry Check

Source the preconditions validator library and run the entry check for the implementation-plan stage (fail-open: `|| true` prevents blocking when no upstream preplanning event exists yet):

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/preconditions-validator-lib.sh" 2>/dev/null || true
_dso_pv_entry_check "implementation-plan" "preplanning" "${STORY_ID:-${primary_ticket_id:-}}" || true
```

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
        → No: [Proposal Generation] → Generate ≥3 proposals → Distinctness gate
          → [all pairs distinct] → [Resolution Loop] → Dispatch approach-decision-maker (timeout: 600000)
            → [mode=selection] Accept → Selected proposal → S3 (Task Drafting)
            → [mode=counter_proposal] Revise → Incorporate feedback → [Proposal Generation] (loop, max 2 cycles)
            → [2 cycles exhausted] Escalate → Present proposals + feedback to user → User selects → S3
            → [agent failure] Surface to user for manual resolution
          → [equivalent pair found] → Regenerate with explicit differentiation guidance → [Proposal Generation] (loop)
          → S3 → S4 (Plan Review)
            → [score=5] S5 (Task Creation)
            → [score<5, iter<3] Revise → S4
            → [score<5, iter=3] Present plan with remaining issues
  → S5 complete → [evaluator says TRIVIAL?]
    → Yes: Skip S6, present summary
    → No: S6 (Gap Analysis) → parse findings → create tasks / amend ACs → present summary
      → [S6 fails/times out] Log warning → present summary (non-blocking)
```

---

## Scrutiny Gate

Before proceeding, check if the epic has a `scrutiny:pending` tag:

1. Run `.claude/scripts/dso ticket show <epic-id>` and check the `tags` field
2. If `scrutiny:pending` is present in the tags array: **HALT immediately**. Output:
   "This epic has not been through scrutiny review. Run `/dso:brainstorm <epic-id>` first to complete the scrutiny pipeline, then retry `/dso:implementation-plan`."
   Do NOT produce any planning output.
3. If `scrutiny:pending` is NOT present (or tags field is empty/absent): proceed normally.

This is a presence-based check — only block when the tag IS present. Existing epics without the tags field are NOT blocked.

---

## Interaction Conflict Gate

Before proceeding, check if the epic has an `interaction:deferred` tag:

1. Run `.claude/scripts/dso ticket show <epic-id>` and check the `tags` field
2. If `interaction:deferred` is present in the tags array: **HALT immediately**. Output:
   "This epic has unresolved cross-epic interaction conflicts. Resolve or override them in `/dso:brainstorm <epic-id>` before proceeding to `/dso:implementation-plan`."
   Do NOT produce any planning output.
3. If `interaction:deferred` is NOT present (or tags field is empty/absent): proceed normally.

This is a presence-based check — only block when the tag IS present. Existing epics without the tags field are NOT blocked. If ticket show fails, treat the tag as absent and proceed (fail-open).

---

## Manual Story Tag Guard

Before proceeding, check if the story being planned is tagged `manual:awaiting_user`:

1. Check the flag gate: `EXTERNAL_DEP_ENABLED=$(bash "$PLUGIN_SCRIPTS/read-config.sh" planning.external_dependency_block_enabled)`. If the flag is absent, empty, or `false`, skip this gate entirely and proceed normally — baseline behavior is preserved.
2. Run `.claude/scripts/dso ticket show <story-id>` and check the `tags` field for `manual:awaiting_user`.
3. If `manual:awaiting_user` is NOT present: proceed normally (not a manual story).
4. If `manual:awaiting_user` IS present: enter the branching logic below.

### Branching Logic for manual:awaiting_user Stories

**Prep-work detection heuristic**: Check the story's done definitions for references to artifacts that do not yet exist in the codebase — specifically: a verification script path, a user-facing instructions document path, or a CLI wrapper that would need to be authored. Use Glob and `test -f` to check if referenced paths exist.

**Branch A — No prep work needed** (heuristic: done definitions reference no new code artifacts):
- Do NOT decompose the story into tasks.
- Emit a refusal diagnostic explaining that this story is a manual step handled as a unit by sprint.
- Emit: `STATUS:blocked REASON:manual_story_no_prep STORY:<story-id>`
- The manual verification step is never decomposed into a task.

**Branch B — Prep work required** (heuristic: done definitions reference at least one artifact not yet in the codebase):
- Decompose ONLY the prep tasks using standard RED/GREEN/UPDATE classification.
- The manual verification step itself is NEVER included as a decomposed task — it is a user-performed action.
- Read the parent epic's External Dependencies block (conforming to `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`) to seed prep-task context: use the `name`, `verification_command`, and `justification` fields from the relevant block entry to populate prep-task descriptions with real resource names and verification commands rather than invented placeholders.
- Continue to Step 1 (Contextual Discovery) with only the prep tasks in scope.

This is a presence-based check — only activate when `manual:awaiting_user` IS present AND the flag is enabled. Existing stories without this tag are NOT affected.

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

### Re-invocation Guard

Before proceeding to Epic Type Detection, check whether the story/epic already has child tasks (i.e., this is a re-invocation). Use:

```bash
.claude/scripts/dso ticket deps <story-id> --include-archived
```

This returns a JSON object with shape `{"ticket_id": "<story-or-epic-id>", "children": ["id1","id2",...], "deps": [...], "blockers": [...], "ready_to_work": bool}` — not a flat list of IDs. Parse ONLY the `children` field to get direct child ticket IDs (including archived ones). Do NOT use the `deps` or `blockers` fields for this guard — they contain cross-story relationships (siblings, peers) that are not children and would cause false short-circuits:

```bash
CHILDREN=$(.claude/scripts/dso ticket deps <story-id> --include-archived | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["children"]))')
```

**If `children` is empty (no existing child tasks):** This is the first invocation — skip this guard entirely and proceed to Epic Type Detection below.

For each child ID in the `children` list, run `.claude/scripts/dso ticket show <child-id>` and classify by status:

- **closed or archived** (`status=closed` OR `archived=true`): read-only — never modify, reopen, or duplicate; log as skipped
- **in-progress** (`status=in_progress`): **hard hold** — an active sub-agent may be working on this task. Do NOT produce a diff plan that modifies in-progress children. If any in-progress children exist, emit `STATUS:blocked REASON:in_progress_children_detected TASKS:<in-progress-ids>` and stop. The sprint orchestrator should retry after those tasks complete
- **open** (`status=open`): candidate for revision — may be updated or left as-is

Log a summary line:
```
Re-invocation guard: N closed (read-only), M in-progress (flagged), K open (candidates)
```

**If ALL children are closed (read-only):**
Log "All children are complete — no new tasks needed". Before emitting STATUS, emit the SKILL_EXIT trace breadcrumb per the Observability section. Then emit:
```
STATUS:complete TASKS:<comma-separated-child-ids> STORY:<story-id>
```
where `<comma-separated-child-ids>` is the full list of child IDs already fetched from the `children` field of the `ticket deps` JSON output (comma-separated, no spaces), and `<story-id>` is the story/epic being processed. Do not proceed further.

**Otherwise:**
Produce only a diff plan: new tasks to be created + open/flagged tasks to be revised — never touch closed children. The diff plan must clearly distinguish "new or reopened" tasks from tasks that are left unchanged. After producing the diff plan, proceed to Epic Type Detection below with only the open/new tasks in scope. (The SKILL_EXIT breadcrumb is emitted at the normal end of the full skill execution, not at this intermediate guard exit.)

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

After loading the story with `.claude/scripts/dso ticket show <story-id>`, check for a preplanning context in the parent epic's ticket comments:

1. Extract the parent epic ID from the story's `parent` field
2. Run `.claude/scripts/dso ticket show <parent-epic-id>` and scan the `comments` array for the last comment in the array whose `body` starts with `PREPLANNING_CONTEXT:`
3. If found AND the embedded `generatedAt` timestamp is within the last 7 days:
   - Extract the JSON payload from the comment body (strip the `PREPLANNING_CONTEXT: ` prefix)
   - If the payload is not valid JSON, treat as not found and fall through to step 4
   - Load epic data from the payload (skip a second `.claude/scripts/dso ticket show <parent-epic-id>` re-fetch)
   - Load sibling stories from the payload (skip `.claude/scripts/dso ticket deps` + per-sibling `.claude/scripts/dso ticket show`)
   - Carry forward: review findings, walking skeleton flags, classifications, traceability lines, story dashboard
   - Log: `"Context loaded from preplanning comment on epic <parent-epic-id> — skipping redundant epic/sibling fetch"`
   - **Skip the Input Analysis section below** and proceed directly to Architectural Alignment
4. If not found OR stale (>7 days) OR malformed JSON:
   - Log: `"No recent preplanning context found on epic <parent-epic-id> — running full Input Analysis"`
   - Proceed with normal Input Analysis below

**Backward compatibility (schema_version-aware parsing):**

The PREPLANNING_CONTEXT payload carries a `schema_version` field. Readers MUST apply version-aware parsing to remain compatible with legacy contexts:

- Check `schema_version` after parsing the JSON payload. If the field is **absent** or its value is less than `2`, apply v1 compatibility mode: the `researchFindings` field is not expected — treat as empty array and continue.
- If `schema_version >= 2`, the `researchFindings` field is expected; if `researchFindings` is **absent** from a v2+ payload, treat as empty array (fail-open) — do NOT block context loading.
- **Fail-open contract**: any parsing failure on the `researchFindings` field (corrupt structure, unexpected type, missing nested keys) MUST NOT block context loading. Treat as empty array, emit a warning log line (`"researchFindings parse failed on epic <parent-epic-id> — treating as empty"`), and continue with the rest of the payload.
- Existing Context File Check behavior (epic data, sibling stories, walking skeleton flags, classifications, traceability lines, story dashboard) is unaffected when `researchFindings` is absent or unparseable.

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

**Exploration decomposition**: When gathering context involves compound or multi-source questions (spanning multiple codebase layers, web research, or ambiguous scope), apply the shared exploration decomposition protocol at `skills/shared/prompts/exploration-decomposition.md`. Classify each question as SINGLE_SOURCE or MULTI_SOURCE before answering. Emit DECOMPOSE_RECOMMENDED when a factor is unspecified or two findings contradict.

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

**If no ambiguities found**, proceed to Unsatisfiable Criteria Detection.

### Unsatisfiable Criteria Detection

After resolving ambiguities (or confirming none exist), check whether the success criteria can actually be satisfied given the current codebase state:

- If success criteria are contradicted by codebase state (e.g., SC says "add OAuth login" but a closed ticket permanently removed OAuth per legal mandate)
- If SC items are mutually exclusive (A and B cannot both be true simultaneously)
- If the current architecture makes the SC impossible to implement without fundamental redesign beyond this story's scope

**When any of these apply, emit the REPLAN_ESCALATE signal and STOP — do NOT proceed to task drafting:**

```
REPLAN_ESCALATE: brainstorm EXPLANATION:<human-readable explanation of the contradiction or impossibility, including what SC cannot be satisfied, why (the codebase state that contradicts it), and what the orchestrator should investigate>
```

This signal is terminal — it is the final output. Do not emit STATUS:complete or STATUS:blocked after it.

**Distinction from STATUS:blocked:**
- STATUS:blocked = user can answer questions to unblock planning (ambiguous requirements, missing info)
- REPLAN_ESCALATE = the story intent itself needs brainstorm-level re-examination; no clarifying question can unblock it; the success criteria cannot be satisfied as written

**If no unsatisfiable criteria found**, proceed to Cross-Cutting Change Detection.

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

### Proposal Generation

Read `shared/prompts/complexity-gate.md`. If the file cannot be read, STOP and emit:
"ERROR: complexity-gate.md not found at skills/shared/prompts/complexity-gate.md — create this file before running implementation-plan."

After resolving cross-cutting detection, generate at least 3 distinct implementation proposals for the story before proceeding to task drafting. Each proposal represents a genuinely different approach to satisfying the story's success criteria, giving the reviewer or decision-maker a real choice rather than surface-level variations.

**Complexity gates per proposal**: At the task-planning level, apply Gates 1 and 2 from `shared/prompts/complexity-gate.md` to each proposal before submitting it to the approach-decision-maker:

- **Gate 1 (YAGNI)**: Does this proposal add functionality not required by the current story's done definitions? If FAIL, either revise the proposal to remove the out-of-scope functionality, or include a `justified-complexity` block with evidence.
- **Gate 2 (Rule of Three)**: Does this proposal introduce an abstraction with fewer than 3 existing call sites? If FAIL, either revise the proposal to inline the abstraction, or include a `justified-complexity` block with evidence.

When a proposal adds a new library dependency, apply Gate 3 before the proposal is submitted to the approach-decision-maker. Include a GATE/CHECKED/FINDING/VERDICT block (format defined in `shared/prompts/complexity-gate.md`) for Gate 3 in the proposal's `cons` or as an annotation alongside the proposal.

**Proposal format**: Each proposal MUST include all six fields defined in `prompts/proposal-schema.md` (the single source of truth for field definitions, risk categories, and the distinctness gate). Read that file before generating proposals. Required fields:

| Field | Description |
|-------|-------------|
| `title` | Concise name for the approach (≤ 80 characters) |
| `description` | How the approach works and why it satisfies the success criteria |
| `files` | File paths likely touched (create, modify, or delete) |
| `pros` | Concrete advantages traceable to design decisions |
| `cons` | Concrete drawbacks and risks — do not omit known tradeoffs |
| `risk` | One of: `low`, `medium`, `high` (see `prompts/proposal-schema.md` for criteria) |

**Minimum proposal count**: Generate at least 3 proposals. A default of 3 is used when no project-level override is set. If the story is genuinely constrained to fewer viable approaches, document the constraint explicitly and generate as many distinct approaches as exist — but attempt at least 3 before concluding that fewer are possible.

**Distinctness validation gate**: Before finalizing the proposal set, self-verify that every pair of proposals differs on at least one of the four structural axes defined in `prompts/proposal-schema.md`:

- **Data layer** — how and where state is stored or retrieved
- **Control flow** — the execution path or orchestration strategy
- **Dependency graph** — which modules, packages, or services are introduced or removed
- **Interface boundary** — where the public contract is drawn and what it exposes

For each pair `(A, B)`, compare on all four axes. If any pair is structurally equivalent on all four axes (two proposals that differ only in naming or surface details), **reject one and replace it** with a genuinely different approach — then re-verify. A proposal set with any equivalent pair MUST NOT be presented or passed to the decision-maker.

Axis comparison is structural, not textual. "Store in a dictionary" and "use a hash map" are the same data-layer choice. Two proposals may look similar yet still pass if they differ on control flow or interface boundary.

**Approach resolution routing** (config-driven via `APPROACH_RESOLUTION`):

- **Autonomous mode** (`APPROACH_RESOLUTION=autonomous`, the default when key is absent): Pass the full proposal set to the decision-maker agent for autonomous selection. The decision-maker returns a selected proposal; use that as the basis for task drafting in Step 3. Do NOT display proposals to the user or wait for manual selection — proceed directly after agent selection.
- **Interactive mode** (`APPROACH_RESOLUTION=interactive`): Display the proposals to the user in a readable format (title, description, pros, cons, risk for each). Wait for the user to select a proposal before proceeding to Step 3. Do NOT dispatch the decision-maker agent — the user makes the selection. Do NOT begin task drafting until the user has confirmed a selection.

### Resolution Loop

After generating a valid, distinct proposal set, dispatch the `dso:approach-decision-maker` agent to evaluate and select an approach. This loop arbitrates between proposals and feeds back into proposal regeneration when no existing proposal is satisfactory.

#### Cycle State Persistence

Before dispatching the agent, read and update the cycle counter from the state file:

```bash
STATE_FILE="/tmp/approach-resolution-${STORY_ID}.json"
# Read current cycle count (0 if file absent or stale)
if [ -f "$STATE_FILE" ]; then
  _file_age=$(( $(date +%s) - $(date -r "$STATE_FILE" +%s 2>/dev/null || echo 0) ))
  if [ "$_file_age" -gt 14400 ]; then
    # TTL = 4 hours; treat stale file as fresh start
    rm -f "$STATE_FILE"
    CYCLE_COUNT=0
  else
    CYCLE_COUNT=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('cycle_count', 0))" 2>/dev/null || echo 0)
  fi
else
  CYCLE_COUNT=0
fi
```

#### Dispatch

Dispatch the `dso:approach-decision-maker` agent (subagent_type, model: opus, timeout: 600000) with:
- All proposals from the generation step (full proposal set with title, description, files, pros, cons, risk)
- Story success criteria and done definitions
- Current codebase context (architecture notes, existing patterns)

**Inline fallback**: If the Agent tool rejects the `dso:approach-decision-maker` subagent type (e.g., "Unknown agent type", "not supported", or any dispatch failure before the agent runs), read `agents/approach-decision-maker.md` inline and execute its evaluation instructions directly with the same proposal set, success criteria, and codebase context as inputs. This fallback covers the case where plugin agent types are not available in the current Claude Code configuration. The inline execution must still produce a valid `APPROACH_DECISION:` output conforming to `docs/contracts/approach-decision-output.md`.

#### Parse Response

Scan the agent output for the `APPROACH_DECISION:` prefix line per the contract at `docs/contracts/approach-decision-output.md`. Extract the JSON block between the opening ` ```json ` and closing ` ``` ` fences. Validate the `mode` field before acting.

**If the agent output is absent, malformed, missing the `APPROACH_DECISION:` prefix, or contains an unrecognized `mode` value**: log a warning and surface the failure to the user for manual proposal selection. Do NOT autonomously fall back to any proposal.

#### Accept Path (mode: selection)

When `mode` is `"selection"`:
1. Read `selected_proposal_index` and extract the corresponding proposal from the input list
2. Log the ADR rationale (`context`, `decision`, `consequences`, `rationale_summary`) for traceability
3. In autonomous mode (`APPROACH_RESOLUTION=autonomous`): proceed directly to Step 3 (Task Drafting) using the selected proposal without user prompt
4. In interactive mode (`APPROACH_RESOLUTION=interactive`): present the decision-maker's selection and rationale to the user; confirm before proceeding to Step 3
5. Clean up the state file: `rm -f "$STATE_FILE"`

#### Revise Path (mode: counter_proposal)

When `mode` is `"counter_proposal"`:
1. Check whether the cycle limit (max 2 cycles) has been reached:
   ```bash
   CYCLE_COUNT=$(( CYCLE_COUNT + 1 ))
   python3 -c "import json; f=open('$STATE_FILE','w'); json.dump({'cycle_count': $CYCLE_COUNT, 'story_id': '$STORY_ID'}, f)"
   ```
2. If `CYCLE_COUNT` is less than or equal to 2:
   - Incorporate the counter-proposal's `approach` and `done_definitions` as additional input constraints
   - Return to Proposal Generation with explicit guidance: generate new proposals that satisfy both the original success criteria AND the counter-proposal's requirements
   - Re-enter the Resolution Loop with the regenerated proposals
3. If `CYCLE_COUNT` exceeds 2: proceed to the Escalate Path below

#### Escalate Path (after 2 cycles)

When the cycle limit is exhausted (2 revision cycles completed without reaching mode `selection`):
1. Present to the user:
   - All proposals from the most recent generation step
   - All counter-proposal feedback received across cycles (from the state file and current agent output)
   - A clear summary: "The decision-maker could not reach a satisfactory selection after 2 cycles. Please review the proposals and counter-proposal feedback, then select an approach manually."
2. Wait for user review and selection before proceeding to Step 3 (Task Drafting)
3. In autonomous mode, emit `STATUS:blocked REASON:approach_escalated_to_user STORY:<story-id>` and pause for user input — do NOT proceed autonomously
4. Clean up the state file after the user selects: `rm -f "$STATE_FILE"`

#### Autonomous vs Interactive Mode

- **Autonomous mode** (`APPROACH_RESOLUTION=autonomous`): The resolution loop runs without user interaction — accept and revise paths proceed automatically. The escalate path is the only point where user interaction is required; emit the blocked status and pause.
- **Interactive mode** (`APPROACH_RESOLUTION=interactive`): At the accept path, display the selected proposal and rationale to the user before proceeding. At the revise path, briefly note that the decision-maker requested revisions and the loop is retrying. At the escalate path, present the full context and wait for user selection.

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
* **3-Gate Granularity:** Every task must pass all three gates. Gates are conjunctive —
  Gate 3 only mandates splitting when the split would not violate Gate 1 or Gate 2.
    * **Gate 1 — Testable Behavior:** The task must produce testable behavior —
      grepping a source file to verify the existence of code is not a valid test.
      A valid test executes the code under test and asserts on its output, exit code,
      or side effects. (See the Behavioral Test Requirement section for the full
      validity rubric.)
    * **Gate 2 — Codebase Green:** The task must leave the codebase in a deployable,
      green state. After committing only this task, all tests pass and the system is
      deployable. Tasks must never require being committed together — each is an
      independent atomic unit. A task that deploys an inert feature (e.g., a guard
      that reads files no one writes yet) is acceptable — inert is not broken.
    * **Gate 3 — Maximum Granularity:** It must not be possible to split the task into
      smaller tasks that each independently meet Gate 1 and Gate 2. If two changes
      within a task each produce independently verifiable behavior and each leaves the
      codebase green on its own, they must be separate tasks. Bundling is acceptable
      only when splitting would violate Gate 1 (neither half produces testable behavior
      alone) or Gate 2 (splitting would leave an intermediate broken state — e.g., a
      rename across import sites).
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

   **Prefer `sg` (ast-grep) for cross-file dependency discovery** — use it to find callers, importers, and source-chain dependencies with syntax-aware structural matching. Guard against unavailability:

   ```bash
   if command -v sg >/dev/null 2>&1; then
       # Structural search — distinguishes real code references from comments/strings
       sg --pattern 'import $MODULE' --lang python .
       sg --pattern 'from $MODULE import $_' --lang python .
   else
       # Fall back to Grep tool or grep command
       grep -r 'import <module>' .
   fi
   ```

   When `sg` is unavailable, fall back to the Grep tool (or `grep -r`) without error — all environments remain functional.

2. **Find associated tests for each source file** — For each source file, locate its test counterpart using one of two methods:
   - **Fuzzy match** (preferred): source the fuzzy-match library and call `fuzzy_find_associated_tests`:
     ```bash
     source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/fuzzy-match.sh
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

### Consumer Detection Pass

For every file in the impact table whose action is `modify` or `remove`, run a downstream consumer detection pass to identify callers/callsites outside the immediate task scope. A change that looks local can still break external consumers — those callsites must be enumerated before the task is drafted, not discovered at implementation time.

**Prefer `sg` (ast-grep) over text grep** — `sg` is syntax-aware and distinguishes real symbol references from comments and strings. Guard against unavailability:

```bash
if command -v sg >/dev/null 2>&1; then
    # Find every callsite of a symbol (function, method, etc.)
    sg --pattern '$FUNC($$$)' --lang python . | grep -F '<symbol_name>'
    # Or, target a specific symbol directly:
    sg --pattern '<symbol_name>($$$)' --lang python .
else
    # Fall back to grep — accept the false-positive cost
    grep -rn '<symbol_name>(' .
fi
```

When external consumers (callers / callsites in files outside the current task's scope) are found, document them in the task's File Impact section with one of two explicit dispositions:

- **Update** — the external callsite must be changed in this task; add the consumer file to the impact table with action `modify` and pull its tests in.
- **Accept the breaking change** — the change is intentionally breaking for that consumer; record the rationale and ensure the consumer's owner story or follow-on ticket is linked.

A modify/remove task with un-triaged external consumers is incomplete and must be revised before it leaves Step 3.

### Testing Mode Classification

Each task in the plan must carry an explicit `testing_mode` field — either **RED**, **GREEN**, or **UPDATE** — derived from the file impact table. The classification describes what the code does to observable behavior, not what text it adds or removes from source files.

The testing_mode applies to the **source file task** (the implementation task), not the test task. A test task for a RED source file is always called a "RED test task" but the implementation task for that same file also carries `testing_mode: RED`:

| Source file condition | testing_mode | Meaning |
|----------------------|-------------|---------|
| Source action = `create` (new file, classification = `needs-creation`) | **RED** | New behavioral content with no existing tests — must have a preceding RED test task that writes a failing test before implementation runs |
| Source action = `modify`, behavior changes, classification = `needs-modification` | **UPDATE** | Existing file with observable behavior change — existing tests must be updated to assert the new behavior before implementation runs |
| Source action = `modify`, no behavior change (pure refactor), classification = `still-valid` | **GREEN** | Implementation change only — existing tests remain correct without modification, no new test task required |
| Source action = `remove`, classification = `needs-removal` | **GREEN** | Deleting behavior — remove corresponding tests to keep the suite honest |

**Behavioral framing rule**: The testing_mode value must reflect what the code *does* — the observable outputs, decisions, or side effects it produces — not what it *contains*. A refactor that renames internal methods without changing what the function returns for any input is GREEN regardless of how many lines change. A new file that computes and returns a value is RED because its behavior has never been tested.

**Emit testing_mode per task** (in the task plan output):

```
Task: <task title>
testing_mode: RED | GREEN | UPDATE
```

The field must appear as an explicit labeled attribute for each task, not inferred from prose alone. This classification drives which TDD task type (see TDD Task Structure below) is selected and whether a RED test task dependency is required.

### TDD Task Structure

**Behavioral content** is defined as code that contains conditional logic, data transformation, or decision points — any code where the output varies based on inputs or state. Every task whose implementation adds or modifies behavioral content must have a preceding **RED test task** as a declared dependency before any implementation task.

**A RED test may be modifying existing tests, not only creating new test files.** When a story changes existing behavior, the RED test edits an existing test file to assert the new expected behavior — it does not necessarily create a new test file. Tests are behavioral specifications — when behavior changes, the specification must be updated. Modifying existing tests is a first-class RED-phase activity, not a special case.

#### TDD task types

Use the file impact table from File Impact Enumeration to select the correct task type for each source file. The `testing_mode` field from Testing Mode Classification maps directly to task type selection:

- `testing_mode: RED` → **Create-test task** (new file, no existing tests)
- `testing_mode: UPDATE` → **Modify-existing-test task** (behavior change with existing coverage)
- `testing_mode: GREEN` → No test task needed (refactor or deletion with no behavior change)

**1. Create-test task** (source action: `create`, classification: `needs-creation`, testing_mode: `RED`)
- Write a new test file asserting the expected behavior of the new source file — what it returns, emits, or does for given inputs
- Standard RED-first flow; implementation task depends on this create-test task

**2. Modify-existing-test task** (source action: `modify`, classification: `needs-modification`, testing_mode: `UPDATE`)
- Update an existing test to assert the new expected behavior after the source change — describe which observable behaviors change and how the assertions must shift
- This is a RED test task: the modified test must fail (RED) before the implementation runs because the new behavior does not yet exist
- The task must name the specific existing test file to modify and describe which assertions change
- Implementation task depends on this modify-existing-test task

**3. Remove-test task** (source action: `remove`, classification: `needs-removal`, testing_mode: `GREEN`)
- Remove test cases or entire test files that verify behavior being deleted from the source
- Removing tests for deleted behavior keeps the test suite honest and prevents dead-code assertions
- This task may run before or in parallel with the source removal task (no behavioral assertion to run RED)
- If only some cases within a test file need removal, describe the specific cases to delete

A RED test task:
- Writes a failing test that asserts the expected behavior
- Must fail (RED) before the implementation task runs
- Is a standalone task in the plan, not embedded in the implementation task description
- Uses `TEST_CMD` (resolved from `commands.test` in workflow-config) as the verify command
- **Must be a behavioral test** — see [Shared Behavioral Testing Standard](../shared/prompts/behavioral-testing-standard.md)
- **Must update `.test-index` with a `[test_function_name]` RED marker** for the source file before committing the RED test — the pre-commit test gate blocks commits that include a failing test without a matching RED marker. The acceptance criteria for every RED test task must include:
  ```
  - [ ] `.test-index` updated with RED marker `[<test_function_name>]` for `<source-file>`
    Verify: grep '\[<test_function_name>\]' $(git rev-parse --show-toplevel)/.test-index
  ```

#### Behavioral Test Requirement

RED tests must follow the [Shared Behavioral Testing Standard](../shared/prompts/behavioral-testing-standard.md). Read that file before writing any test task. The standard defines five rules covering coverage checks, observable-behavior assertions, execution requirements, the refactoring litmus test, and structural boundaries for non-executable instruction files.

**Test approach framing**: Each task that produces a RED test must include a test approach sentence written in **Given / When / Then** format:
- **Given**: the preconditions and inputs (test fixture, initial state)
- **When**: the action or invocation (what the code under test is called with)
- **Then**: the observable outcome asserted (return value, exit code, file written, or side effect)

If the test approach describes grepping a source file rather than invoking the code under test, the task must be revised to describe a behavioral assertion instead.

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

**Primary path constraint**: When the story's success criteria describe a user-facing flow (sign-in, checkout, form submission, API call from a browser client), the integration test must exercise that exact path — not an administrative, server-side, or CLI equivalent that bypasses user-facing infrastructure (e.g., OAuth browser callback, CSRF validation, session cookie issuance). A test that reaches the same external service via a privileged bypass does not satisfy this rule even if it passes. Document which user-facing path is covered in the task description.

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

### Wireframe Design Decision

When the story involves UI changes:
1. **Design wireframes inline (Recommended)** — create wireframes as part of implementation planning
2. **Defer wireframes** — skip wireframe design for this story (only appropriate when visual design is not part of the story's scope)

If wireframes are being created inline, verify that `/dso:preplanning` has already been run for the parent epic — `dso:ui-designer` is dispatched by preplanning Step 6 and produces the Design Manifest (spatial layout tree, SVG wireframe, design token overlay) as a `UI_DESIGNER_PAYLOAD`. If no design artifacts exist, re-run `/dso:preplanning <epic-id>` before proceeding. Include a wireframe task that references the existing design artifacts before implementation tasks. Implementation tasks that touch UI components should depend on the wireframe task.

If deferring, document the rationale in the plan (e.g., "Visual design is out of scope for this story — wireframes will be produced in a dedicated design story").

### E2E Testing Requirement

If the story introduces or modifies user-facing behavior, API endpoints, or cross-component flows, include a dedicated E2E test task:

- **New user flows**: E2E test(s) covering happy path and key error states
- **Modified flows**: Update existing E2E tests; add new tests for new paths
- **API-only changes**: E2E tests if the change affects responses consumed by frontend or external clients
- Place in `tests/e2e/` following existing conventions
- E2E task depends on all implementation tasks (runs last)

If purely internal (no behavior change), document why E2E coverage is not needed.

### Visual Verification Metadata (visual_verification)

When a task's File Impact list contains files matching UI patterns — `.css`, `.js`, `.ts`, `.tsx`, `.html`, `.jinja2`, or files inside component directories — the generated task description MUST declare visual verification:

- Add the metadata field `requires_visual_verification: true` to the task description.
- Add a Playwright acceptance criterion: "Run `playwright test` targeting the affected component; verify no visual regression against baseline."

When the task touches no UI files, omit both the `requires_visual_verification` field and the Playwright AC entirely (do not emit `requires_visual_verification: false` — absence is the signal).

The sub-agent executing the task is responsible for running Playwright as part of satisfying its acceptance criteria. The sprint orchestrator does NOT add a separate Playwright dispatch step — the verification is owned by the implementing task.

The `requires_visual_verification` token is a structural contract surface consumed by downstream automation (sprint, fix-bug). Use the literal token verbatim.

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
${CLAUDE_PLUGIN_ROOT}/docs/contracts/<interface-name>.md
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

### Retry Budget

Each implementation task carries a retry budget that the orchestrator parses and enforces when dispatching sub-agents. The budget defines the maximum attempts at each model tier before escalating, and the terminal user-escalation point.

```
## Retry Budget
MAX_ATTEMPTS: 3 (sonnet model)
On 3 consecutive sonnet failures: escalate to opus with full diagnostic context (all 3 failure messages)
On 3 consecutive opus failures (6 total): escalate to user with full failure history
If MAX_AGENTS: 0 at sonnet→opus escalation time: skip opus step, escalate to user immediately
```

The orchestrator parses `MAX_ATTEMPTS` from the generated task description as the per-tier attempt cap. Include this block verbatim in every task description — the structural marker `MAX_ATTEMPTS` is the integration token sub-agent dispatchers use to determine the retry cap.

#### Opus Escalation

When a sub-agent at the sonnet tier fails `MAX_ATTEMPTS` consecutive times, the orchestrator re-dispatches the task at the opus tier. The escalation dispatch MUST include the full diagnostic context from all sonnet failures:

- Each failed sub-agent's final report
- Test output / error messages from each failure
- Files modified across all attempts (with diffs if available)
- Any `RESOLUTION_RESULT` or contract-violation signals emitted

This context lets opus see the full failure trajectory rather than starting cold. If `MAX_AGENTS: 0` (paused) is in effect at the moment escalation would trigger, skip the opus tier and proceed directly to user escalation — opus dispatch is gated by usage capacity.

#### User Escalation

After 6 total consecutive failures (3 sonnet + 3 opus), the orchestrator terminates the autonomous retry loop and escalates to the user. The escalation report MUST include the full failure history:

- All 6 failed sub-agent reports in chronological order
- The diagnostic context that was passed to opus
- A concise summary of what was attempted and why each attempt failed
- The current state of the working tree (files modified, tests failing)

User escalation is also the immediate path when `MAX_AGENTS: 0` blocks opus dispatch, in which case the report contains the 3 sonnet failures plus an explicit note that opus escalation was skipped due to usage throttling.

### Pattern Reference

When the upstream `dso:complexity-evaluator` output specifies `pattern_familiarity: low` or `medium` for a task, enrich the generated task description with a `## Pattern Reference` block containing up to 30 lines of representative codebase examples. This gives the implementation sub-agent concrete prior art to mirror, reducing the chance of inventing a novel pattern when an established one already exists.

#### Gating Rule

- `pattern_familiarity: low` — REQUIRED: include a Pattern Reference block.
- `pattern_familiarity: medium` — REQUIRED: include a Pattern Reference block.
- `pattern_familiarity: high` (or no evaluator output) — OMIT the section entirely; the sub-agent already knows the pattern and extra context is noise.

#### Retrieval Rules

- Use local `grep`/`glob` only to find representative examples — no external lookups, no nested LLM calls.
- Search anchors come from the task's file impact list and the evaluator's identified pattern keywords.
- Cap the included excerpt at **≤30 lines total** across all examples so task descriptions stay concise. If a single example exceeds 30 lines, truncate with `# ...` and prefer the most representative slice (function signature + body fragment).
- Cite each example with its source path (e.g., `# from src/utils/example.sh:42-58`).

---

## Step 4: Implementation Plan Review (/dso:implementation-plan)

Read [docs/review-criteria.md](docs/review-criteria.md) for the full reviewer
table, launch instructions, score aggregation rules, and conflict detection guidance.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md` inline to evaluate the plan:

- **subject**: "Implementation Plan for: {story title}"
- **artifact**: The user story (title + full description) plus the numbered task list with titles, descriptions, TDD requirements, and dependencies
- **pass_threshold**: 5 (this plan must be safe for unsupervised agent execution)
- **start_stage**: 1
- **perspectives**: Read from reviewer files using the full anchored path `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/plan/`:
  - `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/plan/task-design.md` — perspective: `"Task Design"`
  - `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/plan/tdd.md` — perspective: `"TDD"`
  - `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/plan/safety.md` — perspective: `"Safety"`
  - `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/plan/dependencies.md` — perspective: `"Dependencies"`
  - `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/plan/completeness.md` — perspective: `"Completeness"`

  **If any reviewer file cannot be read: HALT immediately. Do NOT synthesize inline perspectives or construct an ad-hoc rubric. Report: "Step 4 blocked: reviewer file `<path>` not found — create the missing reviewer file before proceeding."**

### Optimization

The plan **must** achieve all dimension scores of **5**. The review protocol workflow's revision protocol handles the iteration loop (max 3 cycles). After 3 attempts, present the plan at its current score with remaining issues to the user for judgment.

---

## Step 5: Task Creation (/dso:implementation-plan)

Once the plan is approved (Score: 5 or user-approved), create tasks in the ticket system.

### Create Tasks

For each task in the plan, use the following command form. The `-d` flag is required — pass the full task body (testing mode, acceptance criteria, implementation notes) at creation time. **Do not create the task first and add the body as a comment** — the `description` field is the canonical task spec.

Each task must include:

| Field | Content |
|-------|---------|
| **Title** | Concise and atomic |
| **Description** | Implementation steps, file paths, constraints |
| **TDD Requirement** | Specific failing test to write first |
| **Acceptance Criteria** | Included via `-d/--description` at creation time |

**Required command form** — always include acceptance criteria via `-d`:

```bash
# Create the task with acceptance criteria included in description
TASK_ID=$(.claude/scripts/dso ticket create task "{title}" --parent=<story-id> --priority=2 -d "$(cat <<'DESCRIPTION'
## Testing Mode
<RED|GREEN|UPDATE>

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

If `.claude/scripts/dso ticket create` fails, retry once. If still failing, report the error.

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

Actions: **Create**, **Edit**, or **Remove**. If multiple tasks touch the same file, list all task IDs — this signals overlap for the orchestrator's batch conflict detection.

Report:
- Total tasks created
- File impact summary (above)
- Dependency graph (`.claude/scripts/dso ticket deps <story-id>`)
- Ready tasks (`.claude/scripts/dso ticket list` filtered by story)
- Whether documentation/E2E tasks were included and why

**When invoked interactively (user-initiated)**: Stop and wait for user instructions — do not begin implementing any tasks.

**When invoked from `/dso:sprint` (via Skill tool)**: Do NOT stop. Continue immediately to Step 6 (Gap Analysis) and then emit STATUS:complete per the Output Protocol section below.

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

### Return Control to Sprint Orchestrator

**When invoked from `/dso:sprint` (via Skill tool)**: After updating the summary, emit STATUS:complete per the Output Protocol section below. Do not wait for user input.

---

## Quick Reference

| Step | Purpose | Key Commands |
|------|---------|--------------|
| 1 | Contextual Discovery | `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket deps`, Glob/Grep, clarify ambiguities, cross-cutting detection. When `planning.external_dependency_block_enabled=true`: if story is tagged `manual:awaiting_user`, refuse decomposition (no prep needed) or produce prep-only tasks (prep work exists); block seeds prep-task context; manual verification step never appears as a task. |
| 2 | Architectural Review | `REVIEW-PROTOCOL-WORKFLOW.md` inline (>= 4, max 3 iterations); forced if cross-cutting detected |
| 3 | Atomic Task Drafting | TDD-first, sequential order, E2E + docs coverage |
| 4 | Plan Review | `REVIEW-PROTOCOL-WORKFLOW.md` inline (all dims = 5, max 3 iterations) |
| 5 | Task Creation | `.claude/scripts/dso ticket create`, `.claude/scripts/dso ticket link`, `validate-issues.sh`, `.claude/scripts/dso ticket list` |
| 6 | Gap Analysis | TRIVIAL skip gate, opus sub-agent via `prompts/gap-analysis.md`, parse findings |

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Planning on assumptions | Run the ambiguity scan; ask before drafting |
| Tasks too large (multi-concern) | Apply the 3-gate test: Gate 1 (testable behavior), Gate 2 (codebase green), Gate 3 (cannot split further while meeting gates 1 and 2). If two changes each produce independently verifiable behavior, they must be separate tasks |
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

## Stage-Boundary Exit Write

Before emitting any STATUS line, write the preconditions exit event for the implementation-plan stage (fail-open):

```bash
_dso_pv_exit_write "implementation-plan" "${_UPSTREAM_EVENT_ID:-}" "${SPEC_HASH:-}" "${STORY_ID:-${primary_ticket_id:-}}" || true
```

## Observability: SKILL_EXIT Breadcrumb

Before emitting any STATUS line (whether `STATUS:complete` or `STATUS:blocked`), emit the SKILL_EXIT trace breadcrumb:

```bash
_DSO_SKILL_EXIT_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
_DSO_EXIT_TOOL_CALL_COUNT="${DSO_TRACE_TOOL_CALL_COUNT:-null}"
_DSO_EXIT_USER_INTERACTION_COUNT="${DSO_TRACE_USER_INTERACTION_COUNT:-0}"
_DSO_SKILL_FILE_SIZE_EXIT=$(wc -c < "${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/SKILL.md" 2>/dev/null || echo "null")
_DSO_CUMULATIVE_BYTES_EXIT="${DSO_TRACE_CUMULATIVE_BYTES:-null}"
# Compute elapsed_ms from SKILL_ENTER timestamp if available; otherwise null
if [ -n "${_DSO_SKILL_ENTER_TS}" ] && [ "${_DSO_SKILL_ENTER_TS}" != "unknown" ]; then
    _DSO_ENTER_EPOCH=$(date -d "${_DSO_SKILL_ENTER_TS}" +%s 2>/dev/null || python3 -c "import datetime; print(int(datetime.datetime.strptime('${_DSO_SKILL_ENTER_TS}', '%Y-%m-%dT%H:%M:%SZ').timestamp()))" 2>/dev/null || echo "")
    _DSO_EXIT_EPOCH=$(date -u +%s 2>/dev/null || echo "")
    if [ -n "${_DSO_ENTER_EPOCH}" ] && [ -n "${_DSO_EXIT_EPOCH}" ]; then
        _DSO_ELAPSED_MS=$(( (_DSO_EXIT_EPOCH - _DSO_ENTER_EPOCH) * 1000 ))
    else
        _DSO_ELAPSED_MS="null"
    fi
else
    _DSO_ELAPSED_MS="null"
fi
# Detect termination directive: scan STATUS line of output for termination signals
_DSO_TERMINATION_DIRECTIVE="false"
echo "{\"type\":\"SKILL_EXIT\",\"timestamp\":\"${_DSO_SKILL_EXIT_TS}\",\"skill_name\":\"implementation-plan\",\"nesting_depth\":${_DSO_NESTING_DEPTH},\"session_ordinal\":${_DSO_SESSION_ORDINAL},\"tool_call_count\":${_DSO_EXIT_TOOL_CALL_COUNT},\"skill_file_size\":${_DSO_SKILL_FILE_SIZE_EXIT},\"elapsed_ms\":${_DSO_ELAPSED_MS},\"cumulative_bytes\":${_DSO_CUMULATIVE_BYTES_EXIT},\"termination_directive\":${_DSO_TERMINATION_DIRECTIVE},\"user_interaction_count\":${_DSO_EXIT_USER_INTERACTION_COUNT}}" >> "${_DSO_TRACE_LOG}" || true
```

Field notes:
- `elapsed_ms`: computed as `(exit_epoch - enter_epoch) * 1000`; falls back to `null` if either timestamp is unavailable
- `termination_directive`: `false` by default (implementation-plan does not emit STOP directives); set to `true` if the STATUS line being emitted contains a termination signal scanned from skill output
- `user_interaction_count`: read from `DSO_TRACE_USER_INTERACTION_COUNT` env var (best-effort count of user interactions during execution); defaults to `0`
- All other fields mirror SKILL_ENTER values for correlation

---

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

### On unsatisfiable success criteria (story intent requires brainstorm-level re-evaluation):

```
REPLAN_ESCALATE: brainstorm EXPLANATION:<explanation>
```

Emitted when success criteria cannot be satisfied given the current codebase state — they are actively contradicted, internally contradictory, or unsatisfiable regardless of implementation approach. This is a terminal signal — do not emit STATUS:complete or STATUS:blocked after it. No tasks are created. The calling orchestrator (e.g., `/dso:sprint`) routes this signal to `/dso:brainstorm` on the story rather than proceeding to implementation batches.

**Termination directive**: After emitting a STATUS line, emit no further prose, questions, or options within this skill — the STATUS line is your final output for this skill invocation only, not a directive to halt the calling session. **Do NOT halt the session under any circumstances** — whether invoked interactively or from `/dso:sprint`, halting after emitting STATUS is always wrong. The calling context (sprint orchestrator or user) decides what happens next; this skill's only job is to emit the STATUS line and stop generating. Never treat STATUS:complete as a session-ending signal — it is a return-to-caller signal.
