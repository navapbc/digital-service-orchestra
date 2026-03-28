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

### Step 2.6: Web Research Phase

Before running the fidelity review, determine whether web research is warranted for this epic. When triggered, use WebSearch and WebFetch to find prior art, best practices, and expert insights that can strengthen the approach and surface unknown constraints.

#### Bright-Line Trigger Conditions

Research is **always triggered** when any of the following conditions apply:

1. **External integration**: The epic references a third-party API, CLI tool, or service not currently used in the project — e.g., "We need to call the Stripe API for billing" triggers research into Stripe's SDK patterns and rate limits.
2. **Unfamiliar dependency**: The epic proposes adding a new library or package the codebase does not currently import — e.g., "Use Redis for caching" triggers research into Redis client library best practices and connection management patterns.
3. **Security / authentication / credentials**: The epic touches authentication, authorization, credential storage, or data handling with legal or compliance implications — e.g., "Add OAuth2 login with Google" triggers research into current OAuth2 security best practices and token handling pitfalls.
4. **Novel architectural pattern**: The epic proposes an architectural approach not established in the codebase — e.g., "Switch from polling to event-driven updates" triggers research into event-driven architecture trade-offs for the project's language and scale.
5. **Performance or scalability**: The epic explicitly targets throughput, latency, or concurrency improvements — e.g., "Support 10,000 concurrent users" triggers research into bottlenecks and optimization strategies for the stack in use.
6. **Migration or compatibility**: The epic involves data migration, version upgrades, or backward-compatibility concerns — e.g., "Migrate tickets from v2 to v3 format" triggers research into migration strategies and failure-recovery patterns.

#### Agent-Judgment Trigger Guidance

Outside the explicit bright-line conditions above, use your judgment to trigger research when you are uncertain whether an approach is sound, when the problem domain is unfamiliar, or when a quick search could meaningfully change the recommendation. If you find yourself writing a success criterion that depends on a capability you have not personally verified — such as "the library supports X" or "the API allows Y" — that is a strong signal to research before drafting the spec. When in doubt, err toward a brief search: a focused 2-3 query search costs less context than implementing the wrong approach.

#### User-Request Trigger

Research always runs when the user explicitly asks for it (e.g., "look up how others have done this", "research best practices first").

#### Research Process

For each trigger condition that fires:

1. Use **WebSearch** to find relevant prior art, official documentation, and community discussions. Prefer authoritative sources (official docs, well-maintained GitHub repos, recognized technical blogs).
2. Use **WebFetch** to retrieve and read specific pages when a search result warrants deeper reading (e.g., official API docs, migration guides, security advisories).
3. Limit to 3-5 focused queries per trigger condition. Stop when the key insight is clear — do not exhaust all search budget.

#### Research Findings

For each trigger condition that produced useful findings, record a **Research Findings** entry in the epic spec under a `## Research Findings` section. Each entry must include:

- **Trigger condition name**: Which condition (from the list above) caused this research
- **Query summary**: A one-sentence description of what was searched
- **Source URLs**: The URL(s) consulted
- **Key insight**: The most actionable finding — what this means for the approach

Example entry:
```
### External Integration: Stripe Billing API
- Trigger condition name: External integration
- Query summary: Stripe SDK payment intent flow and webhook verification
- Source URLs: https://stripe.com/docs/payments/payment-intents, https://stripe.com/docs/webhooks/best-practices
- Key insight: Stripe strongly recommends idempotency keys on all payment API calls to prevent duplicate charges on retry — success criteria should include idempotency handling.
```

#### Graceful Degradation

If WebSearch or WebFetch fails (tool unavailable, network error, or returns no useful results), log: "Web research skipped: [tool] unavailable or returned no results." and continue the brainstorm without research findings. Do not block progress — the research phase is advisory, not a gate.

### Step 2.75: Scenario Analysis

Run failure scenario analysis to surface edge cases, failure modes, and missing constraints not caught by the gap analysis pass. This step identifies risks that the implementation plan would not naturally surface.

**Differentiation note**: Brainstorm scenario analysis targets epic-level spec gaps (edge cases, failure modes, missing constraints). Preplanning adversarial review (Phase 2.5) targets cross-story interaction gaps (shared state, conflicting assumptions, dependency gaps). These are complementary but distinct.

#### Complexity Scaling Thresholds

Determine which mode to use based on the spec's success criteria count and integration signals:

| Condition | Mode |
|-----------|------|
| ≥5 success criteria OR any external integration signal | **Always runs** — full scenario analysis (no cap on scenarios) |
| 3-4 success criteria AND no integration signals | **Reduced** — cap at 3 scenarios total |
| ≤2 success criteria | **Skip** — scenario analysis not warranted at this scope |

