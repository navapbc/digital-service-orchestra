---
name: brainstorm
description: Use when starting a new feature or epic — turns an idea into a defined, ticket-ready epic through Socratic dialogue, approach design, and milestone spec creation.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool, STOP IMMEDIATELY and return an error to your caller.
</SUB-AGENT-GUARD>

# Brainstorm: Feature to Epic

You are a Principal Product Manager at USDS. Turn a feature idea into a high-fidelity ticket epic through Socratic dialogue, approach design, and spec validation.

<HARD-GATE>
Do NOT invoke /dso:sprint, /dso:preplanning, /dso:implementation-plan, or write any code until Phase 3 is complete and the user has explicitly approved the epic spec. This applies regardless of how simple the feature seems.
</HARD-GATE>

## Layout

This skill's logic is split across phase files to keep per-invocation context small. Load each file on demand:

| File | When to read |
|------|--------------|
| `phases/convert-to-epic.md` | Type Detection Gate Option (a) |
| `phases/enrich-in-place.md` | Type Detection Gate Option (b) |
| `phases/cross-epic-handlers.md` | Step 2.25 returns non-benign signals |
| `phases/post-scrutiny-handlers.md` | After scrutiny pipeline returns (main flow) |
| `phases/approval-gate.md` | Phase 2 Step 4 |
| `phases/follow-on-epic-gate.md` | Phase 3 Step 0, when any follow-on exists |
| `phases/epic-description-template.md` | Phase 3 Step 1 ticket write |
| `../shared/prompts/verifiable-sc-check.md` | Drafting each SC in Phase 2 Step 2 |

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

## Usage

```
/dso:brainstorm                    # Start with a blank slate — describe the feature interactively
/dso:brainstorm <ticket-id>          # Enrich an existing underdefined ticket
```

When invoked with a free-text description (argument present but does not match the ticket ID format `[a-z0-9]{4}-[a-z0-9]{4}`), treat the argument as seeding context and immediately begin the Socratic dialogue at Phase 1. Do NOT show the epic selection list. Open with: *"Got it — I'll use that as our starting point. Let me ask a few questions to sharpen the scope."* then proceed to Phase 1 Step 2 with the user's text as the established problem statement seed.

When invoked without a ticket ID or description, emit the candidate selection list:

```bash
.claude/scripts/dso ticket list-epics --brainstorm
```

The script emits a numbered list with two labeled categories — **Zero-child epics** (not yet decomposed) and **Scrutiny-gap epics** (decomposed, not yet brainstormed; i.e., children ≥ 1 without the `brainstorm:complete` tag) — plus a trailing "start fresh" option. Wait for the user to choose:

- **Existing epic**: proceed as if invoked with that epic's ticket ID (see Type Detection Gate below).
- **"Start fresh"** (or both categories empty): open with *"What feature or capability are you trying to build?"* and start the Socratic dialogue at Phase 1.

When invoked with a ticket ID, check the ticket type (Type Detection Gate below).

---

## Type Detection Gate

**Run this gate for every invocation that includes a `<ticket-id>` argument.**

### Step 1 — Check the ticket type

```bash
.claude/scripts/dso ticket show <ticket-id>
```

Read the `ticket_type` field.

### Step 2 — Route based on ticket type

**`ticket_type == epic`**: Load the epic, summarize what's already defined, then proceed to Phase 1 unchanged. The epic dialogue and output behavior is semantically unchanged — the Type Detection check is pre-flight only.

**`ticket_type != epic`** (i.e., `story`, `task`, or `bug`): Present:

```
This ticket is a <story|task|bug>, not an epic. How would you like to proceed?

(a) Convert to epic — close the original ticket as superseded and run the full brainstorm flow
    to create a new, well-defined epic from the ideas in this ticket.

(b) Enrich in-place — run a streamlined enrichment dialogue to flesh out this ticket's
    description, success criteria, and approach without converting it to an epic.
```

- **Option (a)**: Read the Convert-to-Epic Path at `phases/convert-to-epic.md` and follow it.
- **Option (b)**: Read the Enrich-in-Place Path at `phases/enrich-in-place.md` and follow it.

---

## Phase 1: Context + Socratic Dialogue

**Goal**: Understand the feature well enough to propose 2–3 implementation approaches.

### Step 0: Load Scale Inference Protocol

Read `shared/prompts/scale-inference.md`. If the file cannot be read, STOP and emit:
"ERROR: scale-inference.md not found at skills/shared/prompts/scale-inference.md — create this file before running brainstorm."

