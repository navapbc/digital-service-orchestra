---
name: brainstorm
description: Use when starting a new feature or epic — turns an idea into a defined, ticket-ready epic through Socratic dialogue, approach design, and milestone spec creation.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:brainstorm cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
</SUB-AGENT-GUARD>

# Brainstorm: Feature to Epic

You are a Principal Product Manager at USDS. Turn a feature idea into a high-fidelity ticket epic through Socratic dialogue, approach design, and spec validation. The approval gate includes a provenance annotation summary line showing how many criteria are confirmed vs. inferred before presenting options.

<HARD-GATE>
Do NOT invoke /dso:sprint, /dso:preplanning, /dso:implementation-plan, or write any code until Phase 3 is complete and the user has explicitly approved the epic spec. This applies regardless of how simple the feature seems.
</HARD-GATE>


**Supports dryrun mode.** Use `/dso:dryrun /dso:brainstorm` to preview without changes.

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated, never blocks the skill):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

## Usage

```
/dso:brainstorm                    # Start with a blank slate — describe the feature interactively
/dso:brainstorm <epic-id>          # Enrich an existing underdefined epic
/dso:brainstorm <ticket-id>        # Works with any ticket type (epic, story, task, bug)
```

When invoked with a free-text description (argument present but does not match the ticket ID format `[a-z0-9]{4}-[a-z0-9]{4}`), treat the argument as seeding context and immediately begin the Socratic dialogue at Phase 1. Do NOT show the epic selection list. Open with: *"Got it — I'll use that as our starting point. Let me ask a few questions to sharpen the scope."* then proceed to Phase 1 Step 2 with the user's text as the established problem statement seed.

<!-- Schema reference: docs/designs/stage-boundary-preconditions/ -->

When invoked without a ticket ID, run two queries:

```bash
# Zero-child epics (not yet decomposed)
.claude/scripts/dso sprint-list-epics.sh --max-children=0

# Scrutiny-gap epics (decomposed, not yet brainstormed)
.claude/scripts/dso sprint-list-epics.sh --min-children=1 --without-tag=brainstorm:complete
```

Combine results into a single numbered selection list with two labeled categories:

**Zero-child epics (not yet decomposed)**
1. [P<N>] <title> (<epic-id>)
...

**Scrutiny-gap epics (decomposed, not yet brainstormed)**
N+1. [P<N>] <title> (<epic-id>)
...

Always append a "start fresh" option as the last item. If both queries return zero epics, automatically fall through to the fresh dialogue: open with *"What feature or capability are you trying to build?"* and start the Socratic dialogue.

Wait for the user to choose; if they select an existing epic, proceed as if invoked with that epic's ticket ID. If they select "start fresh", open with: *"What feature or capability are you trying to build?"* and start the Socratic dialogue.

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

### Step 0: Load Scale Inference Protocol

Read `shared/prompts/scale-inference.md`. If the file cannot be read, STOP and emit:
"ERROR: scale-inference.md not found at skills/shared/prompts/scale-inference.md — create this file before running brainstorm."

<!-- REVIEW-DEFENSE: brainstorm/SKILL.md does not yet reference complexity-gate.md intentionally — this is a planned addition.
     The RED marker [test_brainstorm_references_complexity_gate] in .test-index line 134 tolerates this expected failure during the current TDD cycle.
     Task a0ae-d68c (Batch 4) will add the complexity-gate.md reference to brainstorm Phase 2. -->

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

If a PRD or .claude/design-notes.md exists, open with a brief summary of what you already know, then probe deeper rather than starting from scratch.

### Codebase Investigation Gate (Mandatory Before Any User Question)

Before presenting ANY question to the user, you MUST first check whether the answer is discoverable by reading the codebase. Read existing skill files (sprint SKILL.md, fix-bug SKILL.md), ARCH_ENFORCEMENT.md, pyproject.toml, project-understanding.md, and relevant scripts/module structure. Only ask the user questions whose answers cannot be found in the repo. Questions about design approach, user experience preferences, or business priorities are appropriate for the user; questions about existing implementations, available tools, or project structure are NOT — find those answers yourself first.

**Exploration decomposition**: When a context question is compound or spans multiple sources (web research, multiple codebase layers, ambiguous scope), apply the shared exploration decomposition protocol at `skills/shared/prompts/exploration-decomposition.md` to classify it as SINGLE_SOURCE or MULTI_SOURCE before proceeding. Emit DECOMPOSE_RECOMMENDED when a factor is unspecified or two findings contradict.

### Step 2: The "Tell Me More" Loop

<HARD-GATE>
Before sending any user-facing message in this dialogue: count the distinct questions in your draft. If the count is greater than 1, stop — select only the single highest-priority unknown and remove all others. A message with two numbered questions, two lettered choices on different topics, or one main question plus a follow-up sub-question ALL violate this rule. No exception exists for "quick context checks" or efficiency arguments.
</HARD-GATE>

