---
name: implementation-plan
description: Use when a user story or simple epic needs to be broken into atomic, TDD-driven implementation tasks with architectural review, or when planning the TDD task breakdown for a specific story or task ticket. Produces an ordered task list with explicit RED-test specs, identifies file impact and consumer/contract dependencies, runs an architectural review pass with a pass_threshold of 5, and writes the task tickets to the tracker with TDD task structure. Trigger phrases include 'plan this story', 'break this into tasks', 'implementation plan', 'plan the work', 'generate tasks', 'TDD task breakdown', 'how should I implement this story'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<HARD-GATE>
<SUB-AGENT-GUARD>
**/dso:implementation-plan is orchestrator-level only. It MUST NOT be invoked as a sub-agent.**

The skill dispatches its own sub-agents (`dso:approach-proposer`, `dso:approach-decision-maker`, `dso:task-decomposer`, opus gap-analysis on COMPLEX). Running implementation-plan ITSELF as a sub-agent means those dispatches become nested Task calls — which CLAUDE.md `rule:no-nested-task` forbids, and which the platform surfaces as `[Tool result missing due to internal error]`, silently losing the plan output.

**If you detect that this skill is running as a sub-agent**, STOP immediately and return verbatim:

```
ERROR: /dso:implementation-plan must be invoked at the orchestrator level, not as a sub-agent.
REASON: This skill dispatches sub-agents internally; nesting would violate rule:no-nested-task.
CALLER ACTION: Return control to your orchestrator and have IT invoke /dso:implementation-plan
              directly (via the Skill tool, not the Agent/Task tool).
```

Do NOT proceed with any of the Phase A/B/C steps. Do NOT dispatch any further sub-agents. Do NOT produce a partial plan.

**Proxy detection (best-effort)**: if the Agent tool is unavailable in your context (`<available_tools>` does not list `Agent` / `Task`), you are running as a sub-agent — refuse per above. If the Agent tool IS available, that is a necessary but not sufficient signal that you are at the orchestrator level; if the orchestrator's most recent user-facing turn does not match the trigger phrases for this skill (per the `description:` frontmatter), and you were invoked via Skill tool by an upstream skill rather than by the user directly, treat the invocation as suspect and prefer to STOP-and-return rather than proceed.

**Caller-side enforcement**: orchestrators that detect the ERROR return from this skill MUST halt their own progression rather than swallow the ERROR and continue — silently continuing produces a broken plan with missing sub-agent outputs.
</SUB-AGENT-GUARD>
</HARD-GATE>

<!-- Schema reference: docs/designs/stage-boundary-preconditions/ -->

# Implementation Plan: Atomic Task Generation

Generate a production-safe implementation plan for a User Story by decomposing it into atomic, TDD-driven tasks with correct dependencies. Prioritize understanding over assumptions — resolve ambiguity before planning.

## Config Resolution

At activation, load project commands and the approach-resolution mode:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)             # shim-exempt: internal orchestration script
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)             # shim-exempt: internal orchestration script
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)   # shim-exempt: internal orchestration script
APPROACH_RESOLUTION=$(bash "$PLUGIN_SCRIPTS/read-config.sh" implementation_plan.approach_resolution)  # shim-exempt: internal orchestration script
APPROACH_RESOLUTION="${APPROACH_RESOLUTION:-autonomous}"   # autonomous (default) | interactive
```

Resolution order: see `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`. **Supports dryrun mode** (`/dso:dryrun /dso:implementation-plan`).

## Stage-Boundary Entry Check

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/preconditions-validator-lib.sh" 2>/dev/null || true
_dso_pv_entry_check "implementation-plan" "preplanning" "${STORY_ID:-${primary_ticket_id:-}}" || true
```

## Usage

```
/dso:implementation-plan                  # Interactive story selection
/dso:implementation-plan <story-id>       # Plan a specific user story
/dso:implementation-plan <epic-id>        # Plan simple epic directly (when routed by /dso:sprint)
```

If `<id>` is omitted, present an interactive list of open stories. Stories accept tasks under the story; epics (when routed by sprint) accept tasks directly under the epic.

## Progress Checklist

> **Task tracking rule**: Only call `TaskCreate` when `/dso:implementation-plan` is invoked **standalone** (directly by the user). When invoked from `/dso:sprint`, do NOT call `TaskCreate` — sprint owns the task list. Track progress through inline notes.

```
Progress:
- [ ] Step 1: Contextual Discovery (story loaded, context gathered, ambiguities resolved, cross-cutting detection done — layers: _, interfaces: _)
- [ ] Step 2: Architectural Review via REVIEW-PROTOCOL-WORKFLOW.md inline (passed / skipped — no new pattern)
- [ ] Step 3: Task Drafting (tasks drafted with E2E + docs coverage)
- [ ] Step 4: Plan Review via REVIEW-PROTOCOL-WORKFLOW.md inline (all dimensions: 5, iteration: _/3)
- [ ] Step 5: Task Creation (tasks created, deps added, health validated)
- [ ] Step 6: Gap Analysis (COMPLEX: opus sub-agent dispatched, findings processed; TRIVIAL: skipped)
```

## Pre-flight Tag Guards

Before any planning work, run a single tag-guard check on the ticket. Capture the exit code explicitly so a lookup failure (exit 2) is treated as fail-open rather than aborting under `set -e`:

```bash
set +e
_guard=$(bash "$PLUGIN_SCRIPTS/implementation-plan/check-tag-guards.sh" "${STORY_ID:-${primary_ticket_id}}")  # shim-exempt: internal orchestration script
_guard_rc=$?
set -e
# rc=0 → verdict in $_guard (OK or BLOCKED:*); rc=1 → BLOCKED in $_guard;
<!-- EMIT-PRECONDITIONS: gate_name=implementation_plan_tag_guard degradation_type=inferred_decision -->
# rc=2 → lookup failure, treat as OK (fail-open).
if (( _guard_rc == 2 )); then _guard="OK"; fi
```

The script returns one of: `OK`, `BLOCKED:scrutiny_pending`, `BLOCKED:interaction_deferred`, `BLOCKED:manual_awaiting_user`. The first two BLOCKED verdicts halt planning; `BLOCKED:manual_awaiting_user` is non-halting — it enters the branching logic below.

| Verdict | Action |
|---------|--------|
| `BLOCKED:scrutiny_pending` | **HALT.** Emit: "This epic has not been through scrutiny review. Run `/dso:brainstorm <epic-id>` first to complete the scrutiny pipeline, then retry `/dso:implementation-plan`." Do NOT produce any planning output. |
| `BLOCKED:interaction_deferred` | **HALT.** Emit: "This epic has unresolved cross-epic interaction conflicts. Resolve or override them in `/dso:brainstorm <epic-id>` before proceeding to `/dso:implementation-plan`." Do NOT produce any planning output. |
| `BLOCKED:manual_awaiting_user` | **Do NOT halt** — enter the Manual Story Branching section below. |
| `OK` | Proceed to Step 1 (Contextual Discovery). |

The `manual:awaiting_user` check is gated by `planning.external_dependency_block_enabled` — when the flag is absent or `false`, the script returns `OK` regardless of tags.

### Copy Story Bypass

Before continuing past the tag guards, detect whether this story is a **copy story** auto-created by `dso:story-decomposer` (Step C3 of the Copy-Needed Auto-Create Protocol). A story is a copy story when EITHER:

- it carries the `copy-story` tag (canonical signal), OR
- its title begins with the verbatim prefix `"Apply gov-copy to "` (case-insensitive fallback)

These match the producer-side values written by `${CLAUDE_PLUGIN_ROOT}/agents/story-decomposer.md` Step C3. If either signal fires:

1. **Do NOT decompose** — copy stories are dispatched to `dso:gov-copy-writer` by `/dso:sprint` Phase E (see sprint SKILL.md "Copy Story Dispatch" section), not by implementation-plan.
2. Emit exactly: `STATUS:bypass REASON:copy_story STORY:<story-id>`
3. Stop. Do not run Step 1 (Contextual Discovery) or any subsequent step.

The bypass is the canonical handoff from `/dso:implementation-plan` to `/dso:sprint`'s gov-copy-writer dispatcher. Decomposing a copy story into ordinary tasks would silently bypass the federal-style canon, the deterministic post-processor, and the coordination-pass — defeating the gov-copy epic's entire pipeline.

### Manual Story Branching (only when `BLOCKED:manual_awaiting_user`)

**Prep-work detection heuristic**: scan the story's done definitions for references to artifacts not yet in the codebase — a verification script path, a user-facing instructions document path, or a CLI wrapper that would need to be authored. Use Glob and `test -f` to confirm.

**Branch A — No prep work needed** (done definitions reference no new code artifacts):
- Do NOT decompose into tasks. Emit a refusal diagnostic and `STATUS:blocked REASON:manual_story_no_prep STORY:<story-id>`. The manual verification step is never decomposed.

**Branch B — Prep work required** (done definitions reference at least one missing artifact):
- Decompose ONLY the prep tasks using standard RED/GREEN/UPDATE classification. The manual verification step itself is NEVER a decomposed task.
- Read the parent epic's External Dependencies block (per `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`) to seed prep-task context: use `name`, `verification_command`, and `justification` to populate prep-task descriptions.
- Continue to Step 1 with only the prep tasks in scope.

---

## Step 1: Contextual Discovery

### Select Story

If `<story-id>` was not provided:
1. `.claude/scripts/dso ticket list --type=story --status=open` to show open stories
2. Fall back to `.claude/scripts/dso ticket list --type=story` if none open
3. If no stories at all, report and exit
4. Present and get selection

Load: `.claude/scripts/dso ticket show <story-id>`. If not found, report the error and exit.

### Re-invocation Guard

Detect existing children before drafting:

```bash
# Capture exit code separately — rc=2 is the fail-open lookup-failure path
# and would abort the surrounding `set -e` context if not handled here.
set +e
_reinv=$(bash "$PLUGIN_SCRIPTS/implementation-plan/check-reinvocation.sh" "$STORY_ID")  # shim-exempt: internal orchestration script
_reinv_rc=$?
set -e
# rc=2 → lookup failed; the script already emitted verdict=fresh, treat as fresh.
# Any other non-zero rc is unexpected; surface and continue with verdict=fresh.
if (( _reinv_rc != 0 && _reinv_rc != 2 )); then
    echo "WARN: check-reinvocation.sh exited with unexpected rc=${_reinv_rc} — continuing with verdict=fresh"
    _reinv="verdict=fresh"
fi
# Parse KEY=VALUE output line-by-line (do NOT use `eval` — script output is
# trusted but eval on external command output is a fragile pattern).
verdict=$(echo "$_reinv" | grep '^verdict=' | cut -d= -f2-)
closed_count=$(echo "$_reinv" | grep '^closed_count=' | cut -d= -f2-)
in_progress_count=$(echo "$_reinv" | grep '^in_progress_count=' | cut -d= -f2-)
open_count=$(echo "$_reinv" | grep '^open_count=' | cut -d= -f2-)
closed_ids=$(echo "$_reinv" | grep '^closed_ids=' | cut -d= -f2-)
in_progress_ids=$(echo "$_reinv" | grep '^in_progress_ids=' | cut -d= -f2-)
open_ids=$(echo "$_reinv" | grep '^open_ids=' | cut -d= -f2-)
```

Branch on `verdict`:

- **`fresh`**: no children — proceed to Epic Type Detection.
- **`in_progress_hold`**: at least one in-progress child. **Hard hold** — emit `STATUS:blocked REASON:in_progress_children_detected TASKS:<in_progress_ids>` and stop. The sprint orchestrator should retry after those tasks complete.
- **`all_closed`**: all children closed/archived AND no unresolved REPLAN_TRIGGER:validation on the parent. Emit the early-exit STATUS line and stop:
  ```
  STATUS:complete TASKS:<closed_ids> STORY:<story-id>
  ```
  Do not proceed further.
- **`replan_required`**: all children closed/archived BUT the parent epic has an unresolved `REPLAN_TRIGGER:validation` comment mentioning this story — i.e., the completion-verifier reported a story-level FAIL after the original tasks closed, and no `REPLAN_RESOLVED:implementation-plan` has acknowledged it yet. Do NOT emit `STATUS:complete` (that would re-trigger the verifier ↔ impl-plan loop). Enter **diff-plan mode**: read the verifier's `remediation_tasks_created` payload from the parent epic's `REPLAN_TRIGGER:validation` comment, treat its uncovered DDs as the AC source, and produce NEW TDD task pairs (RED + GREEN) addressing each uncovered DD. Continue to Epic Type Detection with the new tasks in scope; on completion, emit a `REPLAN_RESOLVED: implementation-plan — Remediation tasks created for story <story-id>.` comment on the parent epic so the next re-invocation collapses back to `all_closed`.
- **`diff_plan`**: mixed open + closed children. Produce a diff plan covering only new tasks + revisions to open children — never touch closed children. Distinguish "new or reopened" tasks from unchanged ones in the output. Continue to Epic Type Detection with only the open/new tasks in scope.

