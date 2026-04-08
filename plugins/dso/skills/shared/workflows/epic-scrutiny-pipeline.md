# Epic Scrutiny Pipeline

A caller-agnostic shared workflow that runs gap analysis, web research, scenario analysis, and fidelity review against an epic spec. Invoking skills pass their identity and prompt paths as required inputs (see below).

## Input

The caller passes the current epic spec with these sections:

- **Context**: 2-4 sentence narrative (who is affected, what problem they face, why it matters)
- **Success Criteria**: The list of verifiable pass/fail outcome statements
- **Approach**: 1-2 sentence summary of the chosen implementation approach

### Required Pipeline Parameters

The invoking skill **must** supply two parameters when reading this pipeline:

| Parameter | Description | Example |
|-----------|-------------|---------|
| `{caller_name}` | The skill's short name (no `dso:` prefix), used in audit logs and schema validation | `brainstorm` |
| `{caller_prompts_dir}` | Absolute path to the calling skill's `prompts/` directory (resolved via `REPO_ROOT`) | `$REPO_ROOT/plugins/dso/skills/brainstorm/prompts` |

Before executing any step, substitute `{caller_name}` and `{caller_prompts_dir}` with the values provided by the invoking skill.

---

## Step 1: Gap Analysis (Self-Review)

Before running the fidelity review, run two gap checks in sequence.

### Part A: Artifact Contradiction Detection

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

### Part B: Technical Approach Self-Review

After resolving any artifact gaps, think carefully about the proposed approach:

- **Are there any sync loops?** If the feature involves bidirectional data flow (sync, replication, event propagation), trace the full cycle: A pushes to B, B pulls back — will it create duplicates, false conflicts, or infinite loops?
- **Are there race conditions?** If multiple actors (worktrees, users, agents, CI) can modify the same state concurrently, what happens when they collide?
- **Does the approach invalidate existing assumptions?** Will adding new data to an existing format break hashing, parsing, caching, or diffing that depends on the current shape?
- **Are there parsing ambiguities?** If the format uses delimiters or markers, can user-provided content contain those same markers?

If gaps are found in either part, present them to the user and resolve before proceeding to the web research phase.

### Part C: Shared Artifact Impact Analysis

**When Part C triggers**: Part C activates only when the Success Criteria section (not the original user request) references creating or modifying a file that is consumed by "2+ other files" outside its own directory. Identify the artifact from the SC section first (same fuzzy-matching heuristics as Part A — this is Part C's scope, not Part A's).

**If the artifact is not yet in the codebase** or a scan produces no results, skip Part C and log: `Part C scan skipped: no consumers found or scan unavailable`.

**Scanning**: Use Grep/Glob to find all files that reference the artifact — path references, import statements, source/include directives. Count only consumers outside the artifact's own directory.

**Cross-referencing**: For each discovered consumer, check whether it is covered by any success criterion in the epic spec. Assign `covered_by_SC: true` if the consumer appears in any SC, `covered_by_SC: false` if not (boolean — not a string).

**Output**: Present a raw list of `(file_path, matching_line, covered_by_SC)` tuples to downstream consumers. Do NOT curate or summarize — pass the raw scan output. Example:

```
- file_path: src/hooks/use-auth.ts, matching_line: import { getUser } from './user-service', covered_by_SC: false
- file_path: tests/unit/test-auth.test.ts, matching_line: import { getUser } from '../../src/user-service', covered_by_SC: true
```

If Part C finds uncovered consumers (`covered_by_SC: false`), flag them as potential scope gaps for the fidelity review phase.

---

## Step 2: Web Research Phase

Before running the fidelity review, determine whether web research is warranted for this epic. When triggered, use WebSearch and WebFetch to find prior art, best practices, and expert insights that can strengthen the approach and surface unknown constraints.

### Bright-Line Trigger Conditions

Research is **always triggered** when any of the following conditions apply:

1. **External integration**: The epic spec references a third-party API, CLI tool, or service not currently used in the project — e.g., "We need to call the Stripe API for billing" triggers research into Stripe's SDK patterns and rate limits.
2. **Unfamiliar dependency**: The epic spec proposes adding a new library or package the codebase does not currently import — e.g., "Use Redis for caching" triggers research into Redis client library best practices and connection management patterns.
3. **Security / authentication / credentials**: The epic spec touches authentication, authorization, credential storage, or data handling with legal or compliance implications — e.g., "Add OAuth2 login with Google" triggers research into current OAuth2 security best practices and token handling pitfalls.
4. **Novel architectural pattern**: The epic spec proposes an architectural approach not established in the codebase — e.g., "Switch from polling to event-driven updates" triggers research into event-driven architecture trade-offs for the project's language and scale.
5. **Performance or scalability**: The epic spec explicitly targets throughput, latency, or concurrency improvements — e.g., "Support 10,000 concurrent users" triggers research into bottlenecks and optimization strategies for the stack in use.
6. **Migration or compatibility**: The epic spec involves data migration, version upgrades, or backward-compatibility concerns — e.g., "Migrate tickets from v2 to v3 format" triggers research into migration strategies and failure-recovery patterns.

