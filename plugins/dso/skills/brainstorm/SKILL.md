---
name: brainstorm
description: Use when starting a new feature or epic — turns an idea into a defined, ticket-ready epic through Socratic dialogue, approach design, and milestone spec creation.
user-invocable: true
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:brainstorm cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Brainstorm: Feature to Epic

Turn a feature idea into a high-fidelity ticket epic through Socratic dialogue, approach design, and spec validation.

<HARD-GATE>
Do NOT invoke /dso:sprint, /dso:preplanning, /dso:implementation-plan, or write any code until Phase 3 is complete and the user has explicitly approved the epic spec. This applies regardless of how simple the feature seems.
</HARD-GATE>


**Supports dryrun mode.** Use `/dso:dryrun /dso:brainstorm` to preview without changes.

## Usage

```
/dso:brainstorm                    # Start with a blank slate — describe the feature interactively
/dso:brainstorm <epic-id>          # Enrich an existing underdefined epic
/dso:brainstorm <ticket-id>        # Works with any ticket type (epic, story, task, bug)
```

When invoked without a ticket ID, open with: *"What feature or capability are you trying to build?"* and start the Socratic dialogue.

When invoked with a ticket ID, check the ticket type first (see the gate section below).

---

## Type Detection Gate

**Run this gate for every invocation that includes a `<ticket-id>` argument.**

Run `.claude/scripts/dso ticket show <ticket-id>` and read the `ticket_type` field.

### Step 1: Check the ticket type

```bash
.claude/scripts/dso ticket show <ticket-id>
```

Read the `ticket_type` field from the output.

### Step 2: Route based on ticket type

**If `ticket_type` is `epic`:** Load the epic, summarize what's already defined, then proceed to Phase 1 unchanged. The epic dialogue and output behavior is semantically unchanged — this gate is a pre-flight type check only.

**If `ticket_type` is not epic** (i.e., `story`, `task`, or `bug`): Present the following two options to the user:

```
This ticket is a <story|task|bug>, not an epic. How would you like to proceed?

(a) Convert to epic — close the original ticket as superseded and run the full brainstorm flow
    to create a new, well-defined epic from the ideas in this ticket.

(b) Enrich in-place — run a streamlined enrichment dialogue to flesh out this ticket's
    description, success criteria, and approach without converting it to an epic.
```

**Option (a) — Convert to epic:**
1. Note the original ticket ID and content.
2. Close the original ticket: `.claude/scripts/dso ticket transition <id> <current-status> closed --reason="Superseded: converting to epic via /dso:brainstorm"`
3. Proceed to Phase 1 with the original ticket's content as seeding context. The full brainstorm flow creates a new epic.

**Option (b) — Enrich in-place:**
1. Load the ticket content and summarize what's already defined.
2. Run a streamlined enrichment dialogue: ask targeted questions about missing success criteria, approach, and dependencies (one question at a time, same as Phase 1 rules).
3. Update the ticket description with enriched content: `.claude/scripts/dso ticket comment <id> "Enriched via /dso:brainstorm: <summary>"`
4. Skip Phase 3 (ticket creation) — the ticket already exists.

---

## Phase 1: Context + Socratic Dialogue (/dso:brainstorm)

**Goal**: Understand the feature well enough to propose 2-3 implementation approaches.

### Step 1: Load Existing Context

Before asking any questions, silently scan for context:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cat "$REPO_ROOT/PRD.md" 2>/dev/null || cat "$REPO_ROOT/docs/PRD.md" 2>/dev/null
cat "$REPO_ROOT/.claude/design-notes.md" 2>/dev/null
.claude/scripts/dso ticket list  # filter to epics via: .claude/scripts/dso ticket list --type=epic
```

If a PRD or .claude/design-notes.md exists, open with a brief summary of what you already know, then probe deeper rather than starting from scratch.

### Step 2: The "Tell Me More" Loop

Ask **one question at a time**. Use *"Tell me more about [concept]..."* to encourage depth. After each answer, either ask a follow-up or move to the next area.

**Prefer multiple-choice questions** over open-ended when possible — easier to answer.

**Probe until you understand:**

| Area | Questions to ask |
|------|-----------------|
| Problem | What specific user problem does this solve? What happens today without this feature? |
| Users | Who needs this — which user type, role, or persona? |
| Value | What business outcome or user improvement does this enable? |
| Scope | What's clearly in scope? What are you explicitly NOT building? |
| Constraints | Any technical constraints, deadlines, or dependencies on other epics? |
| Success | How will you know this worked? What would "done" look like? |

**Do not ask all of these at once.** Pick the most important unknown and ask one question.

### Phase 1 Gate

When you have enough to propose approaches, ask: *"I think I have enough to propose some approaches. Does anything else matter before we dig into options?"*

Do NOT proceed to Phase 2 until the user confirms or adds more context.

---

## Phase 2: Approach + Spec Definition (/dso:brainstorm)

**Goal**: Agree on an approach and produce a high-fidelity epic spec.

### Step 1: Propose 2-3 Approaches

Present 2-3 distinct implementation approaches with trade-offs. **Lead with your recommended approach** and explain why.

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
- [...]

## Dependencies
[Any other epics that must be completed first, or "None"]
```