Log a one-liner: `Re-invocation guard: <closed_count> closed (read-only), <in_progress_count> in-progress (flagged), <open_count> open (candidates)`.

### Epic Type Detection

Check the `type` field from `.claude/scripts/dso ticket show`:

- **`type=epic`**: enter **epic-direct mode** — the epic's done definitions are the AC source; tasks become direct children of the epic; skip Context File Check (no parent); use `--parent=<epic-id>` in Step 5; proceed directly to **Architectural Alignment**.
- **otherwise** (task, story, etc.): continue with Context File Check below.

### Context File Check

After loading the story, look for a recent preplanning context comment on the parent epic:

1. Extract `parent` from the story.
2. Run `.claude/scripts/dso ticket show <parent-epic-id>`. Scan `comments` for the LAST comment whose `body` starts with `PREPLANNING_CONTEXT:`.
3. If found AND embedded `generatedAt` is within 7 days:
   - Parse JSON payload (strip the `PREPLANNING_CONTEXT: ` prefix). On invalid JSON, treat as not found.
   - Load epic data + sibling stories from the payload (skip redundant fetches).
   - Carry forward: review findings, walking skeleton flags, classifications, traceability lines, story dashboard.
   - Log: `"Context loaded from preplanning comment on epic <parent-epic-id>"`.
   - **Skip Input Analysis** and proceed directly to Architectural Alignment.
4. Else: log `"No recent preplanning context — running full Input Analysis"` and proceed below.

**schema_version-aware parsing** (load-bearing wire format):
- Check `schema_version`. If absent or `< 2`: v1 mode — `researchFindings` not expected, treat as empty array.
- If `>= 2`: `researchFindings` expected; if absent, treat as empty array (fail-open).
<!-- EMIT-PRECONDITIONS: gate_name=implementation_plan_research_findings degradation_type=inferred_decision -->
- **Fail-open contract**: any parsing failure on `researchFindings` MUST NOT block context loading — treat as empty, log `"researchFindings parse failed on epic <parent-epic-id> — treating as empty"`, continue.

### Input Analysis

```bash
.claude/scripts/dso ticket show <story-id>
# Extract parent ID from the 'parent' field, then:
.claude/scripts/dso ticket show <parent-epic-id>
.claude/scripts/dso ticket deps <parent-epic-id>     # sibling stories
```

If no parent, proceed with story context alone and note the limited scope.

### Architectural Alignment

- Glob for `docs/**/*.md` and `.claude/docs/**/*.md`
- Grep for "system context", "architecture", "standardization", "ADR"
- Glob for `docs/adr/**/*.md`

### Recipe Consultation

Query the recipe registry to surface available mechanical transforms for the story's language context:

```bash
bash "$PLUGIN_SCRIPTS/consult-recipe-registry.sh" --language <primary-language>
```

Record the output as **available recipe capabilities**. Run without `--language` if the story spans multiple languages or the language is unknown. Empty output (unknown language or missing registry) is not an error — proceed without recipe context.

Recipe-eligible transforms are mechanical and deterministic: function-signature changes, import normalization. Business logic additions, feature decisions, and architectural changes are NOT recipe-eligible regardless of the registry contents.

### Migration-Class Detection

Run the migration-class detector against the story's primary target symbol to classify the migration scope before task drafting begins. This step is **unconditional and non-interactive** — it runs on every Step 1 execution, writes the marker regardless of outcome, and never prompts before persisting.

Determine `TARGET_SYMBOL` from the story description or ticket title (the function, method, or class being changed). If no symbol is determinable, pass an empty string — the script emits `migration-class=inconclusive` cleanly and the marker is still written.

```bash
MIGRATION_MARKER=$(bash "$PLUGIN_SCRIPTS/implementation-plan/migration-class-detect.sh" "<target_symbol>" 2>/dev/null)
.claude/scripts/dso ticket comment <story-id> "MIGRATION_CLASS: $MIGRATION_MARKER"
```

**Even when `migration-class=inconclusive`** (ast-grep unavailable or no symbol provided), write the marker. Never silently omit it — inconclusive is a first-class result, not an error state.

**Last-wins idiom**: re-running Step 1 appends a new `MIGRATION_CLASS:` comment. Consumers MUST read the **last** matching `MIGRATION_CLASS:` comment on the story ticket, ignoring any earlier ones. This mirrors the `COMPLEXITY_CLASSIFICATION:` scan-for-last-comment idiom.

The full marker contract (JSON shape, field definitions, threshold configuration, `sg`-unavailable degradation, consumer protocol) is at `${CLAUDE_PLUGIN_ROOT}/docs/contracts/migration-class-marker.md`.

Log a one-liner: `"Migration-class detection: <migration-class value> (symbol: <target_symbol>)"`.

### Ambiguity Scan

**Curiosity before planning.** A plan built on assumptions is worse than no plan.

**Exploration decomposition**: when context-gathering involves compound or multi-source questions (multi-layer, web research, ambiguous scope), apply `skills/shared/prompts/exploration-decomposition.md`. Classify each question as SINGLE_SOURCE or MULTI_SOURCE. Emit DECOMPOSE_RECOMMENDED when a factor is unspecified or two findings contradict.

| Signal | Example | Action |
|--------|---------|--------|
| Undefined scope boundaries | "improve performance" — of what? by how much? | Ask for measurable criteria |
| Implicit acceptance criteria | "user can upload files" — types? size limits? | Ask for constraints |
| Conflicting signals | Epic says X, story says Y, codebase does Z | Surface the conflict |
| Missing persona | "as a user" — admin or end-user? | Ask which role |
| Unstated constraints | API story with no auth/rate-limiting mention | Ask if intentionally omitted |
| Ambiguous priority | Multiple criteria, unclear essential vs. nice-to-have | Ask for priority ranking |

Batch all questions in one message. Separate **blocking** ("cannot plan without this") from **defaultable** ("I'll assume X unless you say otherwise"). Never ask about things clearly inferrable from the codebase or parent epic.

### Unsatisfiable Criteria Detection

After resolving ambiguities, check whether the SC can be satisfied at all:

- SC contradicted by codebase state (e.g., closed ticket permanently removed the feature SC asks for)
- SC items mutually exclusive (A and B cannot both be true simultaneously)
- Architecture makes SC impossible without redesign beyond this story's scope

When any apply, emit and STOP — do NOT proceed:

```
REPLAN_ESCALATE: brainstorm EXPLANATION:<what SC cannot be satisfied, why (the codebase state contradicting it), and what the orchestrator should investigate>
```

This signal is terminal — do not emit STATUS:complete or STATUS:blocked after it.

**Distinction**: STATUS:blocked = user can answer questions to unblock (ambiguous requirements, missing info). REPLAN_ESCALATE = the story intent itself needs brainstorm-level re-examination; no clarifying question can unblock it.

### Cross-Cutting Change Detection

#### Evaluator Shortcut

If complexity-evaluator output was provided (when invoked from `/dso:sprint`):

1. Reuse `layers_touched` and `interfaces_affected` directly.
2. Sanity-check against the codebase context from Architectural Alignment. If counts seem wrong, note the discrepancy and proceed with corrected counts.
3. Apply the escalation rule below.
4. Skip the full analysis.

If no evaluator output (standalone invocation): perform full analysis.

#### Detection

1. **Trace data/control flow** from entry point to deepest dependency. Count distinct architectural layers touched. Example layer chain: route → service → agent → LLM provider → formatter → DB model → migration. **≥ 3 layers = cross-cutting threshold met.**
2. **Count interfaces/classes needing updates** via Grep/Glob for classes, abstract base types, Protocol definitions, and public method signatures. **≥ 5 interfaces/classes = cross-cutting threshold met.**

#### Escalation Rule

| Condition | Action |
|-----------|--------|
| ≥ 3 architectural layers touched | Force Step 2 — mark **CROSS-CUTTING** |
| ≥ 5 interfaces/classes need updates | Force Step 2 — mark **CROSS-CUTTING** |
| Both thresholds met | Force Step 2, note both signals |
| Neither threshold met | Proceed to new-pattern check; otherwise skip to Step 3 |

When escalating, annotate the Step 2 subject:
```
"Architectural Pattern: {pattern name} [CROSS-CUTTING — {N} layers / {M} interfaces]"
```

### Doc-Only Skip Gate

Before generating proposals, check whether the story exclusively touches documentation or instruction files (`.md` files in `skills/`, `agents/`, `prompts/`, `docs/`, `CLAUDE.md`, or any workflow/config file with no executable behavior). Apply behavioral-testing-standard.md Rule 5: instruction-file changes have only one meaningful implementation and carry no architectural decision. In that case:

1. Log: `"Doc-only story — skipping Proposal Generation and approach-decision-maker dispatch"`
2. Skip directly to **Step 3: Atomic Task Drafting** with `testing_mode: GREEN` for all tasks.
3. Do NOT generate proposals or dispatch the decision-maker.

Signals that indicate a doc-only story:
- Story title/description mentions updating a SKILL.md, CLAUDE.md, workflow doc, agent file, or other `.md` guidance file
- All affected files in the file impact table are `.md` or `.conf` with no associated executable code change
- Story is testing_mode: GREEN with only instruction file updates in scope

### Proposal Generation (via `dso:approach-proposer` opus sub-agent)

**Sync discipline** — the contract summary, dispatch wiring, validation steps, and `agents/approach-proposer.md` are dual-maintained. When updating complexity-gate criteria, the four distinctness axes, the minimum-proposal count, or any other rule below, you MUST update `agents/approach-proposer.md` in the same change to keep the two in sync. The structural test pins wiring + summary presence but does not detect semantic drift between this SKILL.md block and the agent's embedded protocol.

**Contract summary** (the agent enforces these; this block is the human-readable contract surface for SKILL.md readers and is pinned by `tests/scripts/test-implementation-plan-proposals.sh`):

- **Minimum count**: the agent must produce **at least 3 distinct proposals**. Fewer is permitted only when the solution space is genuinely constrained (≥ 2 required); the constraint must be documented in `generation_notes`.
- **Proposal schema** (six required fields per `prompts/proposal-schema.md`): `title`, `description`, `files`, `pros`, `cons`, `risk` (one of `low` / `medium` / `high`).
- **Distinctness validation gate**: every pair of proposals must differ on at least one of the four structural axes:
  - **data layer** — where state is stored or retrieved
  - **control flow** — execution path or orchestration strategy
  - **dependency graph** — modules, packages, or services introduced or removed
  - **interface boundary** — where the public contract is drawn
  A set with any structurally equivalent pair MUST NOT be emitted by the agent. The agent records pairwise comparisons in `distinctness_summary` so the audit trail proves the gate ran.
- **Complexity gates** (per `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/complexity-gate.md`): every proposal is gated through Gate 1 (YAGNI), Gate 2 (Rule of Three), and Gate 3 (new-dependency) with outcomes recorded in `complexity_gate_summary`.

Read `shared/prompts/complexity-gate.md` to confirm it is present. If unreadable, STOP and emit:
"ERROR: complexity-gate.md not found at skills/shared/prompts/complexity-gate.md — create this file before running implementation-plan."

Dispatch via `subagent_type: "dso:approach-proposer"` with `model: "opus"` passed explicitly (do not rely on the agent frontmatter default — distinct-approach reasoning, complexity-gate evaluation, and structural-axis analysis depend on opus-level sustained reasoning, and the explicit param defends against future routing changes that might silently downgrade).

**Two distinct fallback concepts — do not conflate:**

- **Dispatch-target fallback** (this paragraph): if the named `subagent_type: "dso:approach-proposer"` is unregistered in this session ("Unknown agent type" or similar dispatch error), re-dispatch with `subagent_type: "general-purpose"` + `model: "opus"` and `agents/approach-proposer.md` content read inline as the prompt. **The agent still does the work** — only the dispatch transport changes. This is NOT inline drafting.
- **Inline-drafting fallback** (forbidden, see Validation below): the orchestrator itself drafts proposals without the agent. This is the bug class the dispatch was introduced to eliminate and is explicitly prohibited regardless of what dispatch path was taken.

Pass the following as task arguments:

- `{story-id}`, `{story-title}`, `{story-description}` from the story ticket
- `{story-done-definitions}` — the story's DDs, one per line, with stable identifiers (`dd-1`, `dd-2`, ...). Parse these from the story description's `## Done Definitions` section; do NOT rely on session memory.
- `{codebase-context}` — discovery output from Step 1 (relevant files, existing patterns, architectural reviewer findings, walking-skeleton flags)
- `{counter-proposal-feedback}` — if NEW_COUNT ≥ 1, the prior counter-proposal's `approach` and `done_definitions` from the cycle state file; otherwise pass `(none — first cycle)`

The agent returns a JSON object with `proposals`, `distinctness_summary`, `complexity_gate_summary`, and `generation_notes`. Validate the output in this order — do NOT reorder, the model-requirement check MUST run before schema validation:

<!-- VALIDATION-ORDER: model_requirement_unmet → domain-error escalation → schema validation. -->
<!-- VALIDATION-STEP-1: model_requirement_unmet -->
<!-- EMIT-PRECONDITIONS: gate_name=implementation_plan_approach_proposer_model_retry degradation_type=inferred_decision -->
1. **Model-requirement check (first)**: if the response carries `"error": "model_requirement_unmet"`, log `"Approach proposer model requirement unmet — re-dispatching with explicit model: opus"` and retry once via the fallback path. If the retry also returns `model_requirement_unmet`, HALT with diagnostic: `"Approach proposal generation requires opus; configure the environment to allow opus dispatch and re-run /dso:implementation-plan."` Do NOT fall back to inline proposal drafting.
<!-- VALIDATION-STEP-1.5: domain-error-escalation -->
2. **Domain-error escalation (second)**: if the response carries `"error": "insufficient_solution_space"` (documented in `agents/approach-proposer.md`), this is a legitimate signal that the story is genuinely constrained to fewer than 2 viable approaches — NOT a malformed response. Surface the agent's `generation_notes` to the user and HALT with diagnostic: `"Approach proposer: insufficient_solution_space — <generation_notes joined>. Refine the story constraints (or accept the single-approach path manually) and re-run /dso:implementation-plan."` Do NOT proceed to schema validation; an empty `proposals` array under this error code is the intended shape.
<!-- VALIDATION-STEP-2: schema-validation -->
3. **Schema validation (third)**: with both error-envelope branches ruled out, validate that `proposals` conforms to `prompts/proposal-schema.md` (every proposal has all six fields), `distinctness_summary` is a non-empty array of pairwise comparisons (every pair has `differs_on` non-empty), and `complexity_gate_summary` has one entry per proposal with all three gate outcomes recorded. If schema validation fails, HALT with diagnostic: `"Approach proposer returned malformed output; cannot proceed without verified proposals."` Do NOT fall back to inline drafting — inline drafting is the failure mode this phase exists to prevent.  <!-- precondition-emit-ok: negation — HALT, no degradation event -->
<!-- EMIT-PRECONDITIONS landmark above (line 329) also covers this section per the within-10-lines rule. -->


**Why halt (not skip-and-continue) here?** Proposal generation is a **correctness gate**: the selected approach drives every subsequent task in Step 3, and inline orchestrator drafting (the only available fallback) is the bug class this dispatch was introduced to eliminate.

**Approach resolution routing** (config-driven via `APPROACH_RESOLUTION`):

- **`autonomous`** (default): pass the agent's full `proposals` set to the decision-maker; use the selected proposal as the basis for Step 3. Do NOT show proposals to the user or wait for selection.
- **`interactive`**: display the agent's `proposals` to the user (title, description, pros, cons, risk); wait for user selection before Step 3. Do NOT dispatch the decision-maker.

### Resolution Loop

After generating a valid distinct proposal set, dispatch `dso:approach-decision-maker` to evaluate and select.

#### Cycle State

```bash
CYCLE_COUNT=$(bash "$PLUGIN_SCRIPTS/implementation-plan/approach-cycle-state.sh" read "$STORY_ID")  # shim-exempt: internal orchestration script
```

State file `/tmp/approach-resolution-${STORY_ID}.json` (4h TTL); stale files reset to 0 automatically.

#### Dispatch

Dispatch `dso:approach-decision-maker` (subagent_type, model: opus, timeout: 600000) with:
- All proposals (full set with title, description, files, pros, cons, risk)
- Story success criteria and done definitions
- Current codebase context

**Inline fallback**: if the Agent tool rejects the subagent type ("Unknown agent type", "not supported", or any pre-run dispatch failure), read `agents/approach-decision-maker.md` inline and execute its evaluation directly with the same inputs. The inline path must still produce a valid `APPROACH_DECISION:` output conforming to `docs/contracts/approach-decision-output.md`.

#### Parse Response

Scan output for the `APPROACH_DECISION:` prefix per `docs/contracts/approach-decision-output.md`. Extract the JSON block between ` ```json ` and ` ``` ` fences. Validate `mode`.

If output is absent, malformed, missing the prefix, or has an unrecognized `mode`: log a warning and surface to the user for manual selection. Do NOT autonomously fall back to any proposal.

#### Accept Path (`mode: "selection"`)

1. Read `selected_proposal_index`; extract the corresponding proposal.
2. Log the ADR rationale (`context`, `decision`, `consequences`, `rationale_summary`).
3. Autonomous mode: proceed directly to Step 3 with the selected proposal. Interactive mode: present selection and rationale; confirm before Step 3.
4. Clear cycle state: `bash "$PLUGIN_SCRIPTS/implementation-plan/approach-cycle-state.sh" clear "$STORY_ID"`.  # shim-exempt: documentation reference in skill prompt

#### Revise Path (`mode: "counter_proposal"`)

```bash
NEW_COUNT=$(bash "$PLUGIN_SCRIPTS/implementation-plan/approach-cycle-state.sh" increment "$STORY_ID")  # shim-exempt: internal orchestration script
```

If `NEW_COUNT <= 2`: incorporate the counter-proposal's `approach` and `done_definitions` as additional constraints; return to Proposal Generation with explicit guidance (new proposals must satisfy the original SC AND the counter-proposal's requirements); re-enter the Resolution Loop. If `NEW_COUNT > 2`: Escalate Path.

In interactive mode, briefly note that the decision-maker requested revisions and the loop is retrying.

#### Escalate Path (after 2 cycles)

Present:
- All proposals from the most recent generation
- All counter-proposal feedback across cycles (from state file + current agent output)
- Summary: "The decision-maker could not reach a satisfactory selection after 2 cycles. Please review the proposals and counter-proposal feedback, then select an approach manually."

In autonomous mode, emit `STATUS:blocked REASON:approach_escalated_to_user STORY:<story-id>` and pause. Do NOT proceed autonomously. After user selects, clear cycle state.

---

## Step 2: Consistency & Architectural Review

If the implementation does not require a new pattern (or modification to an existing one), skip to Step 3.

If a pattern change is proposed, read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md` inline with:

- **subject**: `"Architectural Pattern: {pattern name}"`
- **artifact**: proposed pattern + relevant architecture docs and existing patterns from Step 1
- **pass_threshold**: `4`
- **start_stage**: `1`
- **perspectives**: from reviewer files in `docs/reviewers/architectural/`:
  - [docs/reviewers/architectural/best-practices.md](docs/reviewers/architectural/best-practices.md) — `"Best Practices"`
  - [docs/reviewers/architectural/project-alignment.md](docs/reviewers/architectural/project-alignment.md) — `"Project Alignment"`
  - [docs/reviewers/architectural/justification.md](docs/reviewers/architectural/justification.md) — `"Justification"`

### Remediation Re-dispatch

On Step 2 architectural-reviewer FAIL verdict (i.e., the architectural-review protocol returns a non-passing score after all autonomous resolution cycles), re-dispatch `dso:approach-proposer` with `model: "opus"` on the dispatch payload to generate a revised approach.

Build a `remediation_context` block before dispatching. Pass all artifact file paths by reference (absolute file paths — do not inline file contents). The shape MUST match the schema declared in `${CLAUDE_PLUGIN_ROOT}/agents/approach-proposer.md` under `### Remediation Context (optional)`:

```json
{
  "remediation_context": {
    "reviewer_artifact_paths": [
      "<absolute path to reviewer-findings.json from the failing review cycle>",
      "<absolute path to the original approach proposal artifact>"
    ],
    "findings": [
      {
        "target": "<proposal-N id that triggered the FAIL verdict, or 'n/a' for set-wide concerns>",
        "description": "<verbatim evidence quote from reviewer findings — copy the exact reviewer text that triggered the FAIL verdict>"
      }
    ],
    "target_story_id": "<story id this delta cycle is scoped to>"
  }
}
```

The orchestrator-level dispatch operates in `mode: remediation` — i.e., the presence of `remediation_context` activates `dso:approach-proposer`'s DELTA OUTPUT MODE and produces only the changed proposals rather than a full regeneration. Do NOT add a `mode` field inside the `remediation_context` object itself (the schema does not declare it).

Also pass the following scratch namespacing args so the sub-agent can write its output via the scratch store:

- `SCRATCH_TICKET_ID`: The story ticket id for this implementation-plan run — the sub-agent uses this to namespace the scratch write.
- `SCRATCH_KEY`: The literal string `implementation-plan:step2:arch-review-draft` — the sub-agent uses this as the scratch key when writing its output.

**Sub-agent output contract** (include verbatim in the dispatched prompt):

```xml
<output_contract>
You MUST write your full JSON output (proposals, distinctness_summary, complexity_gate_summary,
generation_notes) to the ticket scratch store before returning, using the SCRATCH_TICKET_ID and
SCRATCH_KEY values provided:

  bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" set "$SCRATCH_TICKET_ID" "$SCRATCH_KEY" "<your-json-output>"

After writing, return ONLY a 3-field receipt JSON — do NOT embed the draft body in your return block:

  {"ticket_id": "<SCRATCH_TICKET_ID>", "key": "<SCRATCH_KEY>", "byte_count": <N>}

where byte_count is the byte length of the JSON payload you wrote.

NEGATIVE EXAMPLE (contract violation — do NOT do this):
  {"ticket_id": "...", "key": "...", "byte_count": 4096, "proposals": [...]}
  ^^^ Extra fields beyond the 3-field envelope are a contract violation and will
      cause RECEIPT_PARSE_ERROR on the orchestrator side.

NEGATIVE EXAMPLE (contract violation — do NOT do this):
  Here are the revised proposals: proposals: [...], distinctness_summary: [...]
  ^^^ Returning the draft body inline (not via scratch) is a contract violation.
      A SCRATCH_MISS on the orchestrator side is NOT a fallback signal to send
      the payload inline — it is a hard error requiring the agent to be re-dispatched.
</output_contract>
```

After receiving the revised proposals, re-enter the Resolution Loop from Dispatch with the new proposal set. If the re-dispatched approach-proposer returns `model_requirement_unmet`, apply the same retry-once rule as in the Proposal Generation section.

Record exactly one `.claude/scripts/dso ticket comment <id> "REMEDIATION_CYCLE:<N> approach-proposer re-dispatched after Step 2 FAIL"` per cycle per SC5 single-comment policy.

**Fallback**: if the review fails after autonomous resolution (`review.max_cycles`, default: 4) and user escalation, revert to existing patterns and note the unresolved concern. If no existing pattern solves the story, halt and consult the user.

**Remediation loop protocol (Step 2 — architectural review re-dispatch)**

When `dso:approach-proposer` returns revised proposals after a Step 2 FAIL verdict, the orchestrator enters a remediation loop governed by the shared protocol. Source `MAX_CYCLES` from `get_max_remediation_cycles()` in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` before entering the loop.

**Per-cycle declaration**: At the start of every remediation cycle, emit exactly:
`Current cycle: N of MAX_CYCLES`
where `N` is the 1-based cycle counter and `MAX_CYCLES` is the resolved maximum. This line is required before any findings, deltas, or token emissions within that cycle.

**Oscillation-check hard gate (cycle >= 2)**: On any cycle where `N >= 2`, the orchestrator MUST invoke `/dso:oscillation-check` (Skill) before proceeding with findings analysis. Skipping this gate requires an explicit `OSCILLATION_CHECK_SKIPPED: <reason>` ticket comment capturing the rationale; no other skip reason is permitted.

**Mid-loop success exit**: If the revised proposals pass architectural review on any cycle (before reaching `MAX_CYCLES`), the loop exits immediately and Step 2 proceeds to Step 3. No terminal token is emitted on success.

**HALT-vs-REPLAN exclusivity check**: `REPLAN_ESCALATE` MUST be emitted IFF `cycle_count == MAX_CYCLES AND findings non-empty`. No other condition may emit `REPLAN_ESCALATE`. All other terminal states use a different token — human-input required → `HALT_FOR_USER`; oscillation detected → `OSCILLATION_HALT`; illegal state transition → `PROTOCOL_ERROR`. Emitting `REPLAN_ESCALATE` under any other condition, or emitting it together with `PROTOCOL_ERROR`, is itself a `PROTOCOL_ERROR`.

**Terminal REPLAN_ESCALATE**: On cycle `MAX_CYCLES` with findings still non-empty, emit (per the canonical `${CLAUDE_PLUGIN_ROOT}/docs/contracts/replan-escalate-signal.md` colon-space prefix):
`REPLAN_ESCALATE: planner_supplied EXPLANATION:<explanation text>`
The upstream for implementation-plan Step 2 is `planner_supplied` (per the upstream enum in Section 6 of the protocol doc). Emit this as a standalone ticket comment so the orchestrator's parent session can detect and route the escalation. The literal prefix `REPLAN_ESCALATE: ` (colon followed by a single space) and the `EXPLANATION:` field label are fixed by contract — do not vary them.

**PROTOCOL_ERROR on invariant violation**: Any illegal state transition — emitting `REPLAN_ESCALATE` when `cycle_count < MAX_CYCLES`, emitting multiple terminal tokens, or violating the HALT-vs-REPLAN exclusivity invariant — MUST emit `PROTOCOL_ERROR` and halt remediation immediately.

See: `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md`

**Parse Output (Receipt-Only Contract — Step 2 cycle recorder)**

After the sub-agent returns, validate its receipt via `receipt-parse.sh` before reading any payload:

```bash
# Prompt Alignment Finding 1: receipt validation co-located with the read site
PARSE_RESULT=$(printf '%s' "<sub-agent-return-block>" | \
    bash "$PLUGIN_SCRIPTS/receipt-parse.sh" implementation-plan:step2 dso:approach-proposer)
