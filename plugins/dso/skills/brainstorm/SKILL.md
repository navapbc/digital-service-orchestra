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

Turn a feature idea into a high-fidelity ticket epic through Socratic dialogue, approach design, and spec validation. The approval gate includes a provenance annotation summary line showing how many criteria are confirmed vs. inferred before presenting options.

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

When invoked with a free-text description (argument present but does not match the ticket ID format `[a-z0-9]{4}-[a-z0-9]{4}`), treat the argument as seeding context and immediately begin the Socratic dialogue at Phase 1. Do NOT show the epic selection list. Open with: *"Got it — I'll use that as our starting point. Let me ask a few questions to sharpen the scope."* then proceed to Phase 1 Step 2 with the user's text as the established problem statement seed.

When invoked without a ticket ID, run:

```bash
.claude/scripts/dso sprint-list-epics.sh --max-children=0
```

If the command returns one or more epics, present a numbered selection list of those epics plus a "start fresh" option (always last). Also display below the list the count of epics that have one or more children (i.e., epics excluded from the list because they already have child tickets). Wait for the user to choose; if they select an existing epic, proceed as if invoked with that epic's ticket ID. If they select "start fresh", open with: *"What feature or capability are you trying to build?"* and start the Socratic dialogue.

If the command returns zero epics (no 0-child epics exist), automatically fall through to the fresh dialogue: open with *"What feature or capability are you trying to build?"* and start the Socratic dialogue.

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

**If `ticket_type` is `epic`:** Load the epic, summarize what's already defined, then proceed to Phase 1 unchanged. The epic dialogue and output behavior is semantically unchanged — this check is a pre-flight type check only.

**If `ticket_type` is not epic** (i.e., `story`, `task`, or `bug`): Present the following two options to the user:

```
This ticket is a <story|task|bug>, not an epic. How would you like to proceed?

(a) Convert to epic — close the original ticket as superseded and run the full brainstorm flow
    to create a new, well-defined epic from the ideas in this ticket.

(b) Enrich in-place — run a streamlined enrichment dialogue to flesh out this ticket's
    description, success criteria, and approach without converting it to an epic.
```

**Option (a) — Convert to epic:**
Proceed to the Convert-to-Epic Path section below.

**Option (b) — Enrich in-place:**
Proceed to the Enrich-in-Place Path section below.

---

## Convert-to-Epic Path

Use this path when the user selects **Option (a)** from the Type Detection Gate — converting a non-epic ticket into a new, well-defined epic via the full brainstorm flow.

**Summary of this path:** (1) Record the original ticket ID and content for traceability. (2) Proceed to Phase 1 immediately with the original content as seeding context — the full brainstorm flow creates a new epic. (3) ONLY AFTER the new epic is successfully created: use `ticket transition ... closed --reason="Escalated to user: superseded by epic <new-epic-id>"` to close the original ticket. (4) Use `ticket edit` (or a comment) on the new epic to reference the original ticket ID for traceability. Bug tickets require `--reason="Escalated to user: superseded by epic <new-epic-id>"`. Tickets with open children: re-parent children to the new epic or close them before closing the original.

**Step 1 — Note the original ticket.** Run `.claude/scripts/dso ticket show <original-ticket-id>` and capture the original ticket ID, title, description, and any comments. This content seeds Phase 1.

**Step 2 — Proceed to Phase 1 with seeding context.** Begin Phase 1 (Context + Socratic Dialogue) immediately, using the original ticket's content as seeding context. Do NOT close the original ticket yet.

**Step 3 — Complete the full brainstorm flow.** Run Phases 1, 2, and 3 in full. Phase 3 creates the new epic. The new epic is "successfully created" when Phase 3 Step 1 (`.claude/scripts/dso ticket create epic ...`) completes without error and returns a new epic ID.

**Step 4 — Close the original ticket (ONLY AFTER new epic is successfully created).** Only after the new epic has been successfully created, close the original:

```bash
# All ticket types (story, task, bug):
.claude/scripts/dso ticket transition <original-ticket-id> <current-status> closed \
  --reason="Escalated to user: superseded by epic <new-epic-id>"
```

The `--reason` flag is required. Bug tickets must use the `Escalated to user:` prefix — omitting it causes a silent failure.

**Step 5 — Add traceability reference to the new epic.** After closing the original ticket, reference the original ticket ID in the new epic description for traceability:

```bash
.claude/scripts/dso ticket comment <new-epic-id> \
  "Converted from original ticket <original-ticket-id> (reference original ticket ID for traceability)."
```

**Edge case — tickets with open children.** If the original ticket has open child tickets, handle them before closing the original: re-parent open children to the new epic (`.claude/scripts/dso ticket link <child-id> <new-epic-id> depends_on`), or close irrelevant children with `--reason="Escalated to user: superseded by epic <new-epic-id>"`. Only after all open children are resolved, proceed with Step 4.

---

## Enrich-in-Place Path

Use this path when the user selects **Option (b)** from the Type Detection Gate — enriching an existing non-epic ticket with structured acceptance criteria, approach, and file paths without converting it to an epic.

**Ticket type is preserved throughout this path — do not convert, close, or recreate the original ticket. The original type remains unchanged.**

**Step 1 — Load ticket content.** Run `.claude/scripts/dso ticket show <ticket-id>` and read the existing description, title, and type. Summarize what is already defined so the enrichment dialogue is targeted, not redundant.

**Step 2 — Streamlined Socratic dialogue.** Ask **1-3 targeted questions** to clarify intent — this is NOT the full Phase 1 multi-area probe. Use one question at a time (same rule as Phase 1). Focus only on gaps that prevent writing structured acceptance criteria or a clear approach. Good targets: "What does done look like?", "Which file or module is the entry point?", "Are there edge cases that matter?". Stop asking once you can draft meaningful acceptance criteria and an approach summary.

**Step 3 — Update the ticket description.** Update the existing ticket's description field using `ticket edit --description` — do not post a comment. Replace the description with enriched content including: structured acceptance criteria (Given/When/Then format or bullet checklist), an approach summary (1-2 sentences on how to implement this), and relevant file paths (use Glob/Grep to resolve any module or directory references from the ticket to actual repo paths; include only paths that exist).

**Step 4 — Present and stop.** Present the updated ticket content to the user and stop. Do not route to downstream skills.

**Explicitly skip the following** (these apply to the full brainstorm → epic flow only, not the enrich-in-place path):

- Skip fidelity review (Step 2.5/3 gap analysis and reviewer agents)
- Skip scenario analysis (Step 2.75 red/blue team review)
- Skip web research phase (Step 2.6)
- Skip ticket creation (Phase 3) — the ticket already exists; no new ticket is needed
- Skip complexity evaluation (Phase 3, complexity evaluator dispatch)
- Skip routing to downstream skills — do not invoke `/dso:preplanning` or `/dso:implementation-plan`
- Skip writing the brainstorm completion sentinel (Step 3b) — **REVIEW-DEFENSE**: enrich-in-place is used on existing tickets that are already defined, not on new features being scoped from scratch. The brainstorm-before-plan-mode enforcement is designed to ensure new ideas are properly scoped before entering plan mode. When enriching an existing ticket, the user is refining something already in the system — not discovering and framing a new feature — so the sentinel gate correctly does not apply to this path.

Example `ticket edit --description` command structure (replace placeholder values):

```
.claude/scripts/dso ticket edit <id> --description="
Summary: [Original or refined one-sentence summary of the ticket]

Acceptance Criteria:
- Given [context], when [action], then [outcome]
- [ ] [Verifiable condition 1]
- [ ] [Verifiable condition 2]

Approach Summary:
[1-2 sentences on how to implement this — the concrete mechanism, not just the goal]

Relevant Files:
- path/to/relevant/file.py
- path/to/another/module.sh
"
```

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

**Investigate before asking**: Before presenting any question to the user, check whether the answer is discoverable by reading the codebase (existing skills, ARCH_ENFORCEMENT.md, pyproject.toml, project-understanding.md, module structure). Only ask the user questions whose answers cannot be found in the repo. Questions about design approach, user experience preferences, or business priorities are appropriate for the user; questions about existing implementations, available tools, or project structure are not.

**Exploration decomposition**: When a context question is compound or spans multiple sources (web research, multiple codebase layers, ambiguous scope), apply the shared exploration decomposition protocol at `plugins/dso/skills/shared/prompts/exploration-decomposition.md` to classify it as SINGLE_SOURCE or MULTI_SOURCE before proceeding. Emit DECOMPOSE_RECOMMENDED when a factor is unspecified or two findings contradict.

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