Ask **one question at a time**. Use *"Tell me more about [concept]..."* to encourage depth. After each answer, either ask a follow-up or move to the next area.

**Before forming each question**: Check whether the answer is already in the codebase (skill files, ARCH_ENFORCEMENT.md, pyproject.toml, project-understanding.md, module structure). DO NOT ask questions whose answers are discoverable by reading the repo — find those answers yourself first using Read, Grep, or Glob. Only surface questions that require genuine user knowledge (design intent, business priorities, user experience preferences).

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

When you have enough to propose approaches, transition to Phase 2 via this 3-step sequence. The gate covers: (1) a structured **Understanding Summary** covering problem, users, scope, and success that waits for user confirmation; (2) an **Intent Gap Analysis** using targeted questions — one at a time — about inferred or assumed content; and (3) proceeding to Phase 2.

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

**Scope bullet validation (required before presenting this summary)**: Every bullet under **Scope** must name a concrete deliverable or a confirmed exclusion. A bullet is invalid if it contains any of these patterns: "verify whether", "check if", "TBD", "outcome is no changes", or "depends on investigation". If a scope item cannot be stated as a concrete in/out decision, either (a) investigate it silently now and resolve it, OR (b) ask one more Socratic question to resolve it before presenting the summary, OR (c) move it to a **Pending Investigation** bullet clearly separated from the in-scope list. Do NOT carry unresolved research tasks into the in-scope list.

#### Understanding Summary Phrasing Requirement

You MUST close the Understanding Summary with exactly this sentence: **"Does this capture your intent? If anything is off, tell me what to adjust."** Do not paraphrase (e.g., "Does this sound right?" or "Let me know if anything needs adjusting." are not acceptable). This exact phrasing is required — it is a standardized closing, not an example.

Wait for confirmation before proceeding. This confirmation step is separate from the gap analysis that follows — always proceed to the gap analysis after confirmation.

**Step 2 — Intent Gap Analysis**: After the user confirms the understanding summary, self-reflect on inferred or assumed content — items you filled in that the user did not explicitly state. Use targeted questions, one at a time, starting with the highest-priority gap. Exclude already-confirmed content (anything the user explicitly stated or confirmed in Step 1 above) from gap questions.

> **Testing note**: Changes to behavioral instruction placement in this file (e.g., adding or reordering directives within a step) are LLM behavioral changes. They do not have valid mechanical test counterparts — do NOT propose awk/grep change-detector tests that extract step text and assert specific wording. Such tests violate the behavioral testing standard (Rule 5: test structural boundaries, not content). Behavioral instruction changes in markdown instruction files are exempt from mechanical test coverage.

Format for the **first** gap question (includes the skip option):
```
Before I propose approaches: [Targeted gap question]

(You can say "proceed" at any point to skip remaining questions and move to approaches)
```

Format for **subsequent** gap questions (no skip prompt — the user already knows):
```
Before I propose approaches: [Targeted gap question]
```

**Bounded gap loop**: Ask one question at a time. After each answer, ask the next highest-priority gap question (if any remain) or proceed to Phase 2 once you have enough context to propose approaches. Terminate the loop when either (a) you have enough to propose approaches or (b) the user says "proceed" (the first gap-question prompt surfaces this option — see format below). Do not loop indefinitely — every question must target a specific unresolved inferred/assumed item; stop when no such items remain.

**Compression anti-pattern (prohibited)**: Do NOT reframe N independent decisions as a single "core question" with N sub-options or sub-lists. If your draft response contains "Rather than asking", "Instead of asking", or more than one decision sub-list under one heading, STOP — split into separate sequential questions. Each question must cover exactly one independent axis. The user's cognitive cost of evaluating N×M combinations is not reduced by renaming the composite a "core question".

Do NOT proceed to Phase 2 until the user confirms the understanding summary or explicitly skips the gap analysis.

### Step 3 — Shape Heuristic Scan (config-gated)

**Config gate**: Source `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh` and call `is_external_dep_block_enabled`. If the function returns exit 1 (flag absent or false), skip this sub-step entirely and proceed to Phase 2.

**When enabled:**

1. For each Success Criterion in the Understanding Summary, pipe the SC text to `classify-sc-shape.sh`:
   ```bash
   result=$(echo "<sc-text>" | .claude/scripts/dso classify-sc-shape.sh)
   ```

2. If any SC returns `external-outcome`:
   - Run the classification dialogue: ask the user to specify `ownership`, `handling` (`claude_auto` or `user_manual`), `claude_has_access`, and (optionally) `verification_command` for each external-outcome dependency.
   - Warn if `verification_command` runs destructive operations (deletes, writes to production).
   - Render the External Dependencies block in the epic description per the schema in `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`.

3. If no SC returns `external-outcome`: skip block rendering entirely.

---

## Phase 2: Approach + Spec Definition (/dso:brainstorm)

**Goal**: Agree on an approach and produce a high-fidelity epic spec.