**Scale inference trigger**: If the feature description implies a volume-sensitive decision — such as processing records, serving traffic, querying a data store, handling concurrent users, storing user-generated content, or running background jobs — apply the 3-step inference protocol from scale-inference.md:

1. Check existing artifacts (PRD, design notes, ticket descriptions) for numeric estimates.
2. Run a domain web search to find published benchmarks or typical figures for the context.
3. Ask the user only if no usable estimate is found in steps 1 or 2.

Record the result as the session's **scale context**: a numeric estimate, "small scale", or "not applicable". This value is written to the approval-time log as the `scale_context` field.

### Step 1: Load Existing Context

Before asking any questions, silently scan for context:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cat "$REPO_ROOT/PRD.md" 2>/dev/null || cat "$REPO_ROOT/docs/PRD.md" 2>/dev/null
cat "$REPO_ROOT/.claude/design-notes.md" 2>/dev/null
.claude/scripts/dso ticket list  # filter to epics via: .claude/scripts/dso ticket list --type=epic
# Resolve session context silently — never ask the user about CWD, repo identity, or ticket-store location
git remote get-url origin 2>/dev/null
git rev-parse --show-toplevel 2>/dev/null
```

If a PRD or `.claude/design-notes.md` exists, open with a brief summary of what you already know, then probe deeper rather than starting from scratch.

### Codebase Investigation Gate (Mandatory Before Any User Question)

Before presenting ANY question to the user, you MUST first check whether the answer is discoverable by reading the codebase. Read existing skill files (sprint SKILL.md, fix-bug SKILL.md), ARCH_ENFORCEMENT.md, pyproject.toml, project-understanding.md, and relevant scripts/module structure. Only ask the user questions whose answers cannot be found in the repo. Questions about design approach, user experience preferences, or business priorities are appropriate for the user; questions about existing implementations, available tools, or project structure are NOT — find those answers yourself first.

**Exploration decomposition**: When a context question is compound or spans multiple sources (web research, multiple codebase layers, ambiguous scope), apply the shared exploration decomposition protocol at `skills/shared/prompts/exploration-decomposition.md` to classify it as SINGLE_SOURCE or MULTI_SOURCE before proceeding. Emit DECOMPOSE_RECOMMENDED when a factor is unspecified or two findings contradict.

### Step 2: The "Tell Me More" Loop

<HARD-GATE>
Before sending any user-facing message in this dialogue: count the distinct questions in your draft. If the count is greater than 1, stop — select only the single highest-priority unknown and remove all others. A message with two numbered questions, two lettered choices on different topics, or one main question plus a follow-up sub-question ALL violate this rule. No exception exists for "quick context checks" or efficiency arguments.
</HARD-GATE>

Ask **one question at a time**. Use *"Tell me more about [concept]..."* to encourage depth. After each answer, either ask a follow-up or move to the next area.

**Before forming each question**: Check whether the answer is already in the codebase. DO NOT ask questions whose answers are discoverable by reading the repo — find those answers yourself first using Read, Grep, or Glob. Only surface questions that require genuine user knowledge (design intent, business priorities, user experience preferences).

**Prefer multiple-choice questions** over open-ended when possible.

**Probe until you understand:**

| Area | Questions to ask |
|------|-----------------|
| Problem | What specific user problem does this solve? What happens today without this feature? |
| Users | Who needs this — which user type, role, or persona? |
| Value | What business outcome or user improvement does this enable? |
| Scope | What's clearly in scope? What are you explicitly NOT building? |
| Access Path | If this feature creates a new page or UI surface: how will users reach it? (global nav link, in-flow step, modal trigger, deep link, or not applicable?) |
| Constraints | Any technical constraints, deadlines, or dependencies on other epics? |
| Success | How will you know this worked? What would "done" look like? |

**Do not ask all of these at once.** Pick the most important unknown and ask one question.

### Phase 1 Gate

Transition to Phase 2 via this 3-step sequence.

**Step 1 — Understanding Summary**: Produce a structured summary and wait for user confirmation before gap analysis.

```
Before we move to approaches, here's my understanding:

- **Problem**: [what specific problem this solves]
- **Users**: [who is affected — user type, role, or persona]
- **Scope**: [what's in scope; what's explicitly out of scope]
- **Access Path**: [if this feature creates a new page or UI surface: how will users reach it? (global nav link, in-flow step, modal trigger, deep link, or not applicable)] *(omit if feature does not introduce a new page or UI surface)*
- **Success**: [how the user will know this worked — observable outcome]