When you have enough to propose approaches, transition to Phase 2 via this 3-step sequence. The gate covers: (1) a structured **Understanding Summary** covering problem, users, scope, and success that waits for user confirmation; (2) an **Intent Gap Analysis** asking one question at a time about inferred or assumed content (at most 3 questions total); and (3) proceeding to Phase 2.

**Step 1 — Understanding Summary**: Produce a structured summary of what you understand so far and wait for user confirmation before proceeding to the gap analysis.

Present the summary as a brief bulletin:

```
Before we move to approaches, here's my understanding:

- **Problem**: [what specific problem this solves]
- **Users**: [who is affected — user type, role, or persona]
- **Scope**: [what's in scope; what's explicitly out of scope]
- **Success**: [how the user will know this worked — observable outcome]

Does this capture your intent? If anything is off, tell me what to adjust.
```

Wait for confirmation before proceeding. This confirmation step is separate from the gap analysis that follows — always proceed to the gap analysis after confirmation.

**Step 2 — Intent Gap Analysis**: After the user confirms the understanding summary, self-reflect on inferred or assumed content — items you filled in that the user did not explicitly state. Ask one question at a time, targeting the highest-priority gap first. Exclude already-confirmed content (anything the user explicitly stated or confirmed in Step 1 above) from gap questions.

Format for each gap question:
```
Before I propose approaches: [Targeted gap question]

(You can skip and proceed — just say "proceed" to continue)
```

**Bounded gap loop**: Ask at most 3 questions total, one at a time. After each answer, ask the next highest-priority gap question (if any remain) or proceed to Phase 2. If the user wants to continue refining after the initial set, they can opt-in by asking for more questions or clarifying further. Do not loop indefinitely.

Do NOT proceed to Phase 2 until the user confirms the understanding summary or explicitly skips the gap analysis.

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
- Each must be verifiable within the sprint session — the pass/fail verdict must be renderable before the sprint closes. Adding observability tooling (dashboards, metrics instrumentation) is valid sprint work; deferring the measurement itself to post-deployment is not
- Describe outcomes, not implementation ("Users can download results as CSV" not "Implement CSV export endpoint")
- At least one criterion should hint at a validation signal — how you'll know the capability is actually being used

**Context narrative rules:**
- Name the specific user or stakeholder affected
- Describe the problem they face today (without this feature)
- Avoid jargon without explanation

### Provenance Tracking

As you draft the epic spec, classify the origin of each success criterion and key context claim using one of four provenance categories:

- **explicit** — stated directly by the user in their own words
- **confirmed-via-gap-question** — inferred by you, then confirmed by the user during gap analysis (Phase 1 Gate Step 2)
- **inferred** — derived by you from context without explicit user confirmation
- **researched** — sourced from web research or external reference material (Step 2.6)

Track provenance internally — you will use these categories in Step 4 to annotate the rendered spec.

### Steps 2.5, 2.6, 2.75, and Step 3: Epic Scrutiny Pipeline

Read and execute the shared epic scrutiny pipeline from `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md`. Pass the current epic spec (Context + Success Criteria + Approach) as input, and supply the required pipeline parameters:

- `{caller_name}` = `brainstorm`
- `{caller_prompts_dir}` = `$REPO_ROOT/plugins/dso/skills/brainstorm/prompts`

#### Step 2.5 Supplement: Gap Analysis and ast-grep Pattern Discovery for Technical Self-Review

**Gap analysis reminder**: The scrutiny pipeline's Step 2.5 (gap analysis) cross-references user-named artifacts — file paths, CLI tools, data structures, API endpoints, config keys — against the success criteria text. For each user-named artifact, check whether it appears directly or by fuzzy/partial match (including abbreviations, aliases, and variant phrasing) in any success criterion. Flag any artifact named in the request that is absent from or not covered by the SCs, then ask the user whether the SCs are exhaustive relative to what they asked for.

**During Part B (Technical Approach Self-Review)** of the scrutiny pipeline's Step 1, use `sg` (ast-grep) for structural pattern matching when discovering existing codebase patterns that bear on technical feasibility. Structural search finds real code references rather than string matches, improving the accuracy of feasibility assessments.

Before invoking `sg`, check availability with the canonical guard:

```bash
if command -v sg >/dev/null 2>&1; then
    # Use sg for structural pattern search
    sg --pattern '<pattern>' --lang <lang> /path/to/search
else
    # Fall back to Grep tool or grep command
    grep -r '<pattern>' /path/to/search
fi
```

**When to apply during Technical Self-Review**:
- When validating whether the proposed approach conflicts with existing patterns (e.g., find all callers of a function that would need to change)
- When checking whether an assumed dependency is already imported or sourced across files
- When tracing bidirectional data flow to detect potential sync loops or race conditions

Graceful degradation: if `sg` is not installed, use the Grep tool (preferred in Claude Code) or `grep -r` as an equivalent fallback. Do not block the review if neither produces results — log the pattern attempted and continue.

#### FEASIBILITY_GAP Handler (post-pipeline)

After the scrutiny pipeline returns, check whether the epic spec contains a `## FEASIBILITY_GAP` section (annotated by the pipeline's Step 4 when the feasibility reviewer reports any score below 3).

**If FEASIBILITY_GAP is present:**

1. Read `brainstorm.max_feasibility_cycles` from `dso-config.conf` (default: 2 when absent).
2. Initialize or increment `feasibility_cycle_count` (starts at 0, incremented on each re-entry).
3. **If `feasibility_cycle_count < max_feasibility_cycles`**: Re-enter Phase 1 (understanding loop) with the gap context as seeding material. Log: `"FEASIBILITY_GAP detected — re-entering Phase 1 understanding loop (cycle {feasibility_cycle_count}/{max_feasibility_cycles})."` After the user provides additional context or clarification, re-run the scrutiny pipeline and check again.
4. **If `feasibility_cycle_count >= max_feasibility_cycles`**: Escalate to the user. Present the unresolved gap and ask whether to proceed with the gap noted, abort, or manually adjust the spec. Log: `"FEASIBILITY_GAP unresolved after {max_feasibility_cycles} cycles — escalating to user."`
5. Expose `feasibility_cycle_count` as a named state variable for Story 4 (7067-dae6) to consume in the log extensions.

**If FEASIBILITY_GAP is NOT present:** Continue to Step 4 (Approval Gate) normally.

### Step 4: Approval Gate

<HARD-GATE>
Do NOT present this gate unless ALL of the following have completed or gracefully degraded with a logged rationale:
- Step 2.5: Gap analysis (self-review)
- Step 2.6: Web research phase (run OR skipped with a logged rationale per Step 2.6 graceful degradation rules)
- Step 2.75: Scenario analysis (run OR skipped because ≤2 success criteria)
- Step 3: Fidelity review (all three core reviewers completed or escalated to user)

If any of the above has NOT completed, stop and execute it before presenting this gate. The user's ability to request a re-run via option (b) or (c) is for second-pass cycles only — it does not substitute for a mandatory first pass.
</HARD-GATE>

Present the validated spec to the user using **AskUserQuestion** with 4 options. Label options (b) and (c) to reflect whether this is a first re-run or subsequent re-run (the scrutiny pipeline must complete before this gate; these labels apply only to gate-triggered re-runs):

- **If web research (Step 2.6) ran during the mandatory pipeline pass**: label (c) as "Re-run web research phase"
- **If web research was skipped via graceful degradation (no bright-line triggers fired)**: label (c) as "Perform additional web research" (note: this is a first-time run, not a re-run)
- **If scenario analysis (Step 2.75) ran during the mandatory pipeline pass**: label (b) as "Re-run red/blue team review cycle"
- **If scenario analysis was skipped via graceful degradation (≤2 success criteria)**: label (b) as "Perform red/blue team review cycle" (note: this epic has ≤2 success criteria — consider adding more before running scenario analysis)

**Provenance annotation rendering**: Before presenting success criteria, render each criterion with a bold/normal annotation based on its provenance:
- **inferred** or **researched** criteria → render in **bold** (visually prominent — these require user review)
- **explicit** or **confirmed-via-gap-question** criteria → render in normal text (user already confirmed these)

Immediately before the option list, include an annotation summary line in this format:
```
N of M criteria confirmed; K inferred requiring review
```
where N = count of explicit + confirmed-via-gap-question criteria, M = total criteria count, K = count of inferred + researched criteria. This provenance summary line appears before the (a)/(b)/(c)/(d) options.

Note: summary confirmation (Phase 1 Gate Step 1) does NOT collapse with gap analysis (Phase 1 Gate Step 2) — they are always presented as separate steps.

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

(a) Approve — advance to Phase 3 Step 0 (Follow-on Epic Gate), then Step 1 (Ticket Creation)
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

After the user approves (option a), append a planning-intelligence log to the epic spec comment that will be written in Phase 3.

Log format to append (the heading is **Planning Intelligence Log**, level 3):

```
### Planning Intelligence Log

- **Web research (Step 2.6)**: [not triggered | triggered | re-triggered via gate]
  - Bright-line conditions that fired: [list conditions, or "none"]
- **Scenario analysis (Step 2.75)**: [not triggered | triggered | re-triggered via gate]
  - Scenarios surviving blue team filter: [count, or "skipped — ≤2 success criteria"]
- **Practitioner-requested additional cycles**: [none | web research re-run N time(s) | scenario analysis re-run N time(s) | both re-run]
- **Follow-on scrutiny (Step 0)**: [not triggered | triggered — depth: <follow_on_scrutiny_depth>]
- **Feasibility resolution (Step 2.5)**: [not triggered | triggered — cycles: <feasibility_cycle_count>, gap: <triggering gap description>]
- **LLM-instruction signal (Step 5)**: [not triggered | triggered — keyword: <matched_keyword>]
```

---

## Phase 3: Ticket Integration (/dso:brainstorm)

**Goal**: Create the epic in the ticket system and hand off to the next step.

**Clean-text instruction**: Strip all provenance markers and bold emphasis before writing the ticket description. Provenance annotations are used only during the approval-gate review phase — the final ticket description must be written as clean plain text with no markup from the provenance tracking step.

### Step 0: Follow-on and Derivative Epic Gate (/dso:brainstorm)

<HARD-GATE>
Do NOT call `ticket create` for any follow-on or derivative epic until the user has explicitly approved that epic's title, description, and success criteria in a separate approval step. Do NOT treat directional approval of the primary epic (Phase 2 Step 4, option a) as approval for any follow-on epic.
</HARD-GATE>

**When this gate applies**: A follow-on or derivative epic exists whenever:
- The scope reviewer recommended splitting the primary epic and identified a second epic (Epic B).
- The user made a directional statement requesting a future epic (e.g., "we should create a follow-up epic for X").
- You identified a related epic during Phase 1 or Phase 2 that was out of scope for the primary epic.

**Procedure for each follow-on epic** (execute before Step 1 for each follow-on, one at a time):

**State variables** (initialize at the start of each follow-on):
- `request_origin`: set to `"scope-split"` if the scope reviewer recommended splitting the primary epic (Part A / Part B pattern); set to `"user"` otherwise (user directional statement or agent-identified related epic).
- `follow_on_depth`: **Always reset to `0` before processing each follow-on epic in this session.** Exception: if this brainstorm session was itself invoked on a follow-on epic (i.e., `/dso:brainstorm` was called from within a follow-on epic context), set `follow_on_depth = parent_depth + 1` instead. Within a single session, every follow-on is a direct follow-on at depth 0 — do NOT carry over the depth value from the previous follow-on you just processed. Default: `follow_on_depth = 0`.

**Depth cap — stub path (follow_on_depth >= 1)**:
If `follow_on_depth >= 1`, do NOT run the scrutiny pipeline. Present the follow-on as a stub with this stub title and context format:
```
Follow-on epic stub: "[Title]"
Context: [1-2 sentence description]
Proposed success criteria:
- [criterion 1]
- [criterion 2]
Note: This follow-on epic needs `/dso:brainstorm` before implementation (depth-capped stub — scrutiny skipped).
Shall I create this as a ticket stub? (yes / no / let's refine it)
```
Wait for the user's response before calling `ticket create`. If approved, create the epic ticket without running scrutiny. If the user says "no" or requests refinement, update the spec or skip creation accordingly.

**Full scrutiny path (follow_on_depth == 0)**:
1. **Determine request_origin and pre-strip Part A artifacts if needed**: If `request_origin` is `"scope-split"`, pre-strip Part A artifact references from the seeding material before drafting the follow-on spec. This prevents the primary epic's (Part A) content from bleeding into the follow-on scope. Exclude or skip Part A content when seeding the follow-on spec — only use Part B and scope-reviewer recommendations.
2. **Draft the follow-on epic spec**: title, 1-2 sentence context, and 2-4 proposed success criteria. Seed from the scope reviewer's recommendation or the user's directional statement — do not invent scope.
3. **Invoke the epic scrutiny pipeline**: Run the shared scrutiny pipeline at `plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md` on the drafted follow-on epic spec, passing:
   - `{caller_name}` = `brainstorm`
   - `{caller_prompts_dir}` = `$REPO_ROOT/plugins/dso/skills/brainstorm/prompts`
4. **Present with scrutiny results and wait for explicit approval**:
   ```
   Follow-on epic proposed: "[Title]"
   Context: [1-2 sentence description]
   Proposed success criteria:
   - [criterion 1]
   - [criterion 2]
   Scrutiny results: [summary of gap analysis, scenario analysis findings]
   Shall I create this as a separate epic? (yes / no / let's refine it)
   ```
   Wait for the user's response before calling `ticket create`. If the user says "no" or requests refinement, update the spec or skip creation accordingly.

**Planning-intelligence log entry**: After processing each follow-on epic, record:
- `follow_on_scrutiny_depth` = `<follow_on_depth value>` (named state variable for orchestrator/sub-agent inspection)

### Step 1: Create or Update the Epic

**If an existing epic ID was passed as input** (i.e., the Type Detection Gate identified `ticket_type: epic`): do NOT call `ticket create`. Instead, update the existing epic's description with the refined spec from Phase 2:

```bash
.claude/scripts/dso ticket edit <epic-id> --description "$(cat <<'DESCRIPTION'
## Context
[context narrative]

## Success Criteria
- [criterion 1]
- [criterion 2]

## Dependencies
[dependencies or 'None']

## Approach
[1-2 sentences on the chosen approach from Phase 2]

## Scenario Analysis
{scenario analysis content from scrutiny pipeline, if generated}
DESCRIPTION
)"
```

**If no existing epic** (i.e., this is a new brainstorm or the original ticket was not epic — i.e., you arrived here via the Convert-to-Epic path): create the epic:

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

## Scenario Analysis
{scenario analysis content from scrutiny pipeline, if generated}
DESCRIPTION
)"
```

**Priority guidance (new epics only):** Before creating the ticket, read and apply the value/effort scorer from `plugins/dso/skills/shared/prompts/value-effort-scorer.md`. Assess the epic's value (1-5) and effort (1-5) based on the conversation context, map to the recommended priority via the scorer's matrix, and use that priority with `-p <priority>` in the ticket create command above.

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

### Step 3b: Write Brainstorm Completion Sentinel

Write a sentinel file to record that brainstorm has completed for this session. This file is checked by the EnterPlanMode PreToolUse hook to enforce brainstorm-before-plan-mode.

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
echo "brainstorm-complete" > "$ARTIFACTS_DIR/brainstorm-sentinel"
```