### Step 0: Load Complexity Gate

Read `shared/prompts/complexity-gate.md`. If the file cannot be read, STOP and emit:
"ERROR: complexity-gate.md not found at skills/shared/prompts/complexity-gate.md — create this file before running brainstorm Phase 2."

### Step 1: Propose Approaches

Present at least 3 distinct implementation approaches with trade-offs, including at least one genuine simple baseline — the simplest implementation that satisfies all done definitions. **Lead with your recommended approach** and explain why.

**Simple baseline requirement**: The simple baseline must be a viable implementation for the current scope. The Sandbagging Prohibition from `shared/prompts/complexity-gate.md` applies: do not load the simple baseline description with scalability caveats unless those caveats are grounded in the Phase 1 scale context. A technically inadequate option (one that would fail basic requirements) is not a valid simple baseline.

**Complexity gate for proposals**: Any proposal that includes (a) a new library dependency, (b) a performance optimization, or (c) an abstraction with fewer than 3 existing call sites must include a GATE/CHECKED/FINDING/VERDICT block (format defined in `shared/prompts/complexity-gate.md`) for the relevant gate before being presented. If the verdict is FAIL and no justified-complexity path is provided, remove the proposal or revise it to eliminate the offending complexity.

**Scale context propagation**: Pass the Phase 1 scale context (result of the scale-inference.md protocol) to Gate 4 (Scale Threshold) when evaluating performance proposals. If Phase 1 scale context was "small scale (default)", Gate 4 returns FAIL for any performance optimization unless the justified-complexity path is satisfied.

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
- **Post-deployment measurement SCs are prohibited from the verifiable SC list.** After drafting each SC, apply this self-check: _Can this criterion be evaluated during the sprint session using only (a) code/artifacts in the repo, (b) CI test results, or (c) a command that runs in the local dev environment?_ If NO — because the criterion requires live production telemetry, A/B test accumulation, user adoption rates, rate comparisons against a pre-epic baseline, time-series measurements that don't exist yet, or user behavior observed post-deployment — then the criterion is a **post-deployment measurement SC** and must NOT appear as a verifiable sprint-session criterion. Violating examples: "workflow-restart rate drops ≥30% against pre-epic baseline", "adoption rate reaches 40% within 30 days", "P95 latency improves by 20% over 2-week baseline". When a drafted SC fails this check, choose one action: **(a) Rewrite as a verifiable proxy** — instrument the measurement mechanism as the SC (e.g., "Monitoring dashboard for restart-rate is instrumented and emitting data" instead of "restart rate drops ≥30%"), or **(b) Tag as DEFERRED_MEASUREMENT** — include in the epic description with format: `DEFERRED_MEASUREMENT: <criterion text> — measurement plan: <who measures, when, against what baseline>`. Do NOT count DEFERRED_MEASUREMENT items toward the 3-6 verifiable SC quota.
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
- **injected** — derived from a cross-epic interaction scan (consideration-level signal); applied before the scrutiny pipeline and rendered as bold at the approval gate

Track provenance internally — you will use these categories in Step 4 to annotate the rendered spec.

### Step 2.25: Cross-Epic Interaction Scan

Read and execute `skills/brainstorm/prompts/cross-epic-scan.md` with the current epic's approach and success criteria as input. This step dispatches haiku-tier classifiers against all open/in-progress epics to detect shared-resource conflicts before the scrutiny pipeline runs.

After the scan completes, route signals by severity:
- **benign**: log the signal; no action required; proceed to Step 2.5
- **consideration**: carry `CROSS_EPIC_SIGNALS` forward for AC injection (processed after this step per story 2629-66cb)
- **ambiguity** or **conflict**: carry `CROSS_EPIC_SIGNALS` forward for halt/resolution handling (processed after this step per story 3c31-8050)

If `CROSS_EPIC_SIGNALS` is empty or contains only benign signals, proceed directly to Step 2.5.

### Step 2.26: Consideration AC Injection

For each signal in `CROSS_EPIC_SIGNALS` where `severity = "consideration"`:

1. **Construct a structured AC** with these three required fields:
   - (a) Shared resource name: `signal.shared_resource`
   - (b) Overlapping epic ID + title: `signal.overlapping_epic_id` — `signal.overlapping_epic_title`
   - (c) Falsifiable integration constraint: `signal.integration_constraint`

2. **Deduplicate by shared resource name**: if multiple CONSIDERATION signals share the same `shared_resource` value, consolidate to a single AC (use the first or most descriptive integration_constraint).

3. **Mark as `injected` provenance**: each constructed AC carries `injected` provenance — applied before the Phase 3 clean-text strip pass.

4. **Append to the epic spec** under a new `## Cross-Epic Interactions` section (separate from `## Success Criteria`). This keeps SC Gap Check and completion verifier operating on user-authored SCs, while injected ACs are tracked independently.

If `CROSS_EPIC_SIGNALS` has no consideration-severity signals, skip this step and proceed to Step 2.27.

