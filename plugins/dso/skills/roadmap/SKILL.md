---
name: roadmap
description: Use when the user wants to transform a high-level product vision, PRD, or project idea into a prioritized roadmap of epics, or when they want to brainstorm and architect project milestones
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:roadmap cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Roadmap Architect

Act as a Senior Product Manager (Google-style). Transform high-level vision into a prioritized, high-fidelity roadmap of Epics within the ticket system.


## Usage

```
/dso:roadmap    # Interactive vision-to-roadmap process
```

This command is always interactive. It guides you through 6 phases with explicit user confirmation between each phase.

**Supports dryrun mode.** Use `/dso:dryrun /dso:roadmap` to preview without changes.

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated, never blocks the skill):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

## Execution Framework

### Phase 0: Onboarding Prerequisite Check (/dso:roadmap)

**Goal**: Ensure design and architecture foundations exist before roadmap planning.

Before anything else, run the onboarding artifact check:

```bash
.claude/scripts/dso check-onboarding.sh --json
```

**If `.claude/design-notes.md` is missing** (design_onboarding.pass == false):
- Tell the user: *"Before we build a roadmap, we need a Design North Star. I'll run `/dso:onboarding` to establish one — this requires your input."*
- Invoke `/dso:onboarding` and complete the full interview flow with the user.
- After `.claude/design-notes.md` is generated and approved, continue.

**If `ARCH_ENFORCEMENT.md` is missing** (architect_foundation.pass == false):
- Tell the user: *"Before we build a roadmap, we need an architecture foundation. I'll run `/dso:architect-foundation` to establish one — this requires your input."*
- Invoke `/dso:architect-foundation` and complete the full interview flow with the user.
- After the architecture artifacts are generated and approved, continue.

**If both pass**: Proceed directly to Phase 1.

**Important**: These are interactive skills that require user input. Do NOT skip them or auto-generate the artifacts.

---

### Phase 1: Vision Expansion (The "Tell Me More" Sessions) (/dso:roadmap)

**Goal**: Understand the user's vision in depth.

1. **Context Ingestion**: Before engaging the user, scan for existing context:
   - **`PRD.md`** (project root or `docs/`): If found, read it fully. Extract the product vision, target users, key features, success metrics, and constraints. Use these to seed the conversation — reference specific PRD sections when probing deeper and suggest capabilities the user may not have mentioned yet.
   - **`.claude/design-notes.md`**: If found, extract user archetypes, golden paths, and anti-patterns to inform the discussion.
   - Any other documentation or user input provided directly.

   If a `PRD.md` exists, open the dialogue with: *"I've read your PRD. Here's what I see as the core vision: [summary]. Let me probe deeper on a few areas..."* Then proceed to the exploratory dialogue with informed follow-ups rather than starting from scratch.

2. **Review Existing State**: Check what's already in the ticket system to establish current state:
   ```bash
   .claude/scripts/dso ticket list
   .claude/scripts/dso ticket list
   ```

3. **Exploratory Dialogue**: Initiate a brainstorming session with the user.
   - **The "Tell Me More" Loop**: When the user shares an idea, use the phrase: **"Tell me more about [concept]..."** to encourage depth.
   - **Value Extraction**: Probe for the specific user problem or business value behind every feature. Ask: *"What specific problem does this solve for users?"* or *"What business outcome does this enable?"*
   - **Scope**: Focus on the **ideal state**. Do not restrict the vision based on dates or perceived scarcity yet.

4. **Keep asking** until the user has articulated:
   - The core problem being solved
   - The users/stakeholders affected
   - The business value or impact
   - Key capabilities or features needed

**Phase Gate**: Ask the user: *"Have we captured all the major capabilities you envision? Or is there more to explore?"*

Do NOT proceed to Phase 2 until the user confirms the vision is complete.

---

### Phase 2: Milestone Architecture (High Fidelity) (/dso:roadmap)

**Goal**: Structure the vision into clear, actionable Milestones (Epics).

1. **Drafting**: Synthesize the brainstorm into logical **Milestones** (Epics). Group related capabilities together.