This must be the last Phase 3 action before downstream skill invocation. If brainstorm crashes after this write but before completion, the sentinel is a false certificate — but this is an acceptable trade-off vs. not writing a sentinel at all.

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
    success_criteria_count: <count of SC bullet items in the approved spec from Phase 2>
    scenario_survivor_count: <count of scenarios surviving blue team filter from Step 2.75, or 0 if Step 2.75 did not run>
```

Compute `success_criteria_count` by counting the bullet items in the `## Success Criteria` section of the approved spec. Read `scenario_survivor_count` from the Planning-Intelligence Log entry recorded at Step 4 approval (or 0 if the scrutiny pipeline did not run scenario analysis).

If the agent fails or returns malformed JSON (not parseable or missing the `classification` key), log a warning and fall through to full `/dso:preplanning` (full mode is the safe fallback default).

#### Step 4b: Route Based on Classification

Apply the brainstorm routing rule to the shared rubric's output using the routing table below. **Always consult the table** — do NOT skip preplanning based on prose heuristics. Only TRIVIAL epics bypass preplanning; MODERATE and COMPLEX epics always route through preplanning (lightweight or full).

**Session-signal override** (applies before the routing table): If EITHER of the following is true, override the evaluator's classification to COMPLEX regardless of its output:
- `success_criteria_count ≥ 7` — count the bullet items in the `## Success Criteria` section of the approved spec (re-count from the spec text, do NOT rely on session memory which may be lost after compaction)
- `scenario_survivor_count ≥ 10` — read from the Planning-Intelligence Log entry written at Step 4 approval; if the log is unavailable (compacted), read from the `## Scenario Analysis` section of the approved spec and count surviving scenarios