### Step 2.27: Halt and Resolution for Ambiguity/Conflict Signals

If `CROSS_EPIC_SIGNALS` (from Step 2.25) contains signals with `severity="ambiguity"` or `severity="conflict"`, halt and present them to the user for resolution before entering the scrutiny pipeline.

1. **Tag the epic** with `interaction:deferred`:
   ```bash
   .claude/scripts/dso ticket tag <epic-id> interaction:deferred
   ```

2. **If running non-interactively** (`BRAINSTORM_INTERACTIVE=false`): log `INTERACTIVITY_DEFERRED: cross-epic interaction signals require practitioner resolution. Epic tagged interaction:deferred. Re-run /dso:brainstorm <epic-id> interactively to resolve.` and exit without proceeding to Step 2.5.

3. **If running interactively**: Present the signals to the user:

   ```
   Cross-epic interaction signals detected:

   - Epic <overlapping_epic_id>: <overlapping_epic_title>
     Shared resource: <shared_resource>
     Signal severity: <conflict | ambiguity>
     Description: <description>
     Constraint: <integration_constraint>

   This epic has been tagged interaction:deferred. How would you like to proceed?

   (a) Resolve — I will clarify the approach or scope to eliminate the conflict (return to Phase 1)
   (b) Override — proceed to scrutiny anyway (removes interaction:deferred tag)
   (c) Halt — stop now; I will address the conflict separately
   ```

   Wait for the user's response:
   - **(a) Resolve**: Re-enter Phase 1 (Context + Socratic Dialogue) with the conflict context as seeding material. After the user provides clarification, return to Step 2.25 and re-run the scan.
   - **(b) Override**: Remove the `interaction:deferred` tag: `.claude/scripts/dso ticket untag <epic-id> interaction:deferred`. Log: `"CROSS_EPIC_SIGNALS overridden by practitioner — proceeding to scrutiny pipeline."` Continue to Step 2.5.
   - **(c) Halt**: Log: `"Brainstorm halted at practitioner request — cross-epic signals unresolved. Epic remains tagged interaction:deferred."` Stop. Do NOT proceed to Step 2.5.

4. **If no ambiguity or conflict signals**: proceed to Step 2.5 normally.

**Failure contract**: If tagging fails, log a warning and present signals to the user anyway — do not block on infrastructure failures.

### Steps 2.5, 2.6, 2.75, and Step 3: Epic Scrutiny Pipeline

Read and execute the shared epic scrutiny pipeline from `skills/shared/workflows/epic-scrutiny-pipeline.md`. Pass the current epic spec (Context + Success Criteria + Approach) as input, and supply the required pipeline parameters:

- `{caller_name}` = `brainstorm`
- `{caller_prompts_dir}` = `skills/brainstorm/prompts`

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
3. **Spike check (run before deciding whether to re-enter Phase 1)**: Read the `## FEASIBILITY_GAP` section of the epic spec. If the feasibility reviewer's finding includes a recommendation to run a spike, proof-of-concept, or validation step to resolve an integration assumption:
   - **If the spike is executable within this brainstorm session** (e.g., a codebase grep, a targeted CLI `--help` command, a WebSearch, or a lightweight API endpoint check can answer the question): Execute the spike now. Record the result. If the spike resolves the gap (confirms feasibility or disproves the assumption), remove the `## FEASIBILITY_GAP` annotation and update the spec accordingly. If the spike confirms the assumption is unresolvable, proceed to step 5 (escalate to user).
   - **If the spike is NOT executable within this brainstorm session** (e.g., requires a running service, credentials not available, or multi-day proof-of-concept): Do NOT continue to the approval gate. Escalate immediately: present the unresolved spike recommendation to the user with the exact feasibility reviewer finding, and ask whether to (a) abort and create a spike ticket first, (b) proceed with the gap explicitly annotated as a prerequisite in the epic spec, or (c) manually adjust the approach to eliminate the dependency. Log: `"FEASIBILITY_GAP spike recommendation detected — escalating before approval gate."`
4. **If `feasibility_cycle_count < max_feasibility_cycles` AND no spike recommendation was present (or spike was resolved in step 3)**: Re-enter Phase 1 (understanding loop) with the gap context as seeding material. Log: `"FEASIBILITY_GAP detected — re-entering Phase 1 understanding loop (cycle {feasibility_cycle_count}/{max_feasibility_cycles})."` After the user provides additional context or clarification, re-run the scrutiny pipeline and check again.
5. **If `feasibility_cycle_count >= max_feasibility_cycles`**: Escalate to the user. Present the unresolved gap and ask whether to proceed with the gap noted, abort, or manually adjust the spec. Log: `"FEASIBILITY_GAP unresolved after {max_feasibility_cycles} cycles — escalating to user."`
6. Expose `feasibility_cycle_count` as a named state variable for Story 4 (7067-dae6) to consume in the log extensions.