2. **Fidelity Check**: For each Milestone, draft a "Spec Definition" including Context (the narrative "Why"), Success Criteria (testable deliverables), then read [docs/review-criteria.md](docs/review-criteria.md) for reviewer configuration and invoke `/dso:review-protocol` with:
   - **subject**: "Milestone: {milestone title}"
   - **artifact**: The Milestone's spec definition (context + success criteria)
   - **pass_threshold**: 4
   - **start_stage**: 1
   - **perspectives**: (defined in separate reviewer files — see `docs/review-criteria.md`)
     - [../shared/docs/reviewers/agent-clarity.md](../shared/docs/reviewers/agent-clarity.md) — perspective: `"Agent Clarity"`
     - [../shared/docs/reviewers/scope.md](../shared/docs/reviewers/scope.md) — perspective: `"Scope"`
     - [../shared/docs/reviewers/value.md](../shared/docs/reviewers/value.md) — perspective: `"Value"`

   Incorporate findings into the Milestone spec before presenting to the user.

3. **User Verification**: Present the draft list of Milestones to the user. For each Milestone, show:
   - Title
   - Brief context (1-2 sentences)
   - Success criteria (bullet list)

4. **Confirmation**: Ask the user: *"Do these Milestones capture the right 'Success States' for your vision? Should we adjust, merge, or split any of them?"*

**Phase Gate**: Do NOT proceed to Phase 2.5 until the user confirms the Milestones are correct.

---

### Phase 2.5: Scrutiny Decision (/dso:roadmap)

**Goal**: Decide once whether to apply the full scrutiny pipeline to each epic during Phase 5.

Ask the user **exactly once**:

> "Would you like to apply full scrutiny (gap analysis, web research, scenario analysis, fidelity review) to each epic? This produces higher-quality specs but takes longer. [y/n]"

Store the answer as a session variable `SCRUTINY_OPT_IN` (true/false). Do **NOT** re-ask this question for each epic — the answer applies for the entire roadmap session.

**Phase Gate**: Do NOT proceed to Phase 3 until the user answers the scrutiny question.

---

### Phase 3: Visual Prioritization & Dependency Logic (/dso:roadmap)

**Goal**: Prioritize Milestones based on value and effort, accounting for dependencies.

1. **Informed Guess Scoring**: The Agent (not the user) will estimate scores for each Milestone by reading and applying the shared scorer at `skills/shared/prompts/value-effort-scorer.md`. Use the **1-5 scale** defined there:
   - **Value (1-5)**: How much user or business impact does this deliver? (1=minimal, 5=critical)
   - **Effort (1-5)**: How complex or time-consuming is this to build? (1=trivial, 5=multi-sprint)

   Apply the scorer's priority matrix to derive a recommended P0–P4 priority for each Milestone. Present your scoring rationale and the resulting priority for each Milestone.

2. **The "Enabler" Logic**: Identify hard technical dependencies. If a low-value Epic blocks a high-value Epic, it is marked as a **"Critical Enabler"** and inherits the priority of the feature it unlocks.

   Example:
   - Epic A: "User Dashboard" (Value: 5, Effort: 3)
   - Epic B: "Authentication System" (Value: 3, Effort: 4)
   - If Dashboard requires Authentication → Authentication becomes a **Critical Enabler** with inherited priority

   **Note**: Enabler Logic **overrides** the scorer recommendation — enablers inherit the priority of the epic they unblock, regardless of their own value/effort scores.

3. **The Visual Matrix**: Present the roadmap as a visual quadrant:

```
Impact vs Effort Matrix:
  Quick Wins      (High Impact, Low Effort)  → Top priority
  Strategic Bets  (High Impact, High Effort) → Plan carefully
  Fill-ins        (Low Impact, Low Effort)   → Do if time permits
  Avoid/Later     (Low Impact, High Effort)  → Defer or eliminate
```

Present each Milestone as a "Post-it Note" in the appropriate quadrant:
- **Quick Wins** (High Impact, Low Effort): Top priority
- **Strategic Bets** (High Impact, High Effort): Important but plan carefully
- **Fill-ins** (Low Impact, Low Effort): Do if time permits
- **Avoid/Later** (Low Impact, High Effort): Defer or eliminate