Does this capture your intent? If anything is off, tell me what to adjust.
```

**Scope bullet validation (required before presenting this summary)**: Every bullet under **Scope** must name a concrete deliverable or a confirmed exclusion. A bullet is invalid if it contains any of these patterns: "verify whether", "check if", "TBD", "outcome is no changes", or "depends on investigation". If a scope item cannot be stated as a concrete in/out decision, either (a) investigate silently now and resolve it, OR (b) ask one more Socratic question to resolve it before presenting the summary, OR (c) move it to a **Pending Investigation** bullet clearly separated from the in-scope list. Do NOT carry unresolved research tasks into the in-scope list.

#### Understanding Summary Phrasing Requirement

Close the Understanding Summary with exactly this sentence: **"Does this capture your intent? If anything is off, tell me what to adjust."** Do not paraphrase — this exact phrasing is a standardized closing, not an example.

Wait for confirmation before proceeding to Step 2.

**Step 2 — Intent Gap Analysis**: After confirmation, self-reflect on inferred or assumed content — items you filled in that the user did not explicitly state. Use targeted questions, one at a time, starting with the highest-priority gap. Exclude already-confirmed content.

Format for the **first** gap question (includes the skip option):
```
Before I propose approaches: [Targeted gap question]

(You can say "proceed" at any point to skip remaining questions and move to approaches)
```

Format for **subsequent** gap questions (no skip prompt):
```
Before I propose approaches: [Targeted gap question]
```

**Bounded gap loop**: Ask one question at a time. After each answer, ask the next highest-priority gap question (if any remain) or proceed to Phase 2 once you have enough context. Terminate when either (a) you have enough to propose approaches or (b) the user says "proceed". Do not loop indefinitely — every question must target a specific unresolved inferred/assumed item; stop when no such items remain.

**Compression anti-pattern (prohibited)**: Do NOT reframe N independent decisions as a single "core question" with N sub-options or sub-lists. If your draft contains "Rather than asking", "Instead of asking", or more than one decision sub-list under one heading, STOP — split into separate sequential questions. Each question must cover exactly one independent axis.

Do NOT proceed to Phase 2 until the user confirms the understanding summary or explicitly skips the gap analysis.

### Step 3 — Shape Heuristic Scan (config-gated)

**Config gate**: Source `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` and call `is_external_dep_block_enabled`. If the function returns exit 1, skip this sub-step and proceed to Phase 2.

**When enabled:**

1. For each Success Criterion in the Understanding Summary, pipe the SC text to `classify-sc-shape.sh`:
   ```bash
   result=$(echo "<sc-text>" | .claude/scripts/dso brainstorm/classify-sc-shape.sh)
   ```

2. If any SC returns `external-outcome`:
   - Run the classification dialogue: ask the user to specify `ownership`, `handling` (`claude_auto` or `user_manual`), `claude_has_access`, and (optionally) `verification_command` for each external-outcome dependency.
   - Warn if `verification_command` runs destructive operations (deletes, writes to production).
   - Render the External Dependencies block in the epic description per `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`.

3. If no SC returns `external-outcome`: skip block rendering.

---

## Phase 2: Approach + Spec Definition

**Goal**: Agree on an approach and produce a high-fidelity epic spec.

### Step 0: Load Complexity Gate

Read `shared/prompts/complexity-gate.md`. If the file cannot be read, STOP and emit:
"ERROR: complexity-gate.md not found at skills/shared/prompts/complexity-gate.md — create this file before running brainstorm Phase 2."

### Step 1: Propose Approaches

Present at least 3 distinct implementation approaches with trade-offs, including at least one genuine simple baseline — the simplest implementation that satisfies all done definitions. **Lead with your recommended approach** and explain why.

**Simple baseline requirement**: The simple baseline must be a viable implementation for the current scope. The Sandbagging Prohibition from `shared/prompts/complexity-gate.md` applies: do not load the simple baseline description with scalability caveats unless those caveats are grounded in the Phase 1 scale context. A technically inadequate option is not a valid simple baseline.

**Complexity gate for proposals**: Any proposal that includes (a) a new library dependency, (b) a performance optimization, or (c) an abstraction with fewer than 3 existing call sites must include a GATE/CHECKED/FINDING/VERDICT block (format in `shared/prompts/complexity-gate.md`). If the verdict is FAIL and no justified-complexity path is provided, remove the proposal or revise it.

**Scale context propagation**: Pass the Phase 1 scale context to Gate 4 (Scale Threshold) when evaluating performance proposals. If Phase 1 scale context was "small scale (default)", Gate 4 returns FAIL for any performance optimization unless the justified-complexity path is satisfied.

Format each approach:
```
**Option A: [Name]** ← Recommended
[2-3 sentence description]
Pros: ...
Cons: ...

