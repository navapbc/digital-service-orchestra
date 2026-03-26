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
```

When invoked without an epic ID, open with: *"What feature or capability are you trying to build?"* and proceed to Phase 1.

When invoked with an epic ID, load the epic first (`.claude/scripts/dso ticket show <epic-id>`), summarize what's already defined, then enter Phase 1 to fill gaps.

---

## Phase 1: Context + Socratic Dialogue (/dso:brainstorm)

**Goal**: Understand the feature well enough to propose 2-3 implementation approaches.

### Step 1: Load Existing Context

Before asking any questions, silently scan for context:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cat "$REPO_ROOT/PRD.md" 2>/dev/null || cat "$REPO_ROOT/docs/PRD.md" 2>/dev/null
cat "$REPO_ROOT/DESIGN_NOTES.md" 2>/dev/null
.claude/scripts/dso ticket list  # then filter to epics via: grep -l '^type: epic' .tickets/*.md
```

If a PRD or DESIGN_NOTES.md exists, open with a brief summary of what you already know, then probe deeper rather than starting from scratch.

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

### Step 2.5: Gap Analysis (Self-Review)

Before running the fidelity review, run two gap checks in sequence.

#### Part A: Artifact Contradiction Detection

Cross-reference the user's original request against the drafted success criteria. Identify any artifacts, files, components, or named concepts that the user explicitly named in their request but that are absent from or not covered by the success criteria.

**How to detect omissions:**
1. Extract all artifact names the user explicitly mentioned (file paths, CLI tool names, data structures, API endpoints, config keys, etc.)
2. For each user-named artifact, check whether it appears — directly or by fuzzy/partial match — in any success criterion
3. Fuzzy matching rules (count as "covered", not "missing"):
   - Abbreviations and aliases (e.g., user says "tk" → SC says "bare tk CLI references" → **covered**)
   - Containment (e.g., user says ".index.json" → SC says ".tickets-tracker/.index.json" → **covered**)
   - Synonyms and role descriptions (e.g., user says "ticket store" → SC says ".tickets/ directory" → **covered**)
   - Only flag an artifact as missing when no reasonable interpretation of the SC text would encompass it

**When user-named artifacts are missing from SCs:**
Present the gaps to the user before proceeding:

```
Gap analysis found [N] artifact(s) you named that are not covered by the current success criteria:
- "[artifact-name]" — mentioned in your request, not found in any SC

Are the SCs exhaustive relative to what you asked for? Should we add criteria that explicitly address these artifacts, or are they intentionally out of scope?
```

Wait for the user to respond before continuing. Update the success criteria based on their answer.

#### Part B: Technical Approach Self-Review

After resolving any artifact gaps, think carefully about the proposed approach:

- **Are there any sync loops?** If the feature involves bidirectional data flow (sync, replication, event propagation), trace the full cycle: A pushes to B, B pulls back — will it create duplicates, false conflicts, or infinite loops?
- **Are there race conditions?** If multiple actors (worktrees, users, agents, CI) can modify the same state concurrently, what happens when they collide?
- **Does the approach invalidate existing assumptions?** Will adding new data to an existing format break hashing, parsing, caching, or diffing that depends on the current shape?
- **Are there parsing ambiguities?** If the format uses delimiters or markers, can user-provided content contain those same markers?

If gaps are found in either part, present them to the user and resolve before proceeding to the fidelity review.

### Step 3: Run Fidelity Review

Run the spec through three reviewers **in parallel** using the Task tool. For each reviewer:

1. Read the reviewer prompt from `docs/reviewers/` (relative to this skill's directory)
2. Pass: the milestone title, Context section, Success Criteria, and (for Scope reviewer) titles of other open epics
3. Instruct the reviewer to return JSON per the `REVIEW-SCHEMA.md` in the review-protocol skill

| Reviewer | Prompt File | Perspective | Dimensions |
|----------|-------------|------------|------------|
| Senior Technical Program Manager | [docs/reviewers/agent-clarity.md](docs/reviewers/agent-clarity.md) | `"Agent Clarity"` | `self_contained`, `success_measurable` |
| Senior Product Strategist | [docs/reviewers/scope.md](docs/reviewers/scope.md) | `"Scope"` | `right_sized`, `no_overlap`, `dependency_aware` |
| Senior Product Manager | [docs/reviewers/value.md](docs/reviewers/value.md) | `"Value"` | `user_impact`, `validation_signal` |

**Pass threshold**: All dimensions must score 4 or above.

**Validate the review output:**
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REVIEW_OUT="$(mktemp /tmp/brainstorm-review-XXXXXX.json)"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
".claude/scripts/dso validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller brainstorm
```

**Caller schema hash**: `f4e5f5a355e4c145`

**If a dimension scores below 4:**
- Fix the spec based on the finding
- Re-run only the failing reviewer
- Repeat until all dimensions pass, or escalate to user if conflicting guidance

**Watch for the "current vs. future state" anti-pattern**: If a reviewer scores a dimension low and the finding references existing files, components, or behaviors in the current codebase (e.g., "this file already exists at path X"), the reviewer may be evaluating present state rather than the spec's intended future state. Before iterating on the spec, verify whether the low score reflects a genuine spec gap or a reviewer anchor on the status quo. If the existing artifact will be changed or replaced by this epic, the finding is invalid — re-run that reviewer with an explicit reminder to evaluate the spec as written, not the current codebase.

**Conflict detection**: If two reviewers give contradictory guidance on the same spec element, escalate to the user immediately — do not resolve conflicts autonomously.

### Step 4: Present Spec for Approval

Present the validated spec to the user:

```
=== Epic Spec Ready for Review ===

**[Epic Title]**

## Context
[narrative]

## Success Criteria
- [...]

## Dependencies
[...]

Any changes before I create the epic?
```

Wait for explicit approval. If changes are requested, revise and re-run affected reviewers.

---

## Phase 3: Ticket Integration (/dso:brainstorm)

**Goal**: Create the epic in the ticket system and hand off to the next step.

### Step 1: Create the Epic

```bash
.claude/scripts/dso ticket create "<title>" -t epic -p <priority>

.claude/scripts/dso ticket comment <epic-id> "
## Context
[context narrative]

## Success Criteria
- [criterion 1]
- [criterion 2]

## Dependencies
[dependencies or 'None']

## Approach
[1-2 sentences on the chosen approach from Phase 2]
"
```

**Priority guidance:**
- P0-P1: Unblocks users from core workflows or fixes critical issues
- P2: Standard new capability with clear user value (default if unclear)
- P3-P4: Nice-to-have, low urgency

### Step 2: Set Dependencies

If the epic depends on others identified in Phase 1:

```bash
.claude/scripts/dso ticket link <this-epic-id> <blocking-epic-id> depends_on
```

### Step 3: Validate Ticket Health

```bash
$(git rev-parse --show-toplevel)/scripts/validate-issues.sh --quick --terse
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
| 2: Approach + Spec | Define how and what | Propose 2-3 options, draft spec, run 3-reviewer fidelity check |
| 3: Ticket Integration | Create the epic, classify complexity, route to next skill | `.claude/scripts/dso ticket create -t epic`, set deps, validate health, dispatch `dso:complexity-evaluator` agent (haiku, tier_schema=SIMPLE), output classification line + invoke Skill tool in same response: TRIVIAL/MODERATE+High → `/dso:implementation-plan`, MODERATE+Medium → `/dso:preplanning --lightweight`, COMPLEX → `/dso:preplanning` |