Example output:
```
QUICK WINS (High Impact, Low Effort):
  - Epic: User Profile Page (Value: 4, Effort: 2) → P1
  - Epic: Export to CSV (Value: 4, Effort: 1) → P0

STRATEGIC BETS (High Impact, High Effort):
  - Epic: Document Processing Pipeline (Value: 5, Effort: 5) [Critical Enabler] → P1
  - Epic: Admin Dashboard (Value: 5, Effort: 4) → P1

FILL-INS (Low Impact, Low Effort):
  - Epic: Dark Mode (Value: 2, Effort: 2) → P3

AVOID/LATER (Low Impact, High Effort):
  - Epic: Advanced Analytics (Value: 2, Effort: 4) → P4
```

The quadrant placement maps to priority ranges: Quick Wins → P0–P1, Strategic Bets → P1–P2, Fill-ins → P3, Avoid/Later → P4. Use the scorer's matrix for the exact P-level within each quadrant.

4. **Alignment Check**: Ask the user: *"I've categorized these based on our talk. Do you agree with these placements, or should we shift any 'Post-its'?"*

**Phase Gate**: Do NOT proceed to Phase 4 until the user confirms the prioritization is correct.

---

### Phase 4: Lightweight Pre-Mortem (High-Priority Only) (/dso:roadmap)

**Goal**: Identify risks for top priorities and build mitigation into the Success Criteria.

1. **Risk Identification**: Take the **top 3-4 prioritized Epics** (Quick Wins and top Strategic Bets).

2. **The Prompt**: For each top Epic, ask the user: *"Imagine we are three months in the future and [Top Epic] has completely failed. What is the most likely reason why?"*

3. **Mitigation**: Based on the user's answers, update the Success Criteria for those specific Epics to account for the identified risks.

   Example:
   - Risk: "Authentication system gets hacked"
   - Mitigation: Add to Success Criteria: "Security audit completed, OWASP Top 10 vulnerabilities addressed, rate limiting implemented"

4. **Document Risks**: For each top Epic, add a "Risks & Mitigations" section to the Spec Definition.

**Phase Gate**: Do NOT proceed to Phase 5 until the user confirms the mitigations are sufficient.

---

### Phase 5: Execution & Ticket Integration (/dso:roadmap)

**Goal**: Create the Epics in the ticket system with high-fidelity specifications.

1. **Final Alignment Pass**: Perform a final **Agent Alignment Test** on all Epic descriptions to ensure they are "Source of Truth" ready for development agents.

   For each Epic, verify:
   - Could a developer agent understand this with no additional context?
   - Are Success Criteria specific and testable?
   - Are dependencies clearly documented?

2. **Ticket Action**: Create Epics using the sequence: **"Phase [X]: [Name]"**. Use the scorer-determined priority (from Phase 3 Step 1) as the `--priority <priority>` argument. For Critical Enabler epics, use the priority inherited from the epic they unblock.

   ```bash
   # Create epic with scorer-determined priority
   # $SCORER_PRIORITY is the P-level from value-effort-scorer.md (P0=0, P1=1, ... P4=4)
   .claude/scripts/dso ticket create epic "Phase 1: Authentication System" --priority $SCORER_PRIORITY -d "$(cat <<'DESCRIPTION'
   ## Context
   [Why this matters, user need, business goal]

   ## Success Criteria
   - [Specific, testable deliverable 1]
   - [Specific, testable deliverable 2]
   - [Specific, testable deliverable 3]

   ## Risks & Mitigations
   [For top-priority epics only]

   ## References
   [Links to PRDs, designs, or related docs]
   DESCRIPTION
   )"
   ```