PARSE_EXIT=$?
if [ "$PARSE_EXIT" -ne 0 ]; then
    # RECEIPT_PARSE_ERROR — halt workflow; structured error already logged to stderr by receipt-parse.sh
    # Inline cleanup: remove any partial scratch written before the failure
    bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID" "implementation-plan:step2:arch-review-draft" 2>/dev/null || true
    echo "HALT: approach-proposer returned a malformed receipt — see RECEIPT_PARSE_ERROR above. Re-dispatch the sub-agent to fix the return contract before continuing." >&2
    exit 1
fi
# Extract ticket_id and key from the validated receipt
SCRATCH_TICKET_ID_OUT=$(echo "$PARSE_RESULT" | awk '{print $1}')
SCRATCH_KEY_OUT=$(echo "$PARSE_RESULT" | awk '{print $2}')

# Retrieve the payload from scratch
SCRATCH_RESULT=$(bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" get "$SCRATCH_TICKET_ID_OUT" "$SCRATCH_KEY_OUT")
SCRATCH_STATUS=$(echo "$SCRATCH_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")

# Prompt Alignment Finding 1: SCRATCH_MISS guard co-located with the get call
if [ "$SCRATCH_STATUS" != "hit" ]; then
    # SCRATCH_MISS — hard error; do NOT fall back to accepting inline payload  # precondition-emit-ok: negation, no degradation event
    # Inline cleanup: no payload to remove, but clear any stale key
    bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID_OUT" "$SCRATCH_KEY_OUT" 2>/dev/null || true
    echo "HALT: scratch key '$SCRATCH_KEY_OUT' not found for ticket '$SCRATCH_TICKET_ID_OUT' (status=$SCRATCH_STATUS). A SCRATCH_MISS is not a signal to accept an inline payload — re-dispatch the sub-agent." >&2
    exit 1
fi
ARCH_REVIEW_JSON=$(echo "$SCRATCH_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
# Clear scratch after successful read
bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID_OUT" "$SCRATCH_KEY_OUT" 2>/dev/null || true
```

After retrieving the arch-review payload, record the cycle artifact via the recorder:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/append_review_cycle.py \
  --artifact <path-to-architectural-review-artifact-for-step2> \
  --n <cycle-number> \
  --draft-hash <sha256 of DELTA OUTPUT block> \
  --findings-count <int> \
  --verdict <pass|fail|escalate>
```

After the append, emit exactly ONE ticket comment per cycle:

```bash
.claude/scripts/dso ticket comment <ticket-id> "Remediation cycle <n> recorded; arch-review draft stored under implementation-plan:step2:arch-review-draft"
```

**Single-comment policy (SC5)**: The ticket comment references the scratch key and does NOT duplicate the cycle body — cycle entries live in the scratch payload, not in ticket comments. One comment per cycle; no further detail in the comment body.

---

## Step 3: Atomic Task Drafting (via `dso:task-decomposer` opus sub-agent)

Draft tasks that **collectively fulfill all done definitions** of the User Story. If a new pattern was approved in Step 2, include consistency tasks. Task drafting is delegated to the `dso:task-decomposer` sub-agent; the orchestrator collects inputs, dispatches, validates output, then proceeds to Step 4 with the resulting draft set.

### Dispatch

Dispatch via `subagent_type: "dso:task-decomposer"` with `model: "opus"` passed explicitly.

**Two distinct fallback concepts — do not conflate:**

- **Dispatch-target fallback** (this paragraph): if the named `subagent_type: "dso:task-decomposer"` is unregistered ("Unknown agent type" or similar dispatch error), re-dispatch with `subagent_type: "general-purpose"` + `model: "opus"` and `agents/task-decomposer.md` content read inline as the prompt. **The agent still does the work** — only the dispatch transport changes. This is NOT inline drafting.
- **Inline-drafting fallback** (forbidden, see Validation below): the orchestrator itself drafts tasks without the agent. This is the bug class the dispatch was introduced to eliminate and is explicitly prohibited regardless of what dispatch path was taken.

Pass the following as task arguments:

- `{story-id}`, `{story-title}`, `{story-description}` from the story ticket
- `{story-done-definitions}` — the story's DDs with stable identifiers (`dd-1`, `dd-2`, ...). Parse from the story description's `## Done Definitions` section.
- `{selected-approach}` — the proposal selected by `dso:approach-decision-maker` (full proposal: title, description, files, pros, cons, risk)
- `{file-impact-table}` — the orchestrator's enumeration from "File Impact Enumeration" below (every file × action × test-classification)
- `{project-commands}` — `commands.test_unit`, `commands.lint`, `commands.format_check` from `dso-config.conf` (verbatim)
- `{testing-mode}` — the story's testing-mode classification (RED / GREEN / UPDATE; default RED)

The agent returns a JSON object with `dd_partition_map`, `task_drafts`, and `decomposition_notes`. Validate in this order — do NOT reorder:

<!-- VALIDATION-ORDER: model_requirement_unmet → domain-error escalation → schema validation. -->
<!-- VALIDATION-STEP-1: model_requirement_unmet -->
<!-- EMIT-PRECONDITIONS: gate_name=implementation_plan_task_decomposer_model_retry degradation_type=inferred_decision -->
1. **Model-requirement check (first)**: if the response carries `"error": "model_requirement_unmet"`, log `"Task decomposer model requirement unmet — re-dispatching with explicit model: opus"` and retry once via the fallback path. If the retry also returns `model_requirement_unmet`, HALT with diagnostic: `"Task decomposition requires opus; configure the environment to allow opus dispatch and re-run /dso:implementation-plan."` Do NOT fall back to inline task drafting.
<!-- VALIDATION-STEP-1.5: domain-error-escalation -->
2. **Domain-error escalation (second)**: if the response carries `"error": "decomposition_blocked"` (documented in `agents/task-decomposer.md`), this is a legitimate signal that the inputs are insufficient or contradictory — NOT a malformed response. Surface the agent's `decomposition_notes` to the user and HALT with diagnostic: `"Task decomposer: decomposition_blocked — <decomposition_notes joined>. Re-supply the missing input (selected approach, file impact table, or story DDs) and re-run /dso:implementation-plan."` Do NOT proceed to schema validation; empty `task_drafts` / `dd_partition_map` arrays under this error code are the intended shape.
<!-- VALIDATION-STEP-2: schema-validation -->
3. **Schema validation (third)**: with both error-envelope branches ruled out, validate that `dd_partition_map` covers every story DD (union of all `owning_task_ids` is non-empty for every DD, and there are no duplicate ownerships unless explicitly sub-partitioned in `decomposition_notes`); `task_drafts` is a non-empty array with the required fields per the agent's output spec; **every task's `description` field begins with a literal `## Story DD Coverage` section header (verbatim — the completeness reviewer's `dd_collective_ac_coverage` audit greps for this exact heading; a missing header silently invalidates the audit)**; every task's first three `acceptance_criteria` lines are the Universal Criteria using the project commands verbatim; every task whose `testing_mode` is `RED` has a `tdd_test_spec` Given/When/Then sentence. If schema validation fails, HALT with diagnostic: `"Task decomposer returned malformed output; cannot proceed without verified drafts."` Do NOT fall back to inline drafting — inline drafting is the failure mode this dispatch exists to prevent.  <!-- precondition-emit-ok: negation — HALT, no degradation event -->
<!-- EMIT-PRECONDITIONS landmark above (line 445) also covers this section per the within-10-lines rule. -->


**Why halt (not skip-and-continue) here, while Step 6 Gap Analysis falls through on failure?** Task decomposition is a **correctness gate**: every subsequent step (Plan Review, Task Creation, Gap Analysis) consumes the draft set, and inline orchestrator drafting (the only available fallback) is the bug class this dispatch eliminates. Step 6 Gap Analysis is a **quality gate** with a defined skip path — losing it degrades coverage but does not break downstream steps.

The sub-sections below **mirror the rules embedded in `agents/task-decomposer.md`**. They are kept here for human reference and for the orchestrator's input-construction step (file impact enumeration in particular). The agent does NOT load them at dispatch time — it carries its own embedded protocol. When updating gate criteria, AC-library instructions, or sequencing rules below, you MUST update `agents/task-decomposer.md` in the same change to keep the two in sync. The orchestrator itself does not draft tasks inline; it only enumerates the file impact table (which the agent consumes), validates the agent's output, and proceeds to Step 4.

### Directives

* **TDD First** — every task must specify a concrete failing test to write first.
* **3-Gate Granularity** — every task must pass all three gates conjunctively. Gate 3 only mandates splitting when the split would not violate Gate 1 or Gate 2.
    * **Gate 1 — Testable Behavior**: the task must produce testable behavior. Grepping a source file to verify code exists is not a valid test. A valid test executes the code and asserts on output, exit code, or side effects.
    * **Gate 2 — Codebase Green**: after committing only this task, all tests pass and the system is deployable. Tasks must never require being committed together. A task that deploys an inert feature (a guard reading files no one writes yet) is acceptable — inert is not broken.
    * **Gate 3 — Maximum Granularity**: it must not be possible to split into smaller tasks each meeting Gate 1 and Gate 2. If two changes within a task each produce independently verifiable behavior and each leaves the codebase green on its own, they must be separate tasks. Bundling is acceptable only when splitting would violate Gate 1 (neither half produces testable behavior alone) or Gate 2 (intermediate broken state — e.g., a rename across import sites).
* **Acceptance Criteria** — every task must include AC passed via `-d/--description` at creation time, composed from `${CLAUDE_PLUGIN_ROOT}/docs/ACCEPTANCE-CRITERIA-LIBRARY.md`. Read the library once at the start of Step 3. For each task:
  1. Start with Universal Criteria (always included)
  2. Select applicable category blocks based on task type
  3. Fill in parameterized slots ({path}, {ClassName}, {N}, etc.)
  4. Add task-specific criteria not covered by templates
  5. Every criterion must include a `Verify:` command that returns exit 0 on pass.
* **Sequential Order**:
    1. Data Model Updates — backward compatible (nullable fields, defaults).
    2. API/Service Updates — backward compatible (versioning or optional parameters).
    3. UI/Frontend Updates — consume the new API/version.
    4. Cleanup — remove legacy fields, deprecated API versions, or bridge code.

### File Impact Enumeration

Before drafting tasks, enumerate every file the story affects. Produces an auditable **file impact table** mapping each source file to its change action, associated tests, and test classification. The table drives task type selection in TDD Task Structure.

1. **List affected source files** via Glob/Grep, tracing from entry points through all layers.

   **Prefer `sg` (ast-grep) for cross-file dependency discovery** — syntax-aware. Guard:

   ```bash
   if command -v sg >/dev/null 2>&1; then
       sg --pattern 'import $MODULE' --lang python .
       sg --pattern 'from $MODULE import $_' --lang python .
   else
       grep -r 'import <module>' .
   fi
   ```

2. **Find associated tests** for each source file:
   - **Fuzzy match** (preferred):
     ```bash
     source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/fuzzy-match.sh
     fuzzy_find_associated_tests <src_file> <repo_root>
     ```
   - **`.test-index` lookup**: format `source/path.ext: test/path1.ext, test/path2.ext`.
   - Union both result sets.

3. **Classify each test** by what the story does to the source:

   **Non-executable instruction files are always `still-valid`** — before applying the table, identify any file that is an LLM instruction document: SKILL.md, agent definitions (files in `agents/`), prompt files (files in `prompts/`), workflow docs (`.md` prose files in `docs/` — excludes schemas, specs, configs, or any executable artifact stored under `docs/`), hook guidance, CLAUDE.md, or other `.md` prose files with no executable code. Per behavioral-testing-standard Rule 5, these files cannot be deterministically tested for behavioral correctness. Always classify them as `still-valid` regardless of the change action — `create`, `modify`, or `remove`. Do NOT produce a RED or UPDATE test task for instruction file changes. If the Doc-Only Skip Gate (above) should have caught a purely-instruction story, apply it retroactively here.

   | Source change action | Test classification |
   |---------------------|---------------------|
   | `create` (new source file) | `needs-creation` — write a new test file |
   | `modify` (behavior change) | `needs-modification` — update existing test(s) |
   | `remove` (source deleted) | `needs-removal` — remove or prune tests |
   | `modify` (no behavior change, e.g., refactor) | `still-valid` — existing tests remain correct |
   | any action on non-executable instruction file | `still-valid` — no test task ever needed |

4. **Build the file impact table**:

   | Source file | Action | Associated tests | Test classification |
   |-------------|--------|-----------------|---------------------|
   | `src/foo.py` | modify | `tests/test_foo.py` | needs-modification |
   | `src/bar.py` | create | *(none yet)* | needs-creation |
   | `src/legacy.py` | remove | `tests/test_legacy.py` | needs-removal |
   | `src/util.py` | modify | `tests/test_util.py` | still-valid |

`still-valid` requires no test task. `needs-modification` → modify-existing-test RED task. `needs-removal` → remove-test task. `needs-creation` → create-test RED task.

### Consumer Detection Pass

For every file in the impact table whose action is `modify` or `remove`, run a downstream consumer detection pass to identify callers/callsites outside the immediate task scope.

**Prefer `sg` over text grep** — syntax-aware. Guard:

```bash
if command -v sg >/dev/null 2>&1; then
    sg --pattern '$FUNC($$$)' --lang python . | grep -F '<symbol_name>'
    sg --pattern '<symbol_name>($$$)' --lang python .
else
    grep -rn '<symbol_name>(' .
fi
```

When external consumers are found, document them in the task's File Impact section with one disposition:

- **Update** — change the external callsite in this task; add the consumer file with action `modify` and pull its tests in.
- **Accept the breaking change** — record the rationale and link the consumer's owner story or follow-on ticket.

A modify/remove task with un-triaged external consumers is incomplete and must be revised before it leaves Step 3.

### Testing Mode Classification

Each task carries an explicit `testing_mode` field — RED, GREEN, or UPDATE — derived from the file impact table. The classification describes what the code *does* to observable behavior, not what text it adds or removes.

The mode applies to the **source file task** (not the test task). A test task for a RED source file is a "RED test task" but the implementation task for that same file also carries `testing_mode: RED`.

| Source condition | testing_mode | Meaning |
|----------------------|-------------|---------|
| Source action = `create`, classification = `needs-creation` | **RED** | New behavioral content; must have a preceding RED test task |
| Source action = `modify`, behavior changes, `needs-modification` | **UPDATE** | Existing file with observable behavior change; existing tests must be updated to assert new behavior before implementation runs |
| Source action = `modify`, no behavior change (refactor), `still-valid` | **GREEN** | Implementation change only; existing tests remain correct |
| Source action = `remove`, `needs-removal` | **GREEN** | Deleting behavior; remove corresponding tests to keep the suite honest |
| Task matches a recipe capability from the registry | **recipe:** | Mechanical transform; execution delegates to the recipe executor; specify recipe_name, recipe_params, and intent |

**Behavioral framing rule**: testing_mode reflects what the code *does* — observable outputs, decisions, or side effects — not what it *contains*. A refactor that renames internal methods without changing returned values is GREEN regardless of line count.

Emit per task:

```
Task: <task title>
testing_mode: RED | GREEN | UPDATE | recipe:
```

### Recipe Task Type

Assign `testing_mode: recipe:` when a task matches a capability in the recipe registry (from Recipe Consultation in Step 1).

**When to assign recipe:**
- Task is a mechanical, deterministic code transform whose entire behavior is described by a registry `capability_description`
- Examples: adding a parameter to a function signature and updating all callers (`add-parameter`); sorting and deduplicating import statements (`normalize-imports`)
- No judgment about business behavior is required — the transform is fully parameterizable

**When NOT to assign recipe:** feature additions, algorithm changes, API contract decisions, or any task where the "what" requires domain reasoning rather than parameterization.

**Required fields for `recipe:` tasks** (in addition to standard task fields):

```
testing_mode: recipe:
recipe_name: <name field from the registry — e.g., add-parameter>
recipe_params: <key=value pairs for the transform — e.g., function_name=process_request, param_name=timeout, param_type=int, default_value=30>
intent: <natural-language description of this specific transform, derived from capability_description>
```

`recipe:` tasks do not require a preceding RED test task; the recipe executor owns the test contract for mechanical transforms.

### TDD Task Structure

**Behavioral content** is code with conditional logic, data transformation, or decision points — any code where output varies by input or state. Every task adding/modifying behavioral content must have a preceding **RED test task** as a declared dependency before any implementation task.

**A RED test may modify existing tests, not just create new test files.** When a story changes existing behavior, the RED test edits an existing test file to assert the new expected behavior — modifying existing tests is a first-class RED-phase activity.

`testing_mode` maps to TDD task type:

- **RED** → **Create-test task** (source `create`, `needs-creation`): write a new test file asserting expected behavior. Implementation depends on this task.
- **UPDATE** → **Modify-existing-test task** (source `modify` with behavior change, `needs-modification`): update an existing test to assert new behavior. The modified test must fail (RED) before implementation runs because the new behavior does not yet exist. Name the specific file and describe which assertions change.
- **GREEN** (refactor or deletion) → no test task needed; for deletion, optionally a **remove-test task** (source `remove`, `needs-removal`) which may run before or in parallel with the source removal (no behavioral assertion to run RED).

A RED test task:
- Writes a failing test asserting expected behavior.
- Must fail (RED) before the implementation task runs.
- Is a standalone task, not embedded in the implementation task description.
- Uses `TEST_CMD` (resolved from `commands.test`) as the verify command.
- **Must be a behavioral test** — see [Shared Behavioral Testing Standard](../shared/prompts/behavioral-testing-standard.md).
- **Must update `.test-index` with a `[test_function_name]` RED marker** for the source file before committing — the pre-commit test gate blocks commits that include a failing test without a matching RED marker. Required AC:
  ```
  - [ ] `.test-index` updated with RED marker `[<test_function_name>]` for `<source-file>`
    Verify: grep '\[<test_function_name>\]' $(git rev-parse --show-toplevel)/.test-index
  ```

#### Behavioral Test Requirement

RED tests must follow the [Shared Behavioral Testing Standard](../shared/prompts/behavioral-testing-standard.md) — read it before writing any test task.

**Test approach framing**: each task that produces a RED test must include a Given / When / Then test approach sentence:
- **Given**: preconditions and inputs (fixture, initial state)
- **When**: invocation (what the code under test is called with)
- **Then**: observable outcome asserted (return value, exit code, file written, side effect)

If the test approach describes grepping a source file rather than invoking the code under test, the task must be revised to describe a behavioral assertion.

#### Unit Test Exemption Criteria

A task may omit the RED test task dependency only if **all** of the following apply:

1. The code has **no conditional logic** — purely structural (e.g., a class definition with no branching).
2. Any test would be a **change-detector test** — only asserts the code exists, not that it behaves correctly.
3. The task is **infrastructure-boundary-only** — only configuration wiring, dependency injection setup, or module registration with no business logic.

Document all three as a justification requirement in the task description; the plan reviewer validates the exemption in Step 4.

#### Integration Test Task Rule

For tasks crossing an external boundary (database, external API, message queue, file system), include a dedicated **integration test task** verifying the boundary interaction end-to-end. Integration test tasks do not require a RED-first dependency — they may be written after the implementation task.

Omit only if:

1. **existing coverage** — an existing integration test already exercises this boundary in a way that would fail if the task's behavior were broken.
2. **no test environment** — the boundary is unavailable in CI and no suitable mock/contract test is feasible.

Either exemption requires justification documented in the task description and validated by the plan reviewer in Step 4.

**Primary path constraint**: when the story's SC describe a user-facing flow (sign-in, checkout, form submission, browser API call), the integration test must exercise that exact path — not an admin/server-side/CLI bypass that skips user-facing infrastructure (e.g., OAuth browser callback, CSRF validation, session cookie issuance). Document which user-facing path is covered.

### Test Filename Conventions (Fuzzy-Match Compatibility)

The tech-stack-agnostic test gate associates source files with their tests via **fuzzy matching**: source basename normalized (non-alphanumeric stripped, lowercased) and checked as a substring against normalized test basenames.

| Source file | Compatible test filenames |
|-------------|--------------------------|
| `bump_version.py` | `test_bump_version.py`, `test_bumpversion.py` |
| `bump-version.sh` | `test-bump-version.sh`, `test_bumpversion_unit.sh` |
| `auth_service.py` | `test_auth_service.py`, `auth_service_test.go` |
| `parser.ts` | `parser.test.ts`, `parser.spec.ts` |

**Rule**: verify the proposed test filename is fuzzy-match compatible:
1. Normalize source basename: strip all non-`[a-z0-9]`, lowercase (e.g., `bump-version.sh` → `bumpversionsh`).
2. Normalize proposed test basename the same way (e.g., `test-bump-version.sh` → `testbumpversionsh`).
3. Confirm the normalized source string appears as a **substring** of the normalized test string.

**If the test filename would NOT be caught by fuzzy match** (e.g., `test_retry_logic.py` for `connection_handler.py`), the task's AC **must include a `.test-index` entry** as an explicit criterion:

```
- [ ] `.test-index` entry added mapping `<source-file>` to `<test-file>`
  Verify: grep -q '<source-file>' $(git rev-parse --show-toplevel)/.test-index
```

The `.test-index` file is the authorized fallback for unconventional test names; it must be present before commit or the test gate produces a false negative. **Common mistake**: naming a test after a behavior rather than the source file.

### Wireframe Design Decision

When the story involves UI changes:
1. **Design wireframes inline (Recommended)** — create wireframes as part of planning.
2. **Defer wireframes** — only when visual design is not part of the story's scope.

If inline, verify `/dso:preplanning` has run for the parent epic — `dso:ui-designer` is dispatched by preplanning Phase H Step 7 and produces the Design Manifest (spatial layout, SVG wireframe, token overlay) as a `UI_DESIGNER_PAYLOAD`. If no design artifacts exist, re-run `/dso:preplanning <epic-id>` first. Include a wireframe task that references existing design artifacts before implementation tasks. UI implementation tasks depend on the wireframe task.

If deferring, document the rationale (e.g., "Visual design is out of scope — wireframes will come from a dedicated design story").

### E2E Testing Requirement

If the story introduces or modifies user-facing behavior, API endpoints, or cross-component flows, include a dedicated E2E test task:

- **New user flows**: E2E covering happy path and key error states.
- **Modified flows**: update existing E2E; add new tests for new paths.
- **API-only changes**: E2E if the change affects responses consumed by frontend or external clients.
- Place in `tests/e2e/` following existing conventions.
- E2E task depends on all implementation tasks (runs last).

If purely internal, document why E2E coverage is not needed.

### Visual Verification Metadata

When a task's File Impact contains UI files (`.css`, `.js`, `.ts`, `.tsx`, `.html`, `.jinja2`, or files inside component directories), the generated task description MUST declare visual verification:

- Add `requires_visual_verification: true` to the task description.
- Add a Playwright AC: "Run `playwright test` targeting the affected component; verify no visual regression against baseline."

When the task touches no UI files, omit both the field and the Playwright AC entirely (do not emit `requires_visual_verification: false` — absence is the signal).

The sub-agent executing the task is responsible for running Playwright as part of satisfying its AC. The sprint orchestrator does NOT add a separate Playwright dispatch step. The token `requires_visual_verification` is a structural contract surface — use the literal verbatim.

### Documentation Updates

If the story introduces or modifies patterns, conventions, or significant technical decisions, **run the gates in `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/doc-router.md`** to select the target file. Do not infer the target from intuition; the router replaces the legacy heuristic that biased toward CLAUDE.md and away from skill-scoped docs.

If at least one router gate fires, include a documentation task. The task MUST:

- **State which router gate fired** (1–5) and the resolved target file in the task description.
- **Set the target per the router**, in order of preference: Gate 1 → `${CLAUDE_PLUGIN_ROOT}/skills/<skill>/SKILL.md`; Gate 2 → existing reference doc (`HOOKS-REFERENCE.md`, `AGENTS.md`, `WORKTREE-GUIDE.md`, `CONFIGURATION-REFERENCE.md`, `CI-INTEGRATION.md`, contract docs, `KNOWN-ISSUES.md`); Gate 3 → `INSTALL.md` / `README.md` / `docs/user/`; Gate 4 → new ADR in `docs/adr/`; Gate 5 → `CLAUDE_MD_SUGGESTED_CHANGE` report only (no direct CLAUDE.md edit).
- **Never name CLAUDE.md as the direct target.** A task that would edit CLAUDE.md must instead emit a `CLAUDE_MD_SUGGESTED_CHANGE` report and route through the orchestrator.
- **Include the attestation requirement** in the task acceptance criteria: the executing sub-agent emits `DOC_ROUTER_ATTESTATION` in its completion report.
- **If `.claude/docs/DOCUMENTATION-GUIDE.md` exists, follow it** for formatting and structure.

If no router gate fires, omit the documentation task and note the rationale (e.g., "doc-router: no gate fired — internal refactor; existing docs remain accurate").

The doc task depends on the implementation tasks it documents and references Step 2 feedback if applicable.

### Contract Detection Pass

After file impact analysis and before finalizing the task list, run a contract detection pass to identify cross-component interfaces needing explicit contracts.

**When to run**: file impact includes two or more components. Skip for purely internal, single-component changes.

**V1 detection heuristics**:

- **Pattern A — Signal emit/parse pairs**: contract needed when one file produces structured output (`STATUS:`, `RESULT:`, `REPORT:` markers) and another component parses/consumes it.
- **Pattern B — Orchestrator/sub-agent report schema**: contract needed when a skill/orchestrator dispatches sub-agents AND defines an expected return format (`CONTRACT_REPORT` or contract report schema). When a dispatcher and a report schema are both in scope, the interface requires a contract artifact.

**Contract artifact**: for each detected interface, create `${CLAUDE_PLUGIN_ROOT}/docs/contracts/<interface-name>.md` with sections: Signal Name, Emitter, Parser, Fields (with types and required/optional), Example (representative payload).

**Cross-Story Deduplication**: before creating a contract task, check the epic for an existing one:

```bash
.claude/scripts/dso ticket deps <parent-epic-id>
```

Scan output for an existing task whose title contains `Contract:` and the same interface name. If found, wire implementation tasks as dependents of that existing task — do not duplicate. Else create:

```bash
.claude/scripts/dso ticket create task "Contract: <interface-name> signal emit/parse interface" --parent=<parent-epic-id> --priority=2
```

**Contract task as first dependency**: declare it as a dependency of all implementation tasks touching either side of the interface.

### Retry Budget

Each implementation task carries a retry budget the orchestrator parses and enforces when dispatching sub-agents.

```
## Retry Budget
MAX_ATTEMPTS: 3 (sonnet model)
On 3 consecutive sonnet failures: escalate to opus with full diagnostic context (all 3 failure messages)
On 3 consecutive opus failures (6 total): escalate to user with full failure history
If MAX_AGENTS: 0 at sonnet→opus escalation time: skip opus step, escalate to user immediately
```

Include this block verbatim in every task description — `MAX_ATTEMPTS` is the integration token sub-agent dispatchers parse for the per-tier attempt cap.

#### Opus Escalation

When sonnet fails `MAX_ATTEMPTS` consecutive times, the orchestrator re-dispatches at opus with full diagnostic context: each failed sub-agent's final report, test output / error messages from each failure, files modified across attempts (with diffs if available), any `RESOLUTION_RESULT` or contract-violation signals. If `MAX_AGENTS: 0` at escalation time, skip opus and go directly to user escalation — opus dispatch is gated by usage capacity.

#### User Escalation

After 6 total consecutive failures (3 sonnet + 3 opus), the orchestrator terminates the autonomous retry loop and escalates to the user with the full history: 6 failed sub-agent reports in chronological order, the diagnostic context passed to opus, a concise summary of attempts and failure reasons, and the current working-tree state. Same path triggers immediately when `MAX_AGENTS: 0` blocks opus dispatch (report contains the 3 sonnet failures plus an explicit note that opus was skipped due to throttling).

### Pattern Reference

When upstream `dso:complexity-evaluator` output specifies `pattern_familiarity: low` or `medium` for a task, enrich the task description with a `## Pattern Reference` block containing up to 30 lines of representative codebase examples. Gives the implementation sub-agent concrete prior art, reducing the chance of inventing a novel pattern.

**Gating**:

- `pattern_familiarity: low` — REQUIRED.
- `pattern_familiarity: medium` — REQUIRED.
- `pattern_familiarity: high` (or no evaluator output) — OMIT entirely.

**Retrieval rules**: local `grep`/`glob` only — no external lookups, no nested LLM calls. Search anchors come from the task's file impact list and the evaluator's identified pattern keywords. Cap at **≤ 30 lines total** across all examples; truncate single examples >30 lines with `# ...`. Cite each example with its source path (e.g., `# from src/utils/example.sh:42-58`).

---

## Step 4: Implementation Plan Review

<HARD-GATE>
Step 4 (Plan Review) is mandatory for every non-TRIVIAL story. There is NO skip path. Do NOT skip or abbreviate plan review for any of the following reasons — each is an explicitly prohibited rationalization:
- "session efficiency" or "we're running long"
- "context pressure" or "token budget concerns"
- "the task-decomposer already validated the plan"
- "the story is small enough" or "the plan is obvious"
- "I already see the gaps" or "plan review is redundant"
- "user authorized 'push through'"

The plan review protocol (REVIEW-PROTOCOL-WORKFLOW.md) is the only authorized mechanism for closing Step 4. After Step 4 completes, tag the story ticket: `.claude/scripts/dso ticket tag <story-id> plan_review:pass` before proceeding to Step 5.
</HARD-GATE>

Read [docs/review-criteria.md](docs/review-criteria.md) for the full reviewer table, launch instructions, score aggregation rules, and conflict detection guidance.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md` inline:

- **subject**: `"Implementation Plan for: {story title}"`
- **artifact**: user story (title + full description) + numbered task list with titles, descriptions, TDD requirements, and dependencies
- **pass_threshold**: `5` (safety-critical — plan must be safe for unsupervised agent execution)
- **start_stage**: `1`
- **perspectives**: from `${CLAUDE_PLUGIN_ROOT}/skills/implementation-plan/docs/reviewers/plan/`:
  - `task-design.md` — `"Task Design"`
  - `tdd.md` — `"TDD"`
  - `safety.md` — `"Safety"`
  - `dependencies.md` — `"Dependencies"`
  - `completeness.md` — `"Completeness"`

  **If any reviewer file cannot be read: HALT immediately. Do NOT synthesize inline perspectives or construct an ad-hoc rubric. Report: "Step 4 blocked: reviewer file `<path>` not found — create the missing reviewer file before proceeding."**

The plan **must** achieve all dimension scores of **5**. The review protocol workflow's revision protocol handles the iteration loop (max 3 cycles). After 3 attempts, present the plan at its current score with remaining issues to the user for judgment.

### Remediation Re-dispatch

On Step 4 plan-reviewer findings (non-empty findings list), re-dispatch `dso:task-decomposer` with literal `model: "opus"` on the dispatch payload to revise the task list in response to reviewer concerns.

Build a `remediation_context` block before dispatching. Pass all artifact file paths by reference (absolute paths — do not inline file contents). The shape MUST match the schema declared in `${CLAUDE_PLUGIN_ROOT}/agents/task-decomposer.md` under `### Remediation Context (optional)`:

```json
{
  "remediation_context": {
    "reviewer_artifact_paths": [
      "<absolute path to reviewer-findings.json from the failing plan review cycle>",
      "<absolute path to the original task plan artifact, if available>"
    ],
    "findings": [
      {
        "target": "<temp_id or existing task id this finding targets, or 'n/a' for set-wide concerns>",
        "description": "<verbatim evidence quote from reviewer findings — copy the exact reviewer text that triggered the finding>"
      }
    ],
    "target_story_id": "<story id this delta cycle is scoped to>"
  }
}
```

The orchestrator-level dispatch operates in `mode: remediation` — i.e., the presence of `remediation_context` activates `dso:task-decomposer`'s DELTA OUTPUT MODE and produces only the changed tasks rather than a full re-decomposition. Do NOT add a `mode` field inside the `remediation_context` object itself (the schema does not declare it).

Delta-mode behavior: the agent will preserve-by-omission — tasks not named in any finding are absent from the delta output but preserved verbatim in the merged set. Only tasks explicitly named in `findings` (via the `target` field) appear in the delta output with the modifications the findings require.

Also pass the following scratch-handoff arguments to the sub-agent:

- `SCRATCH_TICKET_ID`: The story ticket id (the `<story-id>` value for this implementation-plan run) — the sub-agent uses this to namespace the scratch write.
- `SCRATCH_KEY`: The literal string `implementation-plan:step4:plan-review-draft` — the sub-agent uses this as the scratch key when writing its delta output.

**Sub-agent output contract** (include verbatim in the dispatched prompt):

```xml
<output_contract>
You MUST write your full JSON delta output (dd_partition_map, task_drafts, decomposition_notes) to
the ticket scratch store before returning, using the SCRATCH_TICKET_ID and SCRATCH_KEY values
provided:

  bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" set "$SCRATCH_TICKET_ID" "$SCRATCH_KEY" "<your-json-output>"

After writing, return ONLY a 3-field receipt JSON — do NOT embed the draft body in your return block:

  {"ticket_id": "<SCRATCH_TICKET_ID>", "key": "<SCRATCH_KEY>", "byte_count": <N>}

where byte_count is the byte length of the JSON payload you wrote.

NEGATIVE EXAMPLE (contract violation — do NOT do this):
  {"ticket_id": "...", "key": "...", "byte_count": 4096, "task_drafts": [...]}
  ^^^ Extra fields beyond the 3-field envelope are a contract violation and will
      cause RECEIPT_PARSE_ERROR on the orchestrator side.

NEGATIVE EXAMPLE (contract violation — do NOT do this):
  Here are the revised tasks: dd_partition_map: {...}, task_drafts: [...]
  ^^^ Returning the draft body inline (not via scratch) is a contract violation.
      A SCRATCH_MISS on the orchestrator side is NOT a fallback signal to send
      the payload inline — it is a hard error requiring the agent to be re-dispatched.
</output_contract>
```

### Parse Output (Receipt-Only Contract)

After the sub-agent returns, validate its receipt via `receipt-parse.sh` before reading any payload:

```bash
# Prompt Alignment Finding 1: receipt validation co-located with the read site
PARSE_RESULT=$(printf '%s' "<sub-agent-return-block>" | \
    bash "$PLUGIN_SCRIPTS/receipt-parse.sh" implementation-plan:step4 dso:task-decomposer)
PARSE_EXIT=$?
if [ "$PARSE_EXIT" -ne 0 ]; then
    # RECEIPT_PARSE_ERROR — halt workflow; structured error already logged to stderr by receipt-parse.sh
    # Inline cleanup: remove any partial scratch written before the failure
    bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID" "implementation-plan:step4:plan-review-draft" 2>/dev/null || true
    echo "HALT: task-decomposer (Step 4 remediation) returned a malformed receipt — see RECEIPT_PARSE_ERROR above. Re-dispatch the sub-agent to fix the return contract before continuing." >&2
    exit 1
fi
# Extract ticket_id and key from the validated receipt
SCRATCH_TICKET_ID_OUT=$(echo "$PARSE_RESULT" | awk '{print $1}')
SCRATCH_KEY_OUT=$(echo "$PARSE_RESULT" | awk '{print $2}')

# Retrieve the payload from scratch
SCRATCH_RESULT=$(bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" get "$SCRATCH_TICKET_ID_OUT" "$SCRATCH_KEY_OUT")
SCRATCH_STATUS=$(echo "$SCRATCH_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")

# Prompt Alignment Finding 1: SCRATCH_MISS guard co-located with the get call
if [ "$SCRATCH_STATUS" != "hit" ]; then
    # SCRATCH_MISS — hard error; do NOT fall back to accepting inline payload  # precondition-emit-ok: negation, no degradation event
    # Inline cleanup: no payload to remove, but clear any stale key
    bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID_OUT" "$SCRATCH_KEY_OUT" 2>/dev/null || true
    echo "HALT: scratch key '$SCRATCH_KEY_OUT' not found for ticket '$SCRATCH_TICKET_ID_OUT' (status=$SCRATCH_STATUS). A SCRATCH_MISS is not a signal to accept an inline payload — re-dispatch the sub-agent." >&2
    exit 1
fi
DELTA_JSON=$(echo "$SCRATCH_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
```

The retrieved `DELTA_JSON` is a JSON object with `dd_partition_map`, `task_drafts`, and `decomposition_notes`. Merge the delta with the prior cycle's tasks. After merging, clear the scratch key:

```bash
bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID" "implementation-plan:step4:plan-review-draft"
```

After receiving the revised task set, re-enter Step 4 Plan Review with the updated plan. If the re-dispatched task-decomposer returns `model_requirement_unmet`, apply the same retry-once rule as in the Step 3 Dispatch section.

Record exactly one `.claude/scripts/dso ticket comment <id> "REMEDIATION_CYCLE:<N> task-decomposer re-dispatched after Step 4 plan-review findings"` per cycle per SC5 single-comment policy.

**Remediation loop protocol (Step 4 — plan review re-dispatch)**

When `dso:task-decomposer` returns revised tasks after Step 4 plan-review findings, the orchestrator enters a remediation loop governed by the shared protocol. Source `MAX_CYCLES` from `get_max_remediation_cycles()` in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` before entering the loop.

**Per-cycle declaration**: At the start of every remediation cycle, emit exactly:
`Current cycle: N of MAX_CYCLES`
where `N` is the 1-based cycle counter and `MAX_CYCLES` is the resolved maximum. This line is required before any findings, deltas, or token emissions within that cycle.

**Oscillation-check hard gate (cycle >= 2)**: On any cycle where `N >= 2`, the orchestrator MUST invoke `/dso:oscillation-check` (Skill) before proceeding with findings analysis. Skipping this gate requires an explicit `OSCILLATION_CHECK_SKIPPED: <reason>` ticket comment capturing the rationale; no other skip reason is permitted.

**Mid-loop success exit**: If the revised task set passes plan review on any cycle (before reaching `MAX_CYCLES`), the loop exits immediately and Step 4 proceeds to Step 5. No terminal token is emitted on success.

**HALT-vs-REPLAN exclusivity check**: `REPLAN_ESCALATE` MUST be emitted IFF `cycle_count == MAX_CYCLES AND findings non-empty`. No other condition may emit `REPLAN_ESCALATE`. All other terminal states use a different token — human-input required → `HALT_FOR_USER`; oscillation detected → `OSCILLATION_HALT`; illegal state transition → `PROTOCOL_ERROR`. Emitting `REPLAN_ESCALATE` under any other condition, or emitting it together with `PROTOCOL_ERROR`, is itself a `PROTOCOL_ERROR`.

**Terminal REPLAN_ESCALATE**: On cycle `MAX_CYCLES` with findings still non-empty, emit (per the canonical `${CLAUDE_PLUGIN_ROOT}/docs/contracts/replan-escalate-signal.md` colon-space prefix):
`REPLAN_ESCALATE: planner_supplied EXPLANATION:<explanation text>`
The upstream for implementation-plan Step 4 is `planner_supplied` (per the upstream enum in Section 6 of the protocol doc). Emit this as a standalone ticket comment so the orchestrator's parent session can detect and route the escalation. The literal prefix `REPLAN_ESCALATE: ` (colon followed by a single space) and the `EXPLANATION:` field label are fixed by contract — do not vary them.

**PROTOCOL_ERROR on invariant violation**: Any illegal state transition — emitting `REPLAN_ESCALATE` when `cycle_count < MAX_CYCLES`, emitting multiple terminal tokens, or violating the HALT-vs-REPLAN exclusivity invariant — MUST emit `PROTOCOL_ERROR` and halt remediation immediately.

See: `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md`

**Per-cycle artifact append (Step 4 — cycle recorder)**

After each cycle's re-dispatch and review, atomically append a `cycles[]` entry to the plan-review artifact using the writer:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/append_review_cycle.py \
  --artifact <path-to-plan-review-artifact-for-step4> \
  --n <cycle-number> \
  --draft-hash <sha256 of DELTA OUTPUT block> \
  --findings-count <int> \
  --verdict <pass|fail|escalate>
```

After the append, emit exactly ONE ticket comment per cycle:

```bash
.claude/scripts/dso ticket comment <ticket-id> "Remediation cycle <n> recorded at <artifact-path>"
```

---

## Step 5: Task Creation

Once the plan is approved (Score: 5 or user-approved), create tasks in the ticket system.

### Create Tasks

For each task, use the form below. The `-d` flag is required — pass the full task body (testing mode, AC, implementation notes) at creation time. **Do not create the task first and add the body as a comment** — the `description` field is the canonical task spec.

Each task must include:

| Field | Content |
|-------|---------|
| **Title** | Concise and atomic |
| **Description** | Implementation steps, file paths, constraints |
| **TDD Requirement** | Specific failing test to write first |
| **Acceptance Criteria** | Included via `-d/--description` at creation time |

Before creating each task, partition the story's done definitions across all tasks so every DD appears in exactly one task's Story DD Coverage section. Every story DD must be owned by at least one task.

**Closure Checks exclusion**: Items under `## Closure Checks` are excluded from the DD partition. Only done definitions and success criteria from `## Done Definitions` / `## Success Criteria` sections are assigned to tasks.

> **Why**: Closure Checks are verified at story/epic closure by the completion-verifier agent; they are not implementation targets.

```bash
TASK_ID=$(.claude/scripts/dso ticket create task "{title}" --parent=<story-id> --priority=2 -d "$(cat <<'DESCRIPTION'
## Testing Mode
<RED|GREEN|UPDATE>

## Story DD Coverage
This task is responsible for satisfying the following story done definitions:
- DD{N}: {exact done definition text from story}
- DD{M}: {exact done definition text from story}
(List only the DDs this task owns. Omit DDs owned by other tasks in the plan.)

## Acceptance Criteria
- [ ] Unit tests pass (exit 0)
  Verify: TEST_CMD=$(.claude/scripts/dso read-config commands.test_unit) && [ -n "$TEST_CMD" ] && $TEST_CMD
- [ ] Lint passes (exit 0)
  Verify: LINT_CMD=$(.claude/scripts/dso read-config commands.lint) && [ -n "$LINT_CMD" ] && $LINT_CMD
- [ ] Format check passes (exit 0)
  Verify: FORMAT_CHECK_CMD=$(.claude/scripts/dso read-config commands.format_check) && [ -n "$FORMAT_CHECK_CMD" ] && $FORMAT_CHECK_CMD
- [ ] {task-specific criterion 1}
  Verify: {command that returns exit 0 on pass}
- [ ] {task-specific criterion 2}
  Verify: {command}
DESCRIPTION
)" | tail -1)
```

Universal criteria (test, lint, format) are always the first three lines. Task-specific criteria follow, drawn from the template library and customized.

**Declarative-artifact schema rule**: If the task's file impact table includes a declarative configuration file that executes in a remote runtime (`.github/workflows/*.yml`, GitHub Ruleset JSON, Kubernetes manifests, Terraform, cron schedules, OpenAPI specs), add a schema-validation AC bullet immediately after the universal three:

```
- [ ] {Artifact} is schema-valid (exit 0)
  Verify: actionlint .github/workflows/<file>.yml   # or: yamllint, kubectl apply --dry-run=client, terraform validate, JSON-schema check
```

Pair this with the brainstorm executable-artifact SC (live execution / non-blocking landing) — the schema check catches Layer-1 invalidity at task time, the executable-artifact SC catches Layer-2 runtime gaps at epic close.

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

Run `.claude/scripts/dso ticket ready --epic=<story-id>` to confirm which tasks are immediately workable.

Output the parent epic/story ID prominently at the top:

```
Implementation plan for [epic/story ID]: [Title]
```

Output a summary table:

| ID | Title | Priority | Depends On | TDD Test |
|----|-------|----------|------------|----------|
| xxx-001 | Add nullable field... | P1 | - | test_field_exists_and_nullable |
| xxx-002 | Implement service... | P1 | xxx-001 | test_service_returns_expected |

Output a **File Impact Summary** — every file touched across all tasks:

| File | Action | Task(s) |
|------|--------|---------|
| `src/models/user.py` | Edit | xxx-001 |
| `src/services/auth.py` | Create | xxx-002 |
| `tests/unit/test_auth.py` | Create | xxx-002 |
| `src/routes/legacy_login.py` | Remove | xxx-004 |

Actions: **Create**, **Edit**, or **Remove**. Multiple tasks touching the same file = list all task IDs (signals overlap for batch conflict detection).

Report:
- Total tasks created
- File impact summary (above)
- Dependency graph (`.claude/scripts/dso ticket deps <story-id>`)
- Ready tasks (`.claude/scripts/dso ticket ready --epic=<story-id>`)
- Whether documentation/E2E tasks were included and why

**When invoked from `/dso:sprint` (via Skill tool)**: continue immediately to Step 6 (Gap Analysis), then emit STATUS:complete per the Output Protocol. Do not pause.

**When invoked interactively (user-initiated)**: present the summary above and wait for user instructions before implementing.

---

## Step 5b: Behavioral Coverage Cross-Check (intent-fidelity-pipeline Phase 3)

After task creation (Step 5), dispatch a **haiku-tier cross-check sub-agent** to validate that behavioral DDs have behavioral Verify commands — not file-inspection commands masquerading as behavioral tests.

For each DD in the story that has a `verify_commands` entry, the cross-check agent evaluates: does the Verify command invoke the code under test, or does it only check file/string existence?

```
Agent({
  description: "Behavioral coverage cross-check for <story-id>",
  subagent_type: "general-purpose",
  model: "haiku",
  prompt: "You are a behavioral coverage validator. For each DD below, determine whether the Verify command invokes the code under test (PASS) or only checks file/string existence (FAIL).\n\nA command FAILS if it matches any of: grep, find, ls, wc, cat, head, stat, test -f, test -e, [ -f, [ -e, file, du, diff.\nA command PASSES if it invokes a test runner (pytest, make test, npm test, bash test-*.sh, curl) or directly executes the code.\n\nFor each DD, output exactly: dd-N: PASS or dd-N: FAIL\n\n<dd_list_with_verify_commands>"
})
```

**Routing**:
- All DDs PASS → proceed to Step 6
- Any DD FAIL → revise the failing task's Verify command (update via `set-verify-commands`) before Step 6
- Cross-check dispatch fails (haiku unavailable, MAX_AGENTS=0) → log degradation, proceed to Step 6

This step is skipped when the story has no `verify_commands` entries (backward compatibility with pre-Phase-2 stories).

## Step 6: Gap Analysis

Review the complete task list for design gaps that compound during sub-agent execution.

<HARD-GATE>
The TRIVIAL Skip Gate (below) is the ONLY authorized bypass for gap analysis. The plan reviewer in Step 4 evaluates the plan's structural quality (task design, TDD, safety, dependencies, completeness); it does NOT substitute for gap analysis, which is specifically scoped to design gaps that compound during sub-agent execution after tasks are written.

**Anti-rationalization prohibition (bug 2c4d-cac7-40a4-40e2; prior instance: bug 5749-127d).** The following rationales are explicitly prohibited for skipping gap analysis — each has been observed in practice and each is wrong:
- "session efficiency" or "we're running long"
- "context pressure" or "token budget concerns"
- "the plan reviewer already validated coverage"
- "the story is small enough" or "the tasks are obvious"
- "I already see the gaps" — gap analysis is a structured opus sub-agent dispatch, not an inline check
- "user authorized 'push through'"

The more COMPLEX the story, the more session pressure has accumulated to skip — and the higher the cost of doing so. A COMPLEX story with skipped gap analysis is the highest-risk combination in the planning pipeline.

After Step 6 completes (or TRIVIAL skip is confirmed), tag the story ticket: `.claude/scripts/dso ticket tag <story-id> gap_analysis:complete` before emitting STATUS:complete.
</HARD-GATE>

### TRIVIAL Skip Gate

Check the story's complexity classification. When invoked from `/dso:sprint`, the parent story may carry a `COMPLEXITY_CLASSIFICATION: COMPLEX` comment (written by sprint's evaluator). Check via `.claude/scripts/dso ticket show <story-id>` and grep for `COMPLEXITY_CLASSIFICATION`:

<!-- EMIT-PRECONDITIONS: gate_name=implementation_plan_gap_analysis degradation_type=unresolved_question -->
- **`TRIVIAL`** (or clearly simple from context): skip gap analysis entirely. Log: `"Skipping gap analysis — story classified as TRIVIAL"`. Tag: `.claude/scripts/dso ticket tag <story-id> gap_analysis:complete`. Proceed to final summary.
- **`COMPLEX`** or **no classification found** (standalone): run gap analysis. The cost of an unnecessary analysis is low; the cost of a missed gap is high.

### Dispatch Opus Sub-Agent

For COMPLEX stories (or standalone), dispatch an opus sub-agent via the Task tool using `prompts/gap-analysis.md`.

Fill template placeholders:

| Placeholder | Source |
|-------------|--------|
| `{story-title}` | from `.claude/scripts/dso ticket show` |
| `{story-description}` | from `.claude/scripts/dso ticket show` |
| `{task-list-with-descriptions}` | full task list: titles, descriptions, TDD requirements, AC |
| `{dependency-graph}` | `.claude/scripts/dso ticket deps <story-id>` |
| `{file-impact-summary}` | File Impact Summary table from Step 5 |

### Parse Findings

Parse the JSON `findings` array. For each finding:

- **`type: "new_task"`**: create via `.claude/scripts/dso ticket create` with finding's title and description, parent set to the story, dependency on the appropriate existing task(s); add to summary table.
- **`type: "ac_amendment"`**: append via `.claude/scripts/dso ticket comment <target_task_id> "AC amendment: <description>"`.

### Fallback

If the sub-agent times out, returns malformed JSON, or fails for any reason:

1. Log: `"Gap analysis sub-agent failed: <error> — continuing without gap findings"`.
2. Do NOT block the implementation plan.
3. Proceed to summary with a note that gap analysis was not completed.

### Summary Update

Add a **Gap Analysis Results** section:

| Outcome | Summary Line |
|---------|-------------|
| TRIVIAL skip | `Gap Analysis: Skipped (TRIVIAL classification)` |
| No gaps found | `Gap Analysis: Complete — no gaps found` |
| Gaps found | `Gap Analysis: {N} findings — {X} new tasks created, {Y} AC amendments` |
| Sub-agent failed | `Gap Analysis: Failed (non-blocking) — <error summary>` |

### Return Control to Sprint Orchestrator

**When invoked from `/dso:sprint`**: after updating the summary, emit STATUS:complete per the Output Protocol. Do not wait for user input. Do not halt the session — STATUS:complete is a return value for the sprint orchestrator to parse; the orchestrator continues autonomously.

### Remediation Re-dispatch

On Step 6 gap-analysis findings (non-empty findings from the gap-analysis opus sub-agent that target existing tasks), re-dispatch `dso:task-decomposer` with literal `model: "opus"` on the dispatch payload to revise affected tasks in response to gap-analysis concerns.

Build a `remediation_context` block before dispatching. Pass all artifact file paths by reference (absolute paths — do not inline file contents). The shape MUST match the schema declared in `${CLAUDE_PLUGIN_ROOT}/agents/task-decomposer.md` under `### Remediation Context (optional)`:

```json
{
  "remediation_context": {
    "reviewer_artifact_paths": [
      "<absolute path to gap-analysis-<story-id>.json written by the gap-analysis sub-agent>",
      "<absolute path to the task plan artifact from Step 5, if available>"
    ],
    "findings": [
      {
        "target": "<temp_id or existing task id this finding targets, or 'n/a' for set-wide concerns>",
        "description": "<verbatim evidence quote from gap-analysis findings — copy the exact finding text that triggered the remediation>"
      }
    ],
    "target_story_id": "<story id this delta cycle is scoped to>"
  }
}
```

The orchestrator-level dispatch operates in `mode: remediation` — i.e., the presence of `remediation_context` activates `dso:task-decomposer`'s DELTA OUTPUT MODE and produces only the changed tasks rather than a full re-decomposition. Do NOT add a `mode` field inside the `remediation_context` object itself (the schema does not declare it).

Delta-mode behavior: the agent will preserve-by-omission — tasks not named in any finding are absent from the delta output but preserved verbatim in the merged set. Only tasks explicitly named in `findings` (via the `target` field) appear in the delta output with the modifications the findings require.

After receiving the revised task set, merge the delta with the prior cycle's tasks and re-enter Step 6 Gap Analysis only if the gap-analysis sub-agent flagged structural issues requiring re-analysis; otherwise proceed to summary update. If the re-dispatched task-decomposer returns `model_requirement_unmet`, apply the same retry-once rule as in the Step 3 Dispatch section.

Record exactly one `.claude/scripts/dso ticket comment <id> "REMEDIATION_CYCLE:<N> task-decomposer re-dispatched after Step 6 gap-analysis findings"` per cycle per SC5 single-comment policy.

**Remediation loop protocol (Step 6 — gap analysis re-dispatch)**

When `dso:task-decomposer` returns revised tasks after Step 6 gap-analysis findings, the orchestrator enters a remediation loop governed by the shared protocol. Source `MAX_CYCLES` from `get_max_remediation_cycles()` in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` before entering the loop.

**Per-cycle declaration**: At the start of every remediation cycle, emit exactly:
`Current cycle: N of MAX_CYCLES`
where `N` is the 1-based cycle counter and `MAX_CYCLES` is the resolved maximum. This line is required before any findings, deltas, or token emissions within that cycle.

**Oscillation-check hard gate (cycle >= 2)**: On any cycle where `N >= 2`, the orchestrator MUST invoke `/dso:oscillation-check` (Skill) before proceeding with findings analysis. Skipping this gate requires an explicit `OSCILLATION_CHECK_SKIPPED: <reason>` ticket comment capturing the rationale; no other skip reason is permitted.

**Mid-loop success exit**: If the revised task set shows no remaining gap-analysis concerns on any cycle (before reaching `MAX_CYCLES`), the loop exits immediately and Step 6 proceeds to summary update. No terminal token is emitted on success.

**HALT-vs-REPLAN exclusivity check**: `REPLAN_ESCALATE` MUST be emitted IFF `cycle_count == MAX_CYCLES AND findings non-empty`. No other condition may emit `REPLAN_ESCALATE`. All other terminal states use a different token — human-input required → `HALT_FOR_USER`; oscillation detected → `OSCILLATION_HALT`; illegal state transition → `PROTOCOL_ERROR`. Emitting `REPLAN_ESCALATE` under any other condition, or emitting it together with `PROTOCOL_ERROR`, is itself a `PROTOCOL_ERROR`.

**Terminal REPLAN_ESCALATE**: On cycle `MAX_CYCLES` with findings still non-empty, emit (per the canonical `${CLAUDE_PLUGIN_ROOT}/docs/contracts/replan-escalate-signal.md` colon-space prefix):
`REPLAN_ESCALATE: planner_supplied EXPLANATION:<explanation text>`
The upstream for implementation-plan Step 6 is `planner_supplied` (per the upstream enum in Section 6 of the protocol doc). Emit this as a standalone ticket comment so the orchestrator's parent session can detect and route the escalation. The literal prefix `REPLAN_ESCALATE: ` (colon followed by a single space) and the `EXPLANATION:` field label are fixed by contract — do not vary them.

**PROTOCOL_ERROR on invariant violation**: Any illegal state transition — emitting `REPLAN_ESCALATE` when `cycle_count < MAX_CYCLES`, emitting multiple terminal tokens, or violating the HALT-vs-REPLAN exclusivity invariant — MUST emit `PROTOCOL_ERROR` and halt remediation immediately.

See: `${CLAUDE_PLUGIN_ROOT}/skills/shared/workflows/remediation-loop-protocol.md`

**Per-cycle scratch write (Step 6 — cycle recorder)**

After each cycle's re-dispatch and review, atomically write a cycle-recorder entry to the scratch store using the scratch CLI. The sub-agent writes the payload and returns ONLY a 3-field receipt — it must NOT embed the payload in its return block.

**Namespacing constants (set once before the remediation loop; do NOT alter per-cycle):**

```bash
SCRATCH_TICKET_ID="<story_id>"   # SCRATCH_TICKET_ID — ticket namespace for scratch isolation
SCRATCH_KEY="implementation-plan:step6:gap-analysis-draft"   # SCRATCH_KEY — authoritative key per ticket-scratch-cli.md
```

**Sub-agent write (inside sub-agent prompt — cycle recorder):**

The sub-agent constructs the cycle JSON payload and writes it via the scratch CLI:

```bash
# Sub-agent: write cycle entry to scratch store (do NOT return the payload inline)
CYCLE_PAYLOAD=$(python3 -c "import json; print(json.dumps({
  'n': <cycle-number>,
  'draft_hash': '<sha256 of DELTA OUTPUT block>',
  'findings_count': <int>,
  'verdict': '<pass|fail|escalate>'
}))")
bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" set "$SCRATCH_TICKET_ID" "$SCRATCH_KEY" "$CYCLE_PAYLOAD"
```

<output_contract>
The sub-agent MUST return ONLY the following 3-field receipt JSON. No other content, no payload body, no cycle details. Embedding the cycle payload in the return block is a contract violation and will produce RECEIPT_PARSE_ERROR.

```json
{"ticket_id": "<SCRATCH_TICKET_ID>", "key": "<SCRATCH_KEY>", "byte_count": <N>}
```

Example (valid):
```json
{"ticket_id": "abcd-1234-efgh-5678", "key": "implementation-plan:step6:gap-analysis-draft", "byte_count": 142}
```

Example (INVALID — payload embedded, contract violation):
```json
{"ticket_id": "abcd-1234-efgh-5678", "key": "implementation-plan:step6:gap-analysis-draft", "byte_count": 142, "n": 1, "verdict": "fail"}
```
</output_contract>

**Orchestrator-side: validate receipt, then read payload:**

After the sub-agent returns, parse the receipt with `receipt-parse.sh` and halt on any contract violation:

```bash
# Validate receipt — halt on RECEIPT_PARSE_ERROR (exit 2)
_parsed=$(echo "<sub_agent_output>" | bash "$PLUGIN_SCRIPTS/receipt-parse.sh" implementation-plan:step6 dso:task-decomposer) || {
  echo "ERROR: RECEIPT_PARSE_ERROR from dso:task-decomposer at implementation-plan:step6 — halting workflow" >&2
  exit 1
}
# _parsed = "<ticket_id> <key>" (space-separated) on success