**Success criteria rules:**
- 3-6 criteria per epic
- Each must be verifiable pass/fail
- Describe outcomes, not implementation ("Users can download results as CSV" not "Implement CSV export endpoint")
- At least one criterion should hint at a validation signal — how you'll know the capability is actually being used

**Context narrative rules:**
- Name the specific user or stakeholder affected
- Describe the problem they face today (without this feature)
- Avoid jargon without explanation

### Steps 2.5, 2.6, 2.75, and Step 3: Epic Scrutiny Pipeline

Read and execute the shared epic scrutiny pipeline from `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`. Pass the current epic spec (Context + Success Criteria + Approach) as input, and supply the required pipeline parameters:

- `{caller_name}` = `brainstorm`
- `{caller_prompts_dir}` = `$REPO_ROOT/plugins/dso/skills/brainstorm/prompts`

### Step 4: Approval Gate

Present the validated spec to the user using **AskUserQuestion** with 4 options. Label options (b) and (c) based on whether the corresponding phase already ran in this session:

- **If web research (Step 2.6) has NOT yet run this session**: label (c) as "Perform additional web research"
- **If web research already ran this session**: label (c) as "Re-run web research phase"
- **If scenario analysis (Step 2.75) has NOT yet run this session**: label (b) as "Perform red/blue team review cycle"
- **If scenario analysis already ran this session**: label (b) as "Re-run red/blue team review cycle"

```
=== Epic Spec Ready for Review ===

**[Epic Title]**

## Context
[narrative]

## Success Criteria
- [...]

## Scenario Analysis
[if ran]

## Dependencies
[...]

Please choose how to proceed:

(a) Approve — advance to ticket creation (Phase 3)
(b) [Perform / Re-run] red/blue team review cycle — re-runs scenario analysis (Step 2.75) and re-presents this gate
(c) [Perform / Re-run] additional web research — re-runs web research phase (Step 2.6) and re-presents this gate
(d) Let's discuss more — pause for conversational review before re-presenting this gate
```

**Option behaviors:**

- **(a) Approve**: Record the planning-intelligence log entry (see below), then advance to Phase 3 (Ticket Integration). The log captures which bright-line trigger conditions fired (or "none"), whether scenario analysis ran and how many scenarios survived the blue team filter, and whether the practitioner requested additional cycles via this gate. State vocabulary: "not triggered" / "triggered" / "re-triggered via gate".
- **(b) Re-run scenario analysis**: Re-execute Step 2.75 (Scenario Analysis) with the current spec. Update the Scenario Analysis section in the spec with new results. Re-present this gate. On re-presentation, label (b) as "Re-run red/blue team review cycle" (scenario analysis already ran).
- **(c) Re-run web research**: Re-execute Step 2.6 (Web Research Phase) with the current spec. Update the Research Findings section. Re-present this gate. On re-presentation, label (c) as "Re-run web research phase" (research already ran).
- **(d) Discuss more**: Pause skill execution and engage in open conversational review with the user. When the user indicates they are ready to proceed, re-present this gate with updated labels reflecting what has already run.

If changes are requested during discussion or after any re-run, revise the spec and re-run affected fidelity reviewers before re-presenting this gate.

#### Planning-Intelligence Log Entry

After the user approves (option a), append a planning-intelligence log to the epic spec comment that will be written in Phase 3. The log entry records the planning context for future reference and uses a fixed state vocabulary: **"not triggered"** (phase skipped entirely), **"triggered"** (ran once, automatically or via bright-line condition), or **"re-triggered via gate"** (user explicitly requested a re-run via this gate).

Log format to append under the heading `### Planning Intelligence Log`:

```
### Planning Intelligence Log

- **Web research (Step 2.6)**: [not triggered | triggered | re-triggered via gate]
  - Bright-line conditions that fired: [list conditions, or "none"]
- **Scenario analysis (Step 2.75)**: [not triggered | triggered | re-triggered via gate]
  - Scenarios surviving blue team filter: [count, or "skipped — ≤2 success criteria"]
- **Practitioner-requested additional cycles**: [none | web research re-run N time(s) | scenario analysis re-run N time(s) | both re-run]
```

---

## Phase 3: Ticket Integration (/dso:brainstorm)

**Goal**: Create the epic in the ticket system and hand off to the next step.

### Step 1: Create the Epic

```bash
.claude/scripts/dso ticket create epic "<title>" -p <priority> -d "$(cat <<'DESCRIPTION'
## Context
[context narrative]

## Success Criteria
- [criterion 1]
- [criterion 2]

## Dependencies
[dependencies or 'None']

## Approach
[1-2 sentences on the chosen approach from Phase 2]
DESCRIPTION
)"
```

**Priority guidance:** Before creating the ticket, read and apply the value/effort scorer from `plugins/dso/skills/shared/prompts/value-effort-scorer.md`. Assess the epic's value (1-5) and effort (1-5) based on the conversation context, map to the recommended priority via the scorer's matrix, and use that priority with `-p <priority>` in the ticket create command above.

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