### Agent-Judgment Trigger Guidance

Outside the explicit bright-line conditions above, use your judgment to trigger research when you are uncertain whether an approach is sound, when the problem domain is unfamiliar, or when a quick search could meaningfully change the recommendation. If you find yourself writing a success criterion that depends on a capability you have not personally verified — such as "the library supports X" or "the API allows Y" — that is a strong signal to research before finalizing the spec. When in doubt, err toward a brief search: a focused 2-3 query search costs less context than implementing the wrong approach.

### User-Request Trigger

Research always runs when the user explicitly asks for it (e.g., "look up how others have done this", "research best practices first").

### Research Process

For each trigger condition that fires:

1. Use **WebSearch** to find relevant prior art, official documentation, and community discussions. Prefer authoritative sources (official docs, well-maintained GitHub repos, recognized technical blogs).
2. Use **WebFetch** to retrieve and read specific pages when a search result warrants deeper reading (e.g., official API docs, migration guides, security advisories).
3. Limit to 3-5 focused queries per trigger condition. Stop when the key insight is clear — do not exhaust all search budget.

### Research Findings

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

### Graceful Degradation

If WebSearch or WebFetch fails (tool unavailable, network error, or returns no useful results), log: "Web research skipped: [tool] unavailable or returned no results." and continue without research findings. Do not block progress — the research phase is advisory, not a gate.

---

## Step 3: Scenario Analysis

Run failure scenario analysis to surface edge cases, failure modes, and missing constraints not caught by the gap analysis pass. This step identifies risks that the implementation plan would not naturally surface.

**Differentiation note**: This scenario analysis targets epic-level spec gaps (edge cases, failure modes, missing constraints). Preplanning adversarial review (Phase 2.5) targets cross-story interaction gaps (shared state, conflicting assumptions, dependency gaps). These are complementary but distinct.

### Complexity Scaling Thresholds

Determine which mode to use based on the epic spec's success criteria count and integration signals:

| Condition | Mode |
|-----------|------|
| ≥5 success criteria OR any external integration signal | **Always runs** — full scenario analysis (no cap on scenarios) |
| 3-4 success criteria AND no integration signals | **Reduced** — cap at 3 scenarios total |
| ≤2 success criteria | **Skip** — scenario analysis not warranted at this scope |

**Integration signals** are the same keywords used in Step 2: third-party APIs, CLI tools, external services, CI/CD workflow changes, infrastructure provisioning, data format migrations, authentication/credential flows.

### Agent Dispatch

When scenario analysis runs (full or reduced mode):

1. **Dispatch Red Team sub-agent** (sonnet): Read the contents of `{caller_prompts_dir}/scenario-red-team.md` and dispatch a general-purpose sonnet sub-agent with that prompt as its instructions. Fill in `{epic-title}`, `{epic-description}`, and `{approach}` with the current epic spec's data before dispatching. The sub-agent returns a JSON array of failure scenarios.

2. **Dispatch Blue Team sub-agent** (sonnet): Read the contents of `{caller_prompts_dir}/scenario-blue-team.md` and dispatch a general-purpose sonnet sub-agent with that prompt. Fill in `{epic-title}`, `{epic-description}`, and `{red-team-scenarios}` (the JSON array from Step 1). The sub-agent returns a JSON object with `surviving_scenarios` and `filtered_scenarios`.

For reduced mode (cap 3 scenarios): after the blue team returns, keep only the top 3 surviving scenarios ranked by severity (`critical` > `high` > `medium` > `low`).

### Scenario Analysis Output in Epic Spec

Append a **Scenario Analysis** section to the epic spec between Success Criteria and Dependencies:

```
## Scenario Analysis
[List each surviving scenario:]
- **[title]** (`[severity]`, `[category]`): [description]

[If no scenarios survive:]
No high-confidence failure scenarios identified.
```

If scenario analysis is skipped (≤2 success criteria), omit the section entirely.

### Graceful Degradation

If either sub-agent fails to return valid JSON, log: "Scenario analysis sub-agent failed: [reason]." and continue without scenario output. Do not block progress.

---

## Step 4: Fidelity Review

Run the epic spec through three reviewers **in parallel** using the Task tool. For each reviewer:

1. Read the reviewer prompt from `plugins/dso/skills/shared/docs/reviewers/` (relative to the repo root)
2. Pass: the epic title, Context section, Success Criteria, Scenario Analysis section (from Step 3, if present), and (for Scope reviewer) titles of other open epics
3. Instruct the reviewer to return JSON per the `REVIEW-SCHEMA.md` in the review-protocol skill

| Reviewer | Prompt File | Perspective | Dimensions |
|----------|-------------|------------|------------|
| Senior Technical Program Manager | `plugins/dso/skills/shared/docs/reviewers/agent-clarity.md` | `"Agent Clarity"` | `self_contained`, `success_measurable` |
| Senior Product Strategist | `plugins/dso/skills/shared/docs/reviewers/scope.md` | `"Scope"` | `right_sized`, `no_overlap`, `dependency_aware` |
| Senior Product Manager | `plugins/dso/skills/shared/docs/reviewers/value.md` | `"Value"` | `user_impact`, `validation_signal` |
| Senior Integration Engineer | `dso:feasibility-reviewer` (dedicated agent) | `"Technical Feasibility"` | `technical_feasibility`, `integration_risk` |

### Feasibility Review Trigger

The feasibility reviewer is dispatched when the epic spec involves external integrations OR first-time usage of internal platform features. Scan the epic spec for integration signal keywords:

- Third-party CLI tools, external APIs/services, CI/CD workflow changes, infrastructure provisioning, data format migrations, authentication/credential flows

Trigger: epic references external integrations (third-party APIs, CI/CD, infrastructure) OR first-time usage of internal platform features (hook types not present in any settings.json, tool types not used in any agent definition, framework features not yet exercised in the codebase).

1. **Keyword scan**: Scan the epic spec (Context + Success Criteria + Approach) for integration signal keywords using case-insensitive matching. Match on semantic intent, not exact substrings — "calls an external REST API" matches "external APIs/services" even without the exact phrase. Also check for first-time internal platform feature usage by comparing referenced hook types, tool types, and framework features against existing usages in the codebase. If any integration signal or first-time internal feature usage is present, dispatch the feasibility reviewer.
2. **Skip**: If no integration signals and no first-time internal platform features found, skip the feasibility reviewer. Log: "No external integration or first-time internal platform feature signals — skipping feasibility review."

**Note**: The complexity evaluator's `feasibility_review_recommended` field provides the same signal during preplanning (Phase 2.25 Integration Research) where it is available from the sprint classification. In brainstorm, the keyword scan is the primary trigger since the complexity evaluator has not yet run.

The three core reviewers (Agent Clarity, Scope, Value) **always run in parallel**. If feasibility review is triggered, dispatch `subagent_type: "dso:feasibility-reviewer"` (model: sonnet) as a **4th parallel reviewer** alongside the existing 3 — all four run concurrently in a single Task tool batch.

**Pass threshold**: All dimensions must score 4 or above. When the feasibility reviewer runs, `technical_feasibility` and `integration_risk` are also included in the pass threshold check.

**Feasibility critical findings**: If the feasibility reviewer reports any score below 3, annotate the epic spec with a `## FEASIBILITY_GAP` section identifying the unresolved capability gap and return control to the caller. The caller is responsible for handling this annotation — e.g., brainstorm re-enters its understanding loop bounded by `brainstorm.max_feasibility_cycles`, while other callers may implement their own resolution strategy. The pipeline itself takes no further action beyond the annotation.

**Validate the review output:**
```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
REVIEW_OUT="$(mktemp /tmp/scrutiny-review-XXXXXX.json)"
cat > "$REVIEW_OUT" <<'EOF'
<assembled review JSON>
EOF
".claude/scripts/dso validate-review-output.sh" review-protocol "$REVIEW_OUT" --caller {caller_name}
```

**Caller schema hash**: `f4e5f5a355e4c145`

**If a dimension scores below 4:**
- Fix the spec based on the finding
- Re-run only the failing reviewer
- Repeat until all dimensions pass, or escalate to user if conflicting guidance

**Watch for the "current vs. future state" anti-pattern**: If a reviewer scores a dimension low and the finding references existing files, components, or behaviors in the current codebase (e.g., "this file already exists at path X"), the reviewer may be evaluating present state rather than the spec's intended future state. Before iterating on the spec, verify whether the low score reflects a genuine spec gap or a reviewer anchor on the status quo. If the existing artifact will be changed or replaced by this epic, the finding is invalid — re-run that reviewer with an explicit reminder to evaluate the spec as written, not the current codebase.