# Read cycle payload from scratch store (SCRATCH_MISS guard — co-located with get)
_raw=$(bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" get "$SCRATCH_TICKET_ID" "$SCRATCH_KEY")
_status=$(echo "$_raw" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])")
if [ "$_status" = "miss" ]; then
  # SCRATCH_MISS: sub-agent did not write the key before returning receipt.
  # Example of a miss (key absent): {"status":"miss","ticket_id":"abcd-1234-efgh-5678","key":"implementation-plan:step6:gap-analysis-draft"}
  # This is NOT a valid input — treat as a contract violation and halt.  # precondition-emit-ok: negation, no degradation event
  echo "ERROR: SCRATCH_MISS for $SCRATCH_TICKET_ID/$SCRATCH_KEY — sub-agent returned receipt but key not present; halting." >&2
  # Inline cleanup: remove any partial scratch state before exit
  bash "$PLUGIN_SCRIPTS/ticket-scratch.sh" clear "$SCRATCH_TICKET_ID" "$SCRATCH_KEY" 2>/dev/null || true
  exit 1
fi
CYCLE_JSON=$(echo "$_raw" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])")
```

After reading `CYCLE_JSON`, record the cycle artifact via the recorder:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/append_review_cycle.py \
  --artifact <path-to-gap-analysis-artifact-for-step6> \
  --n <cycle-number> \
  --draft-hash <sha256 of DELTA OUTPUT block> \
  --findings-count <int> \
  --verdict <pass|fail|escalate>
```