**If FEASIBILITY_GAP is NOT present:** Continue to the Research Findings Persistence step below.

#### Research Findings Persistence (post-pipeline)

After the feasibility-reviewer sub-agent returns (regardless of FEASIBILITY_GAP outcome), persist its capability/status findings as a structured ticket comment on the epic so that downstream agents (preplanning, implementation-plan, sprint) can consume them without re-running web research.

**Skip this step entirely** when no feasibility-reviewer output exists for this brainstorm session (e.g., scrutiny pipeline did not dispatch the reviewer because no integration signals were detected).

**Procedure:**

1. From the feasibility-reviewer output, extract each (capability, status) pair the reviewer evaluated. Map each pair to one researchFindings entry with these fields:
   - `capability` (string): the integration/dependency/capability the reviewer evaluated
   - `status` (enum): one of `verified`, `partially_verified`, `unverified`, `contradicted`
   - `source` (string): the URL or reference the reviewer cited (use `"reviewer:internal"` when the reviewer relied solely on codebase evidence)
   - `skill_name` (string): always `"brainstorm"`
   - `timestamp` (string): ISO 8601 UTC timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`)

2. Assemble the entries into a single JSON array.

3. Write the array as a ticket comment on the epic using the `RESEARCH_FINDINGS:` prefix:

   ```bash
   .claude/scripts/dso ticket comment <epic-id> "RESEARCH_FINDINGS: <JSON>"
   ```

   Example payload:
   ```json
   [
     {"capability": "Figma REST API node export", "status": "verified", "source": "https://www.figma.com/developers/api#get-files-endpoint", "skill_name": "brainstorm", "timestamp": "2026-04-19T18:30:00Z"},
     {"capability": "Concurrent worktree merge safety", "status": "partially_verified", "source": "reviewer:internal", "skill_name": "brainstorm", "timestamp": "2026-04-19T18:30:00Z"}
   ]
   ```

4. Continue to the SC Gap Check below.

#### SC Gap Check

After the scrutiny pipeline completes (with no unresolved FEASIBILITY_GAP), inspect the surviving scenario set for Success Criteria coverage gaps. A coverage gap exists when a scenario describes a user outcome that is not explicitly addressed by any current SC.

**Procedure:**

1. Re-read the current SCs and the Scenario Analysis section of the epic spec.
2. For each surviving scenario, check whether at least one SC covers the scenario's core user outcome (what the user achieves, not how).
3. **If no gaps found:** Proceed to Step 4 (Approval Gate) normally.
4. **If gaps found:** For each gap, draft a revised or new SC that addresses the uncovered outcome. Then present the proposed SC revisions to the user for re-approval via `AskUserQuestion`:

   > "Scenario analysis identified the following SC gaps: [list gaps with proposed SC revisions]. Do you want to (a) Accept the revised SCs and continue, (b) Modify the proposed revisions, or (c) Skip SC revision and continue with the original SCs?"

   - **(a) Accept:** Apply the revised SCs to the epic spec (update the `## Success Criteria` section via `ticket edit --description`). Then proceed to Step 4.
   - **(b) Modify:** Incorporate user changes, present again.
   - **(c) Skip:** Log `"SC gap check: user opted to skip revision."` and proceed to Step 4 with original SCs.

### Step 2.28: Relates-to AC Injection

After the SC Gap Check completes, scan the epic spec for cross-epic consideration signals produced by the epic scrutiny pipeline's Part C Cross-Epic Relates_to extension. For each relates_to signal that includes a `shared_resource` field, inject a structured acceptance criterion (AC) into the `## Cross-Epic Interactions` section of the epic spec.

#### URL Navigability Classification

For each `signal.shared_resource` value, classify the resource type:

- **Navigable URL**: the `shared_resource` value starts with `/` OR contains `http://` or `https://`
- **Non-URL resource**: all other values (file paths, config keys, CLI tool names, data structures, etc.)

#### AC Structure

**For navigable URL signals** (4-field AC):
```
- Resource: <shared_resource>
  Interaction: <description of the cross-epic interaction>
  Gate: <acceptance condition>
  Playwright assertion: await page.goto('<shared_resource>'); await expect(page).not.toHaveURL(/4[0-9]{2}/);
```

**For non-URL resource signals** (3-field AC, no Playwright assertion):
```
- Resource: <shared_resource>
  Interaction: <description of the cross-epic interaction>
  Gate: <acceptance condition>
```

#### Injection Procedure

1. If the epic spec does not already contain a `## Cross-Epic Interactions` section, append one after the `## Dependencies` section.
2. For each cross-epic signal with a `shared_resource`, determine its URL navigability classification (above).
3. Append the appropriate AC entry (3-field or 4-field) to the `## Cross-Epic Interactions` section.
4. If no cross-epic signals with `shared_resource` fields are present, skip this step and log: `"Step 2.28 skipped: no shared_resource signals from Part C extension."`