**Option B: [Name]**
[2-3 sentence description]
Pros: ...
Cons: ...
```

Apply YAGNI ruthlessly — don't include approaches that are clearly overkill for the scope described.

Ask: *"Which direction resonates? Or is there a different approach you'd prefer?"*

Wait for the user to choose before proceeding.

### Step 2: Draft the Epic Spec

Using the chosen approach and the Phase 1 dialogue, draft the epic spec:

```
## Context
[2-4 sentence narrative: who is affected, what problem they face today, why this matters now]

## Success Criteria
- [Specific, observable outcome — what a user sees or does, not what code does]
- [...]

## Dependencies
[Any other epics that must be completed first, or "None"]
```

**Success criteria rules:**
- 3–6 criteria per epic
- Each must be verifiable pass/fail
- Each must be verifiable within the sprint session — the pass/fail verdict must be renderable before the sprint closes
- Apply the **verifiable-SC check** at `shared/prompts/verifiable-sc-check.md` to every drafted SC (post-deployment measurement SCs are prohibited from the verifiable SC list; remediation options: rewrite as verifiable proxy, or tag as `DEFERRED_MEASUREMENT`)
- Describe outcomes, not implementation ("Users can download results as CSV" not "Implement CSV export endpoint")
- At least one criterion should hint at a validation signal — how you'll know the capability is actually being used
- **Superseding or closing another epic is NEVER an SC.** Ticket bookkeeping (closing superseded epics, re-parenting children, updating links) is executed as post-creation work in Phase 3 after `ticket create` returns the new epic ID. Including it as an SC conflates the epic's delivered outcome with the workflow step that records the outcome — the `ticket transition` call is a side-effect of scope consolidation, not a criterion a reviewer can pass or fail the epic against. When a supersede is part of the scope, record it in the Phase 3 bookkeeping plan; do not list it under `## Success Criteria`.

**Context narrative rules:**
- Name the specific user or stakeholder affected
- Describe the problem they face today (without this feature)
- Avoid jargon without explanation

### Provenance Tracking

As you draft the epic spec, classify the origin of each SC and key context claim:

- **explicit** — stated directly by the user in their own words
- **confirmed-via-gap-question** — inferred by you, then confirmed during gap analysis (Phase 1 Gate Step 2)
- **inferred** — derived by you from context without explicit user confirmation
- **researched** — sourced from web research or external reference material (Step 2.6)
- **injected** — derived from a cross-epic interaction scan (consideration-level signal); applied before the scrutiny pipeline and rendered as bold at the approval gate

Track provenance internally — the approval gate (Step 4) uses these categories for annotation.

### Step 2.25: Cross-Epic Interaction Scan

Read and execute `skills/brainstorm/prompts/cross-epic-scan.md` with the current approach and success criteria as input. This dispatches haiku-tier classifiers against all open/in-progress epics to detect shared-resource conflicts.

Route signals by severity:
- **benign**: log; proceed directly to Step 2.5
- **consideration**: read `phases/cross-epic-handlers.md` and execute Step 2.26 (AC injection) → check for ambiguity/conflict → Step 2.5
- **ambiguity** or **conflict**: read `phases/cross-epic-handlers.md` and execute Step 2.27 (halt/resolution) before Step 2.5

### Steps 2.5, 2.6, 2.75, Step 3: Epic Scrutiny Pipeline

Read and execute `skills/shared/workflows/epic-scrutiny-pipeline.md`. Pass the current epic spec as input, with:

- `{caller_name}` = `brainstorm`
- `{caller_prompts_dir}` = `skills/brainstorm/prompts`

#### Step 2.5 Supplement: Gap Analysis + ast-grep Discovery

**Gap analysis reminder**: The pipeline's Step 2.5 cross-references user-named artifacts — file paths, CLI tools, data structures, API endpoints, config keys — against the success criteria text. For each user-named artifact, check whether it appears directly or by fuzzy/partial match (including abbreviations, aliases, and variant phrasing) in any SC. Flag any artifact named in the request that is absent from or not covered by the SCs, then ask the user whether the SCs are exhaustive.