After the append, emit exactly ONE ticket comment per cycle that references the scratch key (not a file path):

```bash
.claude/scripts/dso ticket comment <ticket-id> "Remediation cycle <n> recorded at scratch:$SCRATCH_TICKET_ID/$SCRATCH_KEY"
```

**Single-comment policy (SC5)**: The ticket comment references the scratch key and does NOT duplicate the cycle body — cycle entries live in the scratch store under `$SCRATCH_KEY`, not in ticket comments. One comment per cycle; no further detail in the comment body.

---

## Common Mistakes (non-obvious)

| Mistake | Fix |
|---------|-----|
| Skipping cross-cutting detection | Count layers and interfaces before deciding to skip Step 2 — a "simple" change touching route → service → agent → provider is already cross-cutting |
| Cross-cutting but no pattern change | Cross-cutting threshold overrides the new-pattern check — Step 2 is still required |
| Test filename not fuzzy-matchable | Verify the normalized source basename is a substring of the normalized test basename. If not, require a `.test-index` entry in AC |
| Tasks requiring co-commit | Every task must be independently committable and green. Inert (does nothing yet) is fine; broken is not |
<!-- EMIT-PRECONDITIONS: gate_name=implementation_plan_gap_analysis_failure degradation_type=inferred_decision -->
| Blocking on gap analysis failure | Gap analysis failure is non-blocking — log warning and continue |

