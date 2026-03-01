---
name: brainstorm
description: Use when starting a new feature or epic — turns an idea into a defined, beads-ready epic through Socratic dialogue, approach design, and milestone spec creation.
user-invocable: true
---

# Brainstorm: Feature to Epic

Turn a feature idea into a high-fidelity beads epic through Socratic dialogue, approach design, and spec validation.

<HARD-GATE>
Do NOT invoke /sprint, /preplanning, /implementation-plan, or write any code until Phase 3 is complete and the user has explicitly approved the epic spec. This applies regardless of how simple the feature seems.
</HARD-GATE>

> **Worktree Compatible**: All commands use dynamic path resolution and work from any worktree.

**Supports dryrun mode.** Use `/dryrun /brainstorm` to preview without changes.

## Usage

```
/brainstorm                    # Start with a blank slate — describe the feature interactively
/brainstorm <epic-id>          # Enrich an existing underdefined epic
```

When invoked without an epic ID, open with: *"What feature or capability are you trying to build?"* and proceed to Phase 1.

When invoked with an epic ID, load the epic first (`bd show <epic-id>`), summarize what's already defined, then enter Phase 1 to fill gaps.

---

## Phase 1: Context + Socratic Dialogue (/brainstorm)

**Goal**: Understand the feature well enough to propose 2-3 implementation approaches.

### Step 1: Load Existing Context

Before asking any questions, silently scan for context:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
cat "$REPO_ROOT/PRD.md" 2>/dev/null || cat "$REPO_ROOT/docs/PRD.md" 2>/dev/null
cat "$REPO_ROOT/DESIGN_NOTES.md" 2>/dev/null
bd list --type=epic --status=open
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

## Phase 2: Approach + Spec Definition (/brainstorm)

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
"${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/scripts/validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller brainstorm
```

**Caller schema hash**: `f4e5f5a355e4c145`

**If a dimension scores below 4:**
- Fix the spec based on the finding
- Re-run only the failing reviewer
- Repeat until all dimensions pass, or escalate to user if conflicting guidance

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

Does this capture the right scope? Any changes before I create the epic?
```

Wait for explicit approval. If changes are requested, revise and re-run affected reviewers.

---

## Phase 3: Beads Integration (/brainstorm)

**Goal**: Create the epic in beads and hand off to the next step.

### Step 1: Create the Epic

```bash
bd epic create "<title>" -p <priority>

bd update <epic-id> --notes="
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
bd dep add <this-epic-id> <blocking-epic-id>
```

### Step 3: Validate Beads Health

```bash
$(git rev-parse --show-toplevel)/scripts/validate-beads.sh --quick --terse
```

Fix any issues before finalizing.

### Step 4: Report and Hand Off

```
=== Brainstorm Complete ===

Epic created: <epic-id> — "<title>"

Next steps:
- /preplanning <epic-id>  — decompose into user stories (recommended for complex epics)
- /sprint <epic-id>       — begin implementation (auto-triggers preplanning if needed)
```

---

## Guardrails

**One question at a time** — never present multiple questions in a single message.

**YAGNI ruthlessly** — if a capability isn't clearly needed for the stated goal, don't include it.

**Outcomes over outputs** — success criteria describe what users see and do, not what code does.

**Approaches before spec** — always propose 2-3 options and get a choice before drafting the spec.

**Fidelity gate** — the spec must pass all reviewer dimensions before presenting to the user.

**No child tasks** — this skill creates the epic only. Stories and tasks are created by `/preplanning`.

---

## Quick Reference

| Phase | Goal | Key Activities |
|-------|------|---------------|
| 1: Context + Dialogue | Understand the feature | Load PRD/DESIGN_NOTES, one question at a time, "Tell me more" loop |
| 2: Approach + Spec | Define how and what | Propose 2-3 options, draft spec, run 3-reviewer fidelity check |
| 3: Beads Integration | Create the epic | `bd epic create`, set deps, validate health, hand off |