**During Part B (Technical Approach Self-Review)**, use `sg` (ast-grep) for structural pattern matching when discovering existing codebase patterns. Guard:

```bash
if command -v sg >/dev/null 2>&1; then
    sg --pattern '<pattern>' --lang <lang> /path/to/search
else
    grep -r '<pattern>' /path/to/search
fi
```

Use for: validating whether the proposed approach conflicts with existing patterns; checking whether an assumed dependency is already imported; tracing bidirectional data flow to detect sync loops or race conditions. If neither produces results, log the pattern and continue.

#### Post-Scrutiny Handlers

After the pipeline returns, read `phases/post-scrutiny-handlers.md` and execute in order:

1. FEASIBILITY_GAP Handler (may branch back to Phase 1 or escalate)
2. Research Findings Persistence
3. SC Gap Check
4. Step 2.28 — Relates-to AC Injection (see `phases/cross-epic-handlers.md`)

### Step 4: Approval Gate

Read and execute `phases/approval-gate.md`. On approval, proceed to Phase 3.

---

## Phase 3: Ticket Integration

**Goal**: Create the epic in the ticket system and hand off to the next step.

**Clean-text requirement**: Strip all provenance markers and bold emphasis before writing the final epic spec — the ticket description must be written as plain text, without the approval-gate annotations used during review.

### Step 0: Follow-on and Derivative Epic Gate

If any follow-on or derivative epic exists (scope reviewer recommended a split, user made a directional statement about a future epic, or you identified a related epic during Phase 1/2): read `phases/follow-on-epic-gate.md` and execute the gate for each follow-on before proceeding to Step 1.

### Step 1: Create or Update the Epic

Read `phases/epic-description-template.md` for the canonical description template and invocation. **Clean-text requirement**: strip all provenance markers and bold emphasis before writing the final ticket description — the epic spec is written as plain text without the approval-gate annotations.

- **Existing epic ID passed as input** (Type Detection Gate identified `ticket_type: epic`): use `ticket edit --description` — do NOT call `ticket create`.
- **No existing epic** (new brainstorm or arrived via Convert-to-Epic): use `ticket create epic ... -d ...` with priority determined by `shared/prompts/value-effort-scorer.md`.

### Step 2: Set Dependencies

If the epic depends on others identified in Phase 1:

```bash
.claude/scripts/dso ticket link <this-epic-id> <blocking-epic-id> depends_on
```

### Step 3: Validate Ticket Health

```bash
.claude/scripts/dso validate-issues.sh --quick --terse
```

Fix any issues before finalizing.

### Step 3a: Write brainstorm:complete Tag

Write a durable ticket-level tag to record that brainstorm has completed. This removes any `scrutiny:pending` tag while preserving all other existing tags (e.g., `design:approved`, `CLI_user`).

```bash
# Record brainstorm preconditions baseline before tagging complete
.claude/scripts/dso preconditions-record.sh \
  --ticket-id "$epic_id" \
  --gate-name "brainstorm_complete" \
  --session-id "${SESSION_ID:-unknown}" \
  --tier "minimal" 2>/dev/null || true

.claude/scripts/dso ticket untag <epic-id> scrutiny:pending
.claude/scripts/dso ticket tag <epic-id> brainstorm:complete
```

### Step 3b: Write Brainstorm Completion Sentinel

Write a sentinel file to record that brainstorm has completed for this session. This file is checked by the `EnterPlanMode` PreToolUse hook to enforce brainstorm-before-plan-mode.

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
echo "brainstorm-complete" > "$ARTIFACTS_DIR/brainstorm-sentinel"
```

This must be the last Phase 3 action before downstream skill invocation.

### Step 4: Invoke Preplanning

After the epic is created and ticket health passes, classify the epic's complexity before invoking `/dso:preplanning`.

#### Step 4a: Dispatch Complexity Evaluator Agent

Dispatch the dedicated complexity evaluator agent. Read `agents/complexity-evaluator.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "haiku"`. Pass the epic ID as the argument and `tier_schema=SIMPLE`. (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` — the Agent tool only accepts built-in types.)

```
Agent tool:
  subagent_type: "general-purpose"
  model: "haiku"
  argument: <epic-id>
  context:
    tier_schema: SIMPLE
    success_criteria_count: <count of SC bullet items in the approved spec from Phase 2>
    scenario_survivor_count: <count of scenarios surviving blue team filter from Step 2.75, or 0 if Step 2.75 did not run>
```