## Stage-Boundary Exit Write

Before emitting any STATUS line, write the preconditions exit event (fail-open):

```bash
_dso_pv_exit_write "implementation-plan" "${_UPSTREAM_EVENT_ID:-}" "${SPEC_HASH:-}" "${STORY_ID:-${primary_ticket_id:-}}" || true
```

---

## Output Protocol (when invoked from /dso:sprint)

When invoked via Skill tool from `/dso:sprint`, output one of these STATUS lines as the final output so the sprint orchestrator can parse the result:

### On success (all tasks created, dependencies added, plan approved, gap analysis complete):

Before emitting STATUS:complete, confirm that both audit marker tags were applied to the story ticket in their respective steps:
- `plan_review:pass` — set in Step 4 after plan review passes
- `gap_analysis:complete` — set in Step 6 after gap analysis completes (or TRIVIAL skip is confirmed)

If either tag is absent, the corresponding step was skipped. Return and complete the missing step before emitting STATUS:complete.

```
STATUS:complete TASKS:<comma-separated-task-ids> STORY:<story-or-epic-id>
```

### On ambiguity or blocker (cannot proceed without user input):

```
STATUS:blocked QUESTIONS:<json-array-of-question-objects>
```

Each question object has two fields:
- `"text"`: the question string
- `"kind"`: `"blocking"` (cannot plan without this) or `"defaultable"` (safe assumption exists — include the assumption in the text)