3. **Scrutiny Step** (per-epic, inline — not batched): After each epic ticket is created, apply the scrutiny decision from Phase 2.5:

   - **If `SCRUTINY_OPT_IN` is true**: Read and execute the shared scrutiny pipeline from `skills/shared/workflows/epic-scrutiny-pipeline.md`. Pass `caller_name=roadmap` and `caller_prompts_dir=skills/brainstorm/prompts` as the pipeline parameters (scenario analysis prompts are shared from brainstorm's prompts directory). Run scrutiny inline for each epic before moving to the next. Append scrutiny output (gap analysis, scenario analysis, fidelity review verdict) to the epic spec via ticket edit before continuing.

   - **If `SCRUTINY_OPT_IN` is false**: Write the `scrutiny:pending` tag to signal that the epic has not been scrutinized:
     ```bash
     .claude/scripts/dso ticket tag <epic-id> scrutiny:pending
     ```
     This marks the epic for downstream skills (`/dso:preplanning`, `/dso:implementation-plan`) to gate on per the `docs/contracts/scrutiny-pending-tag.md` contract.

4. **Set Dependencies**: Link epics formally within the ticket system for "Critical Enabler" relationships.

   ```bash
   .claude/scripts/dso ticket link <blocked-epic-id> <blocking-epic-id>
   ```

5. **Constraint**: Do NOT create child tasks. Maintain the high-level strategic structure. Child tasks will be created later during sprint planning.

6. **Validate Ticket Health**: After creating all epics and dependencies:

   ```bash
   .claude/scripts/dso validate-issues.sh
   ```

   If score < 5, fix issues before finalizing.

7. **Report**: Present the final roadmap to the user:
   - List of all created Epics (IDs and titles)
   - Dependency graph (which epics block which)
   - Priority order (Quick Wins first, then Strategic Bets)

**Phase Gate**: Present the report. Roadmap is complete.

**Next steps for the user**:
- Use `/dso:preplanning <epic-id>` to decompose an epic into stories
- Use `/dso:sprint <epic-id>` to begin implementation (auto-triggers preplanning if needed)

---

## Guardrails

### Sequential Progress
- **NEVER move to the next phase without explicit user confirmation.**
- Each phase ends with a "Phase Gate" question. Wait for the user to respond before proceeding.

### Cognitive Load Management
- **Always provide "informed guesses"** for scores, priorities, and categorizations rather than asking the user to generate them from scratch.
- The user should validate and adjust, not create from a blank slate.

### Scope Control
- **Do NOT create child tasks** under epics. Epics remain high-level strategic milestones.
- Child tasks are created later via `/dso:preplanning <epic-id>` or `/dso:sprint <epic-id>`.

### Fidelity Standard
- **Agent Alignment Test**: Every Epic description must be clear enough for a developer agent to understand with no additional context.
- If you wouldn't trust a junior developer to build the right thing from the description alone, add more detail.

---

## Phase Gate Pattern

After each phase, use this format:

```
=== Phase [N] Complete ===

[Summary of what was accomplished in this phase]

PHASE GATE QUESTION:
[Specific confirmation question from the phase]

Do NOT proceed until user responds.
```

---

## Quick Reference

| Phase | Purpose | Key Activities |
|-------|---------|----------------|
| 0 | Onboarding Check | Run `check-onboarding.sh`, invoke missing skills |
| 1 | Vision Expansion | "Tell me more" loop, value extraction |
| 2 | Milestone Architecture | Draft epics, define success criteria, agent alignment test |
| 2.5 | Scrutiny Decision | One-time opt-in question for full scrutiny pipeline per epic |
| 3 | Visual Prioritization | Score value/effort, identify enablers, quadrant matrix |
| 4 | Lightweight Pre-Mortem | Identify risks for top 3-4 epics, build mitigations |
| 5 | Execution & Ticket Integration | Create epics in ticket system, apply scrutiny or write scrutiny:pending tag, set dependencies, validate health |

## Example Interaction Flow

```
User: "I want to build a document processing system."

Agent: "Tell me more about what you want this document processing system to do..."

[Phase 1 dialogue continues until vision is clear]

Agent: "=== Phase 1 Complete ===
Based on our discussion, I understand you want a system that:
- Accepts PDF uploads
- Extracts structured data
- Generates policy rules
- Provides admin oversight

Have we captured all the major capabilities you envision? Or is there more to explore?"

User: "That covers it."

Agent: [Proceeds to Phase 2, drafts Milestones]

[And so on...]
```