The Playwright assertion is always appended within the same AC entry as the 4th field — it is not a separate section or bullet. Non-URL resources receive no Playwright assertion and use only the 3-field structure.

### Step 4: Approval Gate

<HARD-GATE>
Do NOT present this gate unless ALL of the following have completed or gracefully degraded with a logged rationale:
- Step 2.5: Gap analysis (self-review)
- Step 2.6: Web research phase (run OR skipped with a logged rationale per Step 2.6 graceful degradation rules)
- Step 2.75: Scenario analysis (run OR skipped because ≤2 success criteria)
- SC Gap Check: scenario-to-SC coverage verified; SCs revised if gaps found, or skip logged
- Step 3: Fidelity review (all three core reviewers completed or escalated to user)
- Structural-change re-review: if the spec was structurally changed AFTER the fidelity review completed — including an epic split, a SC count change of more than 2, or scope migration between epics — the full fidelity review pipeline (Step 3) MUST be re-run on the revised spec before this gate is presented. Prior review scores are invalidated by structural changes and do not satisfy this checklist item.
- FEASIBILITY_GAP: if a `## FEASIBILITY_GAP` section is present in the spec at this point, it MUST be surfaced explicitly in the approval gate presentation as an unresolved prerequisite — do NOT silently omit it. The user must explicitly acknowledge the gap when selecting option (a).

If any of the above has NOT completed, stop and execute it before presenting this gate. The user's ability to request a re-run via option (b) or (c) is for second-pass cycles only — it does not substitute for a mandatory first pass.
</HARD-GATE>

### External Dependencies Contradiction Gate

When `planning.external_dependency_block_enabled` is on (source: `planning-config.sh`):

1. Read the `## External Dependencies` block from the current epic spec.
2. Scan each entry for contradictions: an entry where `handling: claude_auto` AND `claude_has_access` is `no` or `unknown`.
3. If any contradiction is found:
   - Do NOT present approval gate options.
   - Emit a diagnostic naming the contradicting entry:
     ```
     Approval gate blocked: External Dependency "<name>" is declared handling=claude_auto but claude_has_access=<no|unknown>.
     Resolve this contradiction before the gate can open:
     - Option 1: Set handling=user_manual (mark as manual step for sprint)
     - Option 2: Confirm claude_has_access=yes if you have verified access
     ```
   - Wait for the practitioner to resolve the contradiction, then re-run this gate check.
4. For each entry where `verification_command` is omitted and `confirmation_token_required` is not already set:
   - Add `confirmation_token_required: true` to the entry if the entry is `handling: user_manual`.
   - This `confirmation_token_required` marker is consumed by sprint at pause-handshake time.
5. If `planning.external_dependency_block_enabled` is off: skip this gate entirely and proceed to approval gate presentation.

Present the validated spec to the user using **AskUserQuestion** with 4 options. Use **"Spec Review"** as the question header (do NOT use "Approval" — it primes misinterpretation of non-approving options as approval). Label options (b) and (c) to reflect whether this is a first re-run or subsequent re-run (the scrutiny pipeline must complete before this gate; these labels apply only to gate-triggered re-runs):

- **If web research (Step 2.6) ran during the mandatory pipeline pass**: label (c) as "Re-run web research phase"
- **If web research was skipped via graceful degradation (no bright-line triggers fired)**: label (c) as "Perform additional web research" (note: this is a first-time run, not a re-run)
- **If scenario analysis (Step 2.75) ran during the mandatory pipeline pass**: label (b) as "Re-run red/blue team review cycle"
- **If scenario analysis was skipped via graceful degradation (≤2 success criteria)**: label (b) as "Perform red/blue team review cycle" (note: this epic has ≤2 success criteria — consider adding more before running scenario analysis)

**Provenance annotation rendering**: Before presenting success criteria, render each criterion with a bold/normal annotation based on its provenance:
- **inferred** or **researched** criteria → render in **bold** (visually prominent — these require user review)
- **injected** criteria → render in **bold** (same as inferred/researched — requires practitioner awareness)
- **explicit** or **confirmed-via-gap-question** criteria → render in normal text (user already confirmed these)

Immediately before the option list, include an annotation summary line in this format:
```
N of M criteria confirmed; K inferred requiring review; J injected from cross-epic scan
```
where N = count of explicit + confirmed-via-gap-question criteria, M = total criteria count, K = count of inferred + researched criteria, J = count of injected criteria. This provenance summary line appears before the (a)/(b)/(c)/(d) options.

Note: summary confirmation (Phase 1 Gate Step 1) does NOT collapse with gap analysis (Phase 1 Gate Step 2) — they are always presented as separate steps.