**Conflict detection**: If two reviewers give contradictory guidance on the same spec element, escalate to the user immediately — do not resolve conflicts autonomously.

### Review Event Emission

After the fidelity review completes (all dimensions pass or user escalation resolves), emit the review result event for observability:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
".claude/scripts/dso" emit-protocol-review-result.sh \
  --review-type=brainstorm-fidelity \
  --pass-fail=<passed|failed> \
  --revision-cycles=<number of revision cycles executed>
```

- `--pass-fail`: `passed` if all dimensions scored 4+ on final run; `failed` if escalated to user without resolution.
- `--revision-cycles`: The number of times a failing reviewer was re-run (0 if all passed on the first attempt).
- Best-effort: if the emit script fails, log a warning and continue — do not block pipeline completion.

---

## Step 5: Prompt Alignment

When an epic modifies LLM-facing instructions, validate that prompt changes are well-grounded in prior art and reviewed for behavioral soundness. This step detects LLM-instruction signals in the epic spec, searches for prior art, and dispatches the bot-psychologist for review.

### LLM-Instruction Signal Detection

Scan the epic spec (Context + Success Criteria + Approach sections) for the following canonical keyword list using case-insensitive matching:

- **skill file modifications** — changes to `SKILL.md` or skill workflow files
- **agent definitions** — new or modified agent prompts, `subagent_type` declarations, or agent routing changes
- **prompt templates** — changes to prompt files, instruction text, or LLM-facing guidance documents
- **hook behavioral logic** — modifications to hook dispatchers, pre/post tool-use hooks, or enforcement gate behavior

If none of the canonical keywords match, skip the remainder of Step 5 and proceed to Pipeline Output. Log: "No LLM-instruction signals detected — skipping prompt alignment."

Set `matched_keyword = <first matched keyword category>` as a state variable for planning-intelligence log consumption. When multiple categories match, use the first match in the canonical order above.

### Doc-Epic Exclusion

Before proceeding with the full prompt alignment workflow, check the Approach section for file references. If the Approach section references **only** documentation files (`.md` files, documentation paths, or doc-only changes) and no code or configuration files, skip prompt alignment. Log: "Doc-epic exclusion — skipping prompt alignment."

### GitHub Prior-Art Search

If the signal fires and the doc-epic exclusion does not apply:

1. Use **WebSearch** to run a provider-agnostic GitHub prior-art search for similar prompts, instruction patterns, or agent behavioral specifications in popular AI/LLM projects. Focus queries on the matched keyword category — e.g., if "agent definitions" matched, search for agent definition patterns in well-known AI orchestration repos.
2. Limit to 2-3 focused queries. Stop when key patterns are identified.
3. Present findings to the user for collaborative prompt drafting — highlight patterns that align with or diverge from the proposed approach.

### Bot-Psychologist Dispatch

After prior-art findings are gathered:

1. Dispatch `dso:bot-psychologist` via the Agent tool (model: sonnet) to review the draft prompt text or LLM-facing instruction changes described in the epic spec.
2. Pass the matched keyword category, the epic's Approach section, and any prior-art findings as context.
3. Incorporate the bot-psychologist's behavioral analysis findings into the epic spec.

### Graceful Degradation

- **WebSearch failure**: If WebSearch fails (tool unavailable, network error, or returns no useful results), log: "Prompt alignment prior-art search skipped: WebSearch unavailable or returned no results." Continue without prior-art findings — proceed directly to bot-psychologist dispatch.
- **Bot-psychologist failure**: If the bot-psychologist Agent dispatch fails (SUB-AGENT-GUARD rejection, dispatch timeout, or returns no usable analysis), log: "Prompt alignment bot-psychologist review skipped: dispatch failed or returned no results." Continue without bot-psychologist findings — do not block pipeline completion.

### Prompt Alignment Findings

If prompt alignment produced findings (from prior-art search, bot-psychologist review, or both), record them in the epic spec under a `## Prompt Alignment Findings` section:

- **Matched signal**: Which canonical keyword category triggered prompt alignment
- **Prior-art patterns**: Key patterns found in similar projects (if WebSearch succeeded)
- **Behavioral review**: Bot-psychologist analysis summary (if dispatch succeeded)
- **Recommendations**: Specific prompt improvements or cautions for the implementation plan

---

## Pipeline Output

After all steps complete, the caller receives an updated epic spec with any or all of these additional sections populated:

- `## Research Findings` — if web research ran and produced findings
- `## Scenario Analysis` — if scenario analysis ran and produced surviving scenarios
- `## Prompt Alignment Findings` — if prompt alignment ran and produced findings (LLM-instruction signal detected)

The caller is responsible for presenting the final spec to the user for approval.