Rules: never include questions clearly answerable from the codebase or parent epic.

### On copy-story bypass (story is dispatched by sprint to gov-copy-writer):

```
STATUS:bypass REASON:copy_story STORY:<story-id>
```

Emitted when the pre-flight detects `copy-story` tag OR title prefix `"Apply gov-copy to "` (case-insensitive). Terminal signal — do not emit STATUS:complete or STATUS:blocked after it. No tasks are created. The sprint orchestrator handles copy-story execution via the gov-copy-writer dispatch path (see sprint SKILL.md "Copy Story Dispatch" section).

### On unsatisfiable success criteria (story intent requires brainstorm-level re-evaluation):

```
REPLAN_ESCALATE: brainstorm EXPLANATION:<explanation>
```

Emitted when SC cannot be satisfied given the current codebase state — they are actively contradicted, internally contradictory, or unsatisfiable regardless of approach. Terminal signal — do not emit STATUS:complete or STATUS:blocked after it. No tasks are created. The calling orchestrator routes this signal to `/dso:brainstorm` on the story rather than proceeding to implementation batches.

**Output boundary**: after emitting a STATUS line, emit no further prose, questions, or options within this skill invocation — the STATUS line is the skill's return value, not a session terminator. **Do NOT stop the session or wait for user input** — the STATUS line is a return-to-caller signal. The calling context (sprint orchestrator or user) reads the STATUS line and continues autonomously.