```
=== Epic Spec Ready for Review ===

**[Epic Title]**

## Context
[narrative]

## Success Criteria
- **[inferred or researched criterion — bold because it requires user review]**
- [explicit or confirmed criterion — plain text]

## Scenario Analysis
[if ran]

## Dependencies
[...]

_N of M criteria confirmed; K inferred requiring review_

Please choose how to proceed:

(a) Approve — advance to Phase 3 Step 0 (Follow-on Epic Gate), then Step 1 (Ticket Creation)
(b) [Perform / Re-run] red/blue team review cycle — re-runs scenario analysis (Step 2.75) and re-presents this gate
(c) [Perform / Re-run] additional web research — re-runs web research phase (Step 2.6) and re-presents this gate
(d) Let's discuss more — pause for conversational review before re-presenting this gate
```

<HARD-GATE>
Do NOT advance to Phase 3 unless the user explicitly selects option **(a) Approve** at this gate. Options (b), (c), and (d) are non-approving — they loop back to this gate after their respective actions complete. After option (d) discussion ends, you MUST re-present this gate in full (all 4 options) and wait for the user to select (a) before proceeding. A user saying "ready to proceed" or "looks good" during discussion is NOT equivalent to selecting (a) — re-present the gate and let them choose.
</HARD-GATE>

**Option behaviors:**

- **(a) Approve**: Record the planning-intelligence log entry (see below), then advance to Phase 3 (Ticket Integration). The log captures which bright-line trigger conditions fired (or "none"), whether scenario analysis ran and how many scenarios survived the blue team filter, and whether the practitioner requested additional cycles via this gate. State vocabulary: "not triggered" / "triggered" / "re-triggered via gate".
- **(b) Re-run scenario analysis**: Re-execute Step 2.75 (Scenario Analysis) with the current spec. Update the Scenario Analysis section in the spec with new results. Re-present this gate. On re-presentation, label (b) as "Re-run red/blue team review cycle" (scenario analysis already ran).
- **(c) Re-run web research**: Re-execute Step 2.6 (Web Research Phase) with the current spec. Update the Research Findings section. Re-present this gate. On re-presentation, label (c) as "Re-run web research phase" (research already ran).
- **(d) Discuss more**: Pause skill execution and engage in open conversational review with the user. When the user indicates they are ready to proceed, you MUST re-present this full gate (all 4 options with the `=== Epic Spec Ready for Review ===` block) and wait for the user to select an option. Do NOT interpret conversational signals ("looks good", "let's move on", "ready") as implicit approval — the user must select option (a) at the re-presented gate to advance.

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
- **Scale context (Step 0)**: [<numeric estimate> | small scale (default) | not applicable (no volume decision) | user-provided: <value>]
```

---

## Phase 3: Ticket Integration (/dso:brainstorm)

**Goal**: Create the epic in the ticket system and hand off to the next step.

**Clean-text instruction**: Strip all provenance markers and bold emphasis before writing the ticket description. Provenance annotations are used only during the approval-gate review phase — the final ticket description must be written as clean plain text with no markup from the provenance tracking step. Note: `injected` provenance is applied BEFORE the Phase 3 clean-text strip pass. The approval gate (Step 4, which runs before Phase 3) presents injected ACs in **bold** so practitioners see them clearly. Clean-text strips all provenance markers including `injected` annotations for the final ticket description.

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
3. **Invoke the epic scrutiny pipeline**: Run the shared scrutiny pipeline at `skills/shared/workflows/epic-scrutiny-pipeline.md` on the drafted follow-on epic spec, passing:
   - `{caller_name}` = `brainstorm`
   - `{caller_prompts_dir}` = `skills/brainstorm/prompts`
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

### Planning Intelligence Log

- **Web research (Step 2.6)**: [not triggered | triggered | re-triggered via gate]
  - Bright-line conditions that fired: [list conditions, or "none"]
- **Scenario analysis (Step 2.75)**: [not triggered | triggered | re-triggered via gate]
  - Scenarios surviving blue team filter: [count, or "skipped — ≤2 success criteria"]
- **Practitioner-requested additional cycles**: [none | web research re-run N time(s) | scenario analysis re-run N time(s) | both re-run]
- **Follow-on scrutiny (Step 0)**: [not triggered | triggered — depth: <follow_on_scrutiny_depth>]
- **Feasibility resolution (Step 2.5)**: [not triggered | triggered — cycles: <feasibility_cycle_count>, gap: <triggering gap description>]
- **LLM-instruction signal (Step 5)**: [not triggered | triggered — keyword: <matched_keyword>]
- **Scale context (Step 0)**: [<numeric estimate> | small scale (default) | not applicable | user-provided: <value>]

<!-- REQUIRED: populate this section from the approval-gate log recorded at Phase 2 Step 4. Do NOT omit this heading — it is a contract signal consumed by ticket-migrate-brainstorm-tags.sh and downstream tooling. -->
DESCRIPTION
)"
```

**If no existing epic** (i.e., this is a new brainstorm or the original ticket was not epic — i.e., you arrived here via the Convert-to-Epic path): create the epic:

```bash
.claude/scripts/dso ticket create epic "<title>" --priority <priority> -d "$(cat <<'DESCRIPTION'
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

### Planning Intelligence Log

- **Web research (Step 2.6)**: [not triggered | triggered | re-triggered via gate]
  - Bright-line conditions that fired: [list conditions, or "none"]
- **Scenario analysis (Step 2.75)**: [not triggered | triggered | re-triggered via gate]
  - Scenarios surviving blue team filter: [count, or "skipped — ≤2 success criteria"]
- **Practitioner-requested additional cycles**: [none | web research re-run N time(s) | scenario analysis re-run N time(s) | both re-run]
- **Follow-on scrutiny (Step 0)**: [not triggered | triggered — depth: <follow_on_scrutiny_depth>]
- **Feasibility resolution (Step 2.5)**: [not triggered | triggered — cycles: <feasibility_cycle_count>, gap: <triggering gap description>]
- **LLM-instruction signal (Step 5)**: [not triggered | triggered — keyword: <matched_keyword>]
- **Scale context (Step 0)**: [<numeric estimate> | small scale (default) | not applicable | user-provided: <value>]

<!-- REQUIRED: populate this section from the approval-gate log recorded at Phase 2 Step 4. Do NOT omit this heading — it is a contract signal consumed by ticket-migrate-brainstorm-tags.sh and downstream tooling. -->
DESCRIPTION
)"
```

**Priority guidance (new epics only):** Before creating the ticket, read and apply the value/effort scorer from `skills/shared/prompts/value-effort-scorer.md`. Assess the epic's value (1-5) and effort (1-5) based on the conversation context, map to the recommended priority via the scorer's matrix, and use that priority with `--priority <priority>` in the ticket create command above.

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

# Remove scrutiny:pending (no-op if not present) and add brainstorm:complete
.claude/scripts/dso ticket untag <epic-id> scrutiny:pending
.claude/scripts/dso ticket tag <epic-id> brainstorm:complete
```

Replace `<epic-id>` with the actual epic ID variable available at Phase 3 execution context.

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

Dispatch the dedicated complexity evaluator agent to classify the epic. Read `agents/complexity-evaluator.md` inline and dispatch as `subagent_type: "general-purpose"` with `model: "haiku"`. Pass the epic ID as the argument and `tier_schema=SIMPLE` so the agent outputs SIMPLE/MODERATE/COMPLEX tier vocabulary. (`dso:complexity-evaluator` is an agent file identifier, NOT a valid `subagent_type` value — the Agent tool only accepts built-in types.)

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
| 1: Context + Dialogue | Understand the feature | Load PRD/DESIGN_NOTES, one question at a time, "Tell me more" loop; Phase 1 Gate: Understanding Summary (problem/users/scope/success structured bullets, wait for confirmation) → Intent Gap Analysis (self-reflect on inferred content, one question at a time, exclude confirmed content; loop terminates when approach-proposal is well-founded or user says "proceed") → proceed to Phase 2. When `planning.external_dependency_block_enabled=true`: Phase 1 runs External Dependencies shape heuristic + classification dialogue; Phase 2 approval gate checks for contradiction resolution. Schema: `${CLAUDE_PLUGIN_ROOT}/docs/contracts/external-dependencies-block.md`. |
| 2: Approach + Spec | Define how and what | Propose 2-3 options, draft spec; Provenance Tracking (4 categories: explicit, confirmed-via-gap-question, inferred, researched); Step 2.5 gap analysis (artifact contradiction + technical self-review); Step 2.6 web research (bright-line triggers: external integration, unfamiliar dependency, security/auth, novel pattern, performance, migration — or user request); Step 2.75 scenario analysis (red team + blue team sonnet sub-agents; always runs when ≥5 SCs or integration signal, reduced/cap 3 when 3-4 SCs, skip when ≤2 SCs; targets epic-level spec gaps — distinct from preplanning adversarial review which targets cross-story gaps); run 3-reviewer fidelity check (+ conditional feasibility reviewer for integration epics); Step 4 approval gate (annotation summary line before options: "N of M criteria confirmed; K inferred requiring review"; inferred/researched → bold, explicit/confirmed → normal; 4-option AskUserQuestion: approve/scenario re-run/web research re-run/discuss; labels reflect initial-run vs re-run; planning-intelligence log appended on approve) |
| 3: Ticket Integration | Create the epic, classify complexity, route to next skill | Follow-on epic gate (HARD-GATE: present + approve each follow-on before `ticket create`). `.claude/scripts/dso ticket create epic "<title>" -d "..."`, set deps, validate health, dispatch `dso:complexity-evaluator` agent (haiku, tier_schema=SIMPLE, pass success_criteria_count + scenario_survivor_count), apply session-signal override (SC≥7 or scenarios≥10 → COMPLEX), output classification line + invoke Skill tool in same response: TRIVIAL → `/dso:implementation-plan`, MODERATE+High → `/dso:preplanning --lightweight`, MODERATE+Medium → `/dso:preplanning --lightweight`, COMPLEX → `/dso:preplanning` |