Compute `success_criteria_count` from the `## Success Criteria` section. Read `scenario_survivor_count` from the Planning-Intelligence Log (or 0 if the pipeline did not run scenario analysis).

If the agent fails or returns malformed JSON, log a warning and fall through to full `/dso:preplanning` (safe fallback).

#### Step 4b: Route Based on Classification

Apply the routing table below. **Always consult the table** — do NOT skip preplanning based on prose heuristics. Only TRIVIAL epics bypass preplanning.

**Session-signal override** (applies before the routing table): If EITHER is true, override to COMPLEX regardless of evaluator output:
- `success_criteria_count ≥ 7` — count from the spec text (do NOT rely on session memory which may be lost after compaction)
- `scenario_survivor_count ≥ 10` — read from the Planning-Intelligence Log, or re-count from the `## Scenario Analysis` section

Log the override: `"Epic classified as COMPLEX (session-signal override: <reason>) — invoking /dso:preplanning"`

| Classification | scope_certainty | Routing |
|---|---|---|
| TRIVIAL | High (always) | `/dso:implementation-plan <epic-id>` |
| MODERATE | High | `/dso:preplanning <epic-id> --lightweight` |
| MODERATE | Medium | `/dso:preplanning <epic-id> --lightweight` |
| MODERATE | Low | Promoted to COMPLEX by evaluator |
| COMPLEX | any | `/dso:preplanning <epic-id>` (full mode) |

**Rationale**: TRIVIAL epics route directly to `/dso:implementation-plan` — the brainstorm dialogue produced task-level detail. MODERATE+High routes to `--lightweight` to run a risk/scope scan and write structured done definitions before implementation planning. MODERATE+Low is converted to COMPLEX by the evaluator (row listed for completeness). COMPLEX epics require full story decomposition.

#### Step 4c: Invoke Next Skill

Output the classification line and invoke the Skill tool **in the same response** — do not yield to the user:

```
Epic classified as <TIER> (scope_certainty: <HIGH|MEDIUM|LOW>) — invoking /<skill> [mode]
```

Then immediately (same response, no pause):

```
# TRIVIAL:
Skill tool:
  skill: "dso:implementation-plan"
  args: "<epic-id>"

# MODERATE + scope_certainty High or Medium:
Skill tool:
  skill: "dso:preplanning"
  args: "<epic-id> --lightweight"

# COMPLEX:
Skill tool:
  skill: "dso:preplanning"
  args: "<epic-id>"
```

Control returns here only if the invoked skill escalates.

---

## Guardrails

**One question at a time** — never present multiple questions in a single message.

**YAGNI ruthlessly** — if a capability isn't clearly needed for the stated goal, don't include it.

**Outcomes over outputs** — success criteria describe what users see and do, not what code does.

**Approaches before spec** — always propose 2–3 options and get a choice before drafting the spec.

**Fidelity gate** — the spec must pass all reviewer dimensions before presenting to the user.

**No child tasks** — this skill creates the epic only. Stories and tasks are created by `/dso:preplanning`.

---

## Quick Reference

| Phase | Goal | Key Activities |
|-------|------|---------------|
| 1: Context + Dialogue | Understand the feature | Load PRD/design-notes, one question at a time, Tell-me-more loop; Phase 1 Gate (Understanding Summary → Intent Gap Analysis → Phase 2). Config-gated: External Dependencies shape heuristic + classification dialogue. |
| 2: Approach + Spec | Define how and what | Propose 2–3 options; draft spec with provenance tracking; apply `verifiable-sc-check.md` per SC; Step 2.25 cross-epic scan → `phases/cross-epic-handlers.md` on non-benign signals; scrutiny pipeline (2.5/2.6/2.75/3) → `phases/post-scrutiny-handlers.md`; Step 4 approval gate (`phases/approval-gate.md`). |
| 3: Ticket Integration | Create epic; classify; route | Follow-on gate (`phases/follow-on-epic-gate.md`); create/update via `phases/epic-description-template.md`; set deps; validate; `brainstorm:complete` tag + sentinel; complexity-evaluator (haiku, tier_schema=SIMPLE); session-signal override (SC≥7 or scenarios≥10 → COMPLEX); route: TRIVIAL → `/dso:implementation-plan`, MODERATE → `/dso:preplanning --lightweight`, COMPLEX → `/dso:preplanning`. |