Log the override: `"Epic classified as COMPLEX (session-signal override: <reason>) — invoking /dso:preplanning"`

| Classification | scope_certainty | Routing |
|---|---|---|
| TRIVIAL | High (always) | `/dso:implementation-plan <epic-id>` |
| MODERATE | High | `/dso:preplanning <epic-id> --lightweight` |
| MODERATE | Medium | `/dso:preplanning <epic-id> --lightweight` |
| MODERATE | Low | Promoted to COMPLEX by evaluator — see COMPLEX row |
| COMPLEX | any | `/dso:preplanning <epic-id>` (full mode) |

**Rationale**: TRIVIAL epics route directly to `/dso:implementation-plan` — the brainstorm dialogue produced task-level detail. MODERATE+High epics route to `/dso:preplanning --lightweight` to run a risk/scope scan, detect qualitative overrides missed during brainstorm, and write structured done definitions before implementation planning. MODERATE+Medium epics have implicit acceptance criteria that need decomposition. MODERATE+Low is not a reachable combination in practice — the complexity-evaluator's promotion rule (`scope_certainty Low → COMPLEX always`) converts it to COMPLEX before routing. The row is listed for completeness. COMPLEX epics require full story decomposition regardless of spec fidelity.

#### Step 4c: Invoke Next Skill