**Integration signals** are the same keywords used in Step 2.6: third-party APIs, CLI tools, external services, CI/CD workflow changes, infrastructure provisioning, data format migrations, authentication/credential flows.

#### Agent Dispatch

When scenario analysis runs (full or reduced mode):

1. **Dispatch Red Team sub-agent** (sonnet): Read the contents of `prompts/scenario-red-team.md` (relative to this skill's directory) and dispatch a general-purpose sonnet sub-agent with that prompt as its instructions. Fill in `{epic-title}`, `{epic-description}`, and `{approach}` with the current epic's data before dispatching. The sub-agent returns a JSON array of failure scenarios.

2. **Dispatch Blue Team sub-agent** (sonnet): Read the contents of `prompts/scenario-blue-team.md` and dispatch a general-purpose sonnet sub-agent with that prompt. Fill in `{epic-title}`, `{epic-description}`, and `{red-team-scenarios}` (the JSON array from Step 1). The sub-agent returns a JSON object with `surviving_scenarios` and `filtered_scenarios`.

For reduced mode (cap 3 scenarios): after the blue team returns, keep only the top 3 surviving scenarios ranked by severity (`critical` > `high` > `medium` > `low`).

#### Scenario Analysis Output in Epic Spec

Append a **Scenario Analysis** section to the epic spec between Success Criteria and Dependencies:

```
## Scenario Analysis
[List each surviving scenario:]
- **[title]** (`[severity]`, `[category]`): [description]

[If no scenarios survive:]
No high-confidence failure scenarios identified.
```

If scenario analysis is skipped (≤2 success criteria), omit the section entirely.

#### Graceful Degradation

If either sub-agent fails to return valid JSON, log: "Scenario analysis sub-agent failed: [reason]." and continue without scenario output. Do not block progress.

### Step 3: Run Fidelity Review

Run the spec through three reviewers **in parallel** using the Task tool. For each reviewer:

1. Read the reviewer prompt from `../shared/docs/reviewers/` (relative to this skill's directory)
2. Pass: the milestone title, Context section, Success Criteria, and (for Scope reviewer) titles of other open epics
3. Instruct the reviewer to return JSON per the `REVIEW-SCHEMA.md` in the review-protocol skill

| Reviewer | Prompt File | Perspective | Dimensions |
|----------|-------------|------------|------------|
| Senior Technical Program Manager | [../shared/docs/reviewers/agent-clarity.md](../shared/docs/reviewers/agent-clarity.md) | `"Agent Clarity"` | `self_contained`, `success_measurable` |
| Senior Product Strategist | [../shared/docs/reviewers/scope.md](../shared/docs/reviewers/scope.md) | `"Scope"` | `right_sized`, `no_overlap`, `dependency_aware` |
| Senior Product Manager | [../shared/docs/reviewers/value.md](../shared/docs/reviewers/value.md) | `"Value"` | `user_impact`, `validation_signal` |
| Senior Integration Engineer | `dso:feasibility-reviewer` (dedicated agent) | `"Technical Feasibility"` | `technical_feasibility`, `integration_risk` |

### Feasibility Review Trigger

The feasibility reviewer is dispatched only when the epic involves external integrations. Scan the epic spec for integration signal keywords:

- Third-party CLI tools, external APIs/services, CI/CD workflow changes, infrastructure provisioning, data format migrations, authentication/credential flows

1. **Keyword scan**: Scan the epic spec (Context + Success Criteria + Approach) for integration signal keywords using case-insensitive matching. Match on semantic intent, not exact substrings — "calls an external REST API" matches "external APIs/services" even without the exact phrase. If any integration signal is present, dispatch the feasibility reviewer.
2. **Skip**: If no integration signals found, skip the feasibility reviewer. Log: "No external integration signals — skipping feasibility review."

**Note**: The complexity evaluator's `feasibility_review_recommended` field provides the same signal during preplanning (Phase 2.25 Integration Research) where it is available from the sprint classification. In brainstorm, the keyword scan is the primary trigger since the complexity evaluator has not yet run.

The three core reviewers (Agent Clarity, Scope, Value) **always run in parallel**. If feasibility review is triggered, dispatch `subagent_type: "dso:feasibility-reviewer"` (model: sonnet) as a **4th parallel reviewer** alongside the existing 3 — all four run concurrently in a single Task tool batch.

**Pass threshold**: All dimensions must score 4 or above. When the feasibility reviewer runs, `technical_feasibility` and `integration_risk` are also included in the pass threshold check.

**Feasibility critical findings**: If the feasibility reviewer reports any score below 3, add a note to the epic spec recommending a spike task to de-risk the integration before implementation begins.

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