### Step 4: Invoke Preplanning

After the epic is created and ticket health passes, classify the epic's complexity before invoking `/dso:preplanning`. This routes the epic to the appropriate preplanning mode so the decomposition depth matches the scope.

#### Step 4a: Dispatch Complexity Evaluator Agent

Dispatch the dedicated complexity evaluator agent to classify the epic. Use the Task tool with `subagent_type: "dso:complexity-evaluator"` and `model: "haiku"`. Pass the epic ID as the argument and `tier_schema=SIMPLE` so the agent outputs SIMPLE/MODERATE/COMPLEX tier vocabulary.

```
Task tool:
  subagent_type: "dso:complexity-evaluator"
  model: "haiku"
  argument: <epic-id>
  context:
    tier_schema: SIMPLE
```

If the agent fails or returns malformed JSON (not parseable or missing the `classification` key), log a warning and fall through to full `/dso:preplanning` (full mode is the safe fallback default).

#### Step 4b: Route Based on Classification

Apply the brainstorm routing rule to the shared rubric's output. The key insight: brainstorm produces specs at varying fidelity levels. When the spec already includes explicit file lists, a defined approach, and measurable success criteria, preplanning (story decomposition) is redundant — route directly to `/dso:implementation-plan`.

| Classification | scope_certainty | Routing |
|---|---|---|
| TRIVIAL | High (always) | `/dso:implementation-plan <epic-id>` |
| MODERATE | High | `/dso:implementation-plan <epic-id>` |
| MODERATE | Medium | `/dso:preplanning <epic-id> --lightweight` |
| COMPLEX | any | `/dso:preplanning <epic-id>` (full mode) |

**Rationale**: TRIVIAL and MODERATE+High epics have named files, testable acceptance criteria, and bounded scope — the brainstorm dialogue already produced story-level detail. Preplanning would add overhead without value. MODERATE+Medium epics have a clear goal but implicit acceptance criteria that need decomposition. COMPLEX epics require full story decomposition regardless of spec fidelity.

#### Step 4c: Invoke Next Skill

Output the classification line and invoke the Skill tool **in the same response** — do not yield to the user between them:

```
Epic classified as <TIER> (scope_certainty: <HIGH|MEDIUM|LOW>) — invoking /<skill> [mode]
```

Then immediately (same response, no pause):

```
# TRIVIAL or MODERATE + scope_certainty High:
Skill tool:
  skill: "dso:implementation-plan"
  args: "<epic-id>"

# MODERATE + scope_certainty Medium:
Skill tool:
  skill: "dso:preplanning"
  args: "<epic-id> --lightweight"

# COMPLEX:
Skill tool:
  skill: "dso:preplanning"
  args: "<epic-id>"
```

`/dso:implementation-plan` will break the epic directly into atomic TDD tasks. `/dso:preplanning` will decompose into user stories first, then each story gets `/dso:implementation-plan`. Control returns here only if the invoked skill escalates (e.g., requires user clarification).

---

## Guardrails

**One question at a time** — never present multiple questions in a single message.

**YAGNI ruthlessly** — if a capability isn't clearly needed for the stated goal, don't include it.

**Outcomes over outputs** — success criteria describe what users see and do, not what code does.

**Approaches before spec** — always propose 2-3 options and get a choice before drafting the spec.

**Fidelity gate** — the spec must pass all reviewer dimensions before presenting to the user.

**No child tasks** — this skill creates the epic only. Stories and tasks are created by `/dso:preplanning`.

---

## Quick Reference

| Phase | Goal | Key Activities |
|-------|------|---------------|
| 1: Context + Dialogue | Understand the feature | Load PRD/DESIGN_NOTES, one question at a time, "Tell me more" loop |
| 2: Approach + Spec | Define how and what | Propose 2-3 options, draft spec; Step 2.5 gap analysis (artifact contradiction + technical self-review); Step 2.6 web research (bright-line triggers: external integration, unfamiliar dependency, security/auth, novel pattern, performance, migration — or user request); Step 2.75 scenario analysis (red team + blue team sonnet sub-agents; always runs when ≥5 SCs or integration signal, reduced/cap 3 when 3-4 SCs, skip when ≤2 SCs; targets epic-level spec gaps — distinct from preplanning adversarial review which targets cross-story gaps); run 3-reviewer fidelity check (+ conditional feasibility reviewer for integration epics); Step 4 approval gate (4-option AskUserQuestion: approve/scenario re-run/web research re-run/discuss; labels reflect initial-run vs re-run; planning-intelligence log appended on approve) |
| 3: Ticket Integration | Create the epic, classify complexity, route to next skill | `.claude/scripts/dso ticket create epic "<title>" -d "..."`, set deps, validate health, dispatch `dso:complexity-evaluator` agent (haiku, tier_schema=SIMPLE), output classification line + invoke Skill tool in same response: TRIVIAL/MODERATE+High → `/dso:implementation-plan`, MODERATE+Medium → `/dso:preplanning --lightweight`, COMPLEX → `/dso:preplanning` |