Output the classification line and invoke the Skill tool **in the same response** — do not yield to the user between them:

```
Epic classified as <TIER> (scope_certainty: <HIGH|MEDIUM|LOW>) — invoking /<skill> [mode]
```

Then immediately (same response, no pause):

```
# TRIVIAL:
Skill tool:
  skill: "dso:implementation-plan"
  args: "<epic-id>"

# MODERATE + scope_certainty High:
Skill tool:
  skill: "dso:preplanning"
  args: "<epic-id> --lightweight"

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
| 1: Context + Dialogue | Understand the feature | Load PRD/DESIGN_NOTES, one question at a time, "Tell me more" loop; Phase 1 Gate: Understanding Summary (problem/users/scope/success structured bullets, wait for confirmation) → Intent Gap Analysis (self-reflect on inferred content, one question at a time, at most 3 questions total, exclude confirmed content, opt-in continuation) → proceed to Phase 2 |
| 2: Approach + Spec | Define how and what | Propose 2-3 options, draft spec; Provenance Tracking (4 categories: explicit, confirmed-via-gap-question, inferred, researched); Step 2.5 gap analysis (artifact contradiction + technical self-review); Step 2.6 web research (bright-line triggers: external integration, unfamiliar dependency, security/auth, novel pattern, performance, migration — or user request); Step 2.75 scenario analysis (red team + blue team sonnet sub-agents; always runs when ≥5 SCs or integration signal, reduced/cap 3 when 3-4 SCs, skip when ≤2 SCs; targets epic-level spec gaps — distinct from preplanning adversarial review which targets cross-story gaps); run 3-reviewer fidelity check (+ conditional feasibility reviewer for integration epics); Step 4 approval gate (annotation summary line before options: "N of M criteria confirmed; K inferred requiring review"; inferred/researched → bold, explicit/confirmed → normal; 4-option AskUserQuestion: approve/scenario re-run/web research re-run/discuss; labels reflect initial-run vs re-run; planning-intelligence log appended on approve) |
| 3: Ticket Integration | Create the epic, classify complexity, route to next skill | Follow-on epic gate (HARD-GATE: present + approve each follow-on before `ticket create`). `.claude/scripts/dso ticket create epic "<title>" -d "..."`, set deps, validate health, dispatch `dso:complexity-evaluator` agent (haiku, tier_schema=SIMPLE, pass success_criteria_count + scenario_survivor_count), apply session-signal override (SC≥7 or scenarios≥10 → COMPLEX), output classification line + invoke Skill tool in same response: TRIVIAL → `/dso:implementation-plan`, MODERATE+High → `/dso:preplanning --lightweight`, MODERATE+Medium → `/dso:preplanning --lightweight`, COMPLEX → `/dso:preplanning` |
