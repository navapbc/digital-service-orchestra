---
name: fix-bug
description: Classify bugs by type and severity, then route through the appropriate investigation and fix path. Replaces tdd-workflow for bug fixes.
user-invocable: true
---

# Fix Bug: Investigation-First Bug Resolution

Enforce a hard separation between investigation and implementation. Bugs are classified, scored, investigated to root cause, and only then fixed — with TDD discipline ensuring the fix is verified.

This skill replaces `/dso:tdd-workflow` for bug fixes. For new feature development using TDD, continue to use `/dso:tdd-workflow`.

<HARD-GATE>
Do NOT modify any code, write any fix, or make any file changes until Steps 1–5 are complete (classify, investigate, hypothesis test, approve, RED test). This applies regardless of how simple or obvious the bug appears. Steps 1–5 must complete before any code modification.

Do NOT modify skill files, agent files, or prompt templates for llm-behavioral bugs until investigation is complete. LLM-behavioral bugs follow the same investigation discipline as code bugs — the HARD-GATE applies equally to skill file changes, agent file changes, and prompt template edits. Do not edit any .md file in skills/, agents/, or prompts/ directories before completing Steps 1–5.

Do NOT investigate inline as a substitute for sub-agent dispatch. Reading code, grepping, running commands, or analyzing stack traces yourself does NOT satisfy Step 2. You MUST dispatch the investigation sub-agent described in Step 2 — your own analysis is not equivalent, even when the root cause appears obvious.
</HARD-GATE>

## Config Resolution (reads project workflow-config.yaml)

At activation, load project commands via read-config.sh before executing any steps:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.test)
LINT_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.lint)
FORMAT_CHECK_CMD=$(bash "$PLUGIN_SCRIPTS/read-config.sh" commands.format_check)
```

Resolution order: See `${CLAUDE_PLUGIN_ROOT}/docs/CONFIG-RESOLUTION.md`.

Resolved commands used in this skill:
- `TEST_CMD` — used in RED test (Step 5), fix verification (Step 7), and mechanical fix validation
- `LINT_CMD` — used in fix verification (Step 7)
- `FORMAT_CHECK_CMD` — used in fix verification (Step 7)

## Empirical Validation Directive

**Core principle: validate assumptions — never assume unobserved behavior.**

Every investigation step that forms a belief about how a tool, API, command, or external system behaves must be backed by empirical evidence before that belief informs a proposed fix. The distinction between "the documentation claims X" and "I tested and confirmed X actually works" is critical.

Required practices at every investigation tier:

1. **Run actual commands before proposing fixes** — when the bug involves a CLI tool, API, or external system, run the actual command (`--help`, `--generate-json`, a test invocation) to confirm the assumed behavior. Do not propose a fix based on documentation alone.
2. **Distinguish documented vs. observed behavior** — explicitly label evidence as "stated in docs" vs. "tested and confirmed". Only "tested and confirmed" evidence supports a high-confidence fix proposal.
3. **Search for real-world usage** — when facing an unfamiliar tool or API, search GitHub or other code repositories for how other projects solve the same problem, rather than relying solely on official documentation.
4. **Test proposed approaches in isolation** — before committing to a fix approach, test the key assumption in isolation (e.g., a throwaway API call, a minimal reproduction script) to confirm it works as expected.

These practices apply to all investigation tiers and are enforced through the "Empirical Validation" step in each investigation prompt template.

## Error Type Classification

Before scoring, classify the error:

### Mechanical Errors

Mechanical errors have an obvious, deterministic fix that requires no investigation. These skip the scoring rubric and route directly to the **Mechanical Fix Path** (read the error, apply the fix, validate).

**Exclusion — files in `skills/`, `agents/`, or `prompts/` directories must not be classified as mechanical.** Changes to skill files, agent definitions, or prompt templates affect LLM behavior and guidance — even when the fix appears to be "obvious text replacement." These files must be routed through the LLM-behavioral or behavioral classification path, never mechanical. An agent that can see "what text is wrong" in a skill file is not performing a mechanical fix — it is making a judgment about how to change agent behavior, which requires investigation.

Types of mechanical errors:
- **import error** — missing or incorrect import statement
- **type annotation** — incorrect or missing type hint
- **lint violation** — ruff, mypy, or similar linter failure with a clear fix
- **config syntax** — malformed YAML, TOML, JSON, or conf file (not `.md` files in `skills/`, `agents/`, or `prompts/`)

Mechanical Fix Path:
1. Complete Step 0.5 (Ticket Lifecycle Setup) — ensure a bug ticket exists and is in-progress
2. Read the error message and identify the exact file and line
3. Apply the deterministic fix (add import, fix type, fix lint, fix syntax)
4. Run `$TEST_CMD` and `$LINT_CMD` to validate
5. If validation passes, run Gate 2a (Reversal Check) then proceed to Step 8 (Commit and Close)
6. If validation fails with a NEW error, reclassify — it may be behavioral

### Behavioral Errors

All errors that are NOT mechanical or LLM-behavioral are behavioral. These require investigation and proceed to Step 1 (Score and Classify).

### LLM-Behavioral Errors

LLM-Behavioral Errors are a distinct classification for bugs where the defect is in how an LLM agent behaves — not in executable code. These bugs are identified using **dual-signal detection**: both signals must be present together to classify a bug as llm-behavioral (preventing over-classification of unrelated markdown changes).

**Dual-signal detection**:
1. **Ticket content signal** — the bug description references LLM output quality, prompt regression, agent guidance gaps, model behavior drift, skill misinterpretation, or agent skips/misinterprets/drifts from expected behavior
2. **File type signal** — the affected file is a skill file (`.md` in `skills/`), an agent file (`.md` in `agents/`), or a prompt template (`.md` in `prompts/`)

Both signals must be present. A markdown file change with no behavioral ticket signal is NOT llm-behavioral. A behavioral complaint with no skill/agent/prompt file involvement is NOT llm-behavioral (route as behavioral instead).

**LLM-Behavioral Fix Path**:

LLM-behavioral bugs follow a combined investigation+fix path (SC5 — HARD-GATE amendment applies). The investigation produces a diagnosis of what behavioral gap or prompt regression is causing the issue, and the fix is a targeted change to the skill, agent, or prompt template.

<!-- REVIEW-DEFENSE: This SUB-AGENT-GUARD serves a different purpose than the llm-behavioral fix path dispatch instruction that follows it. The guard handles the case where fix-bug itself is running as a sub-agent (e.g., dispatched by debug-everything or sprint) — in that context, the Agent tool is unavailable and nested dispatch is prohibited. The dispatch instruction that follows is for when fix-bug runs as the orchestrator (Agent tool available). These two contexts are complementary: when fix-bug is the orchestrator, dispatch bot-psychologist as a sub-agent; when fix-bug is itself a sub-agent, fall back to inline guidance. The inline fallback acknowledges that iterative experiment loops requiring user input cannot complete in non-interactive sub-agent contexts — it degrades to partial investigation and surfaces findings for the calling orchestrator to escalate. -->
<SUB-AGENT-GUARD>
Agent tool availability check: if the Agent tool is unavailable, use the inline fallback below instead of dispatching a sub-agent.

**If the Agent tool is available** (orchestrator context): dispatch `dso:bot-psychologist` sub-agent:

```
Read: plugins/dso/agents/bot-psychologist.md
Dispatch: subagent_type: dso:bot-psychologist
Input: bug description, affected skill/agent/prompt file path, ticket content, behavioral symptoms observed
```

**If the Agent tool is unavailable** (sub-agent context — inline investigation fallback): Read `plugins/dso/agents/bot-psychologist.md` as a REFERENCE only — use it for the llm-behavioral taxonomy definitions and probe definitions. Do NOT attempt to follow bot-psychologist's own investigation steps (bot-psychologist contains its own SUB-AGENT-GUARD that blocks all diagnosis steps in nested contexts). Instead, perform the investigation directly using fix-bug's own Step 2/3 investigation framework, applying the llm-behavioral taxonomy from bot-psychologist.md. Specifically: identify the behavioral gap type (prompt regression, guidance gap, behavioral drift, etc.) using the taxonomy, then run static analysis on the affected skill/agent/prompt file (grep for relevant patterns, read the file, identify the defect). Skip any steps requiring user-provided experimental results — record them as `INTERACTIVITY_DEFERRED` in the investigation RESULT and surface them for the calling orchestrator to escalate to the user. This fallback ensures LLM-behavioral investigation degrades gracefully when nested dispatch is prohibited, while clearly signaling which investigation steps could not complete.
</SUB-AGENT-GUARD>

**Step 5 / Step 5.5 exemption**: LLM-behavioral bugs are exempt from the standard RED unit test requirement (see Step 5.5 for details). The behavioral nature of these bugs means a traditional executable RED test cannot always be written before the fix. Instead, use eval-based verification or behavioral assertion verification as the confirmation mechanism.

## Scoring Rubric (Behavioral Bugs Only)

Score the bug across these dimensions to determine investigation depth:

| Dimension | Score 0 | Score 1 | Score 2 |
|-----------|---------|---------|---------|
| **severity** | Low — cosmetic, minor UX | Medium/moderate — functional degradation | High/critical — data loss, security, outage |
| **complexity** | Simple/trivial — single file, obvious cause | Moderate/medium — multiple files, non-obvious | Complex — cross-system, race conditions, emergent |
| **environment** | Local — reproducible in dev | CI failure — reproducible in CI only | Production/staging — observed in deployed env |

### Bonus Modifiers

| Condition | Modifier |
|-----------|----------|
| **Cascading failure** — fixing this bug caused new failures in previous attempts | +2 |
| **Prior fix attempts** — previous commits attempted to fix this bug and failed | +2 |

### Total Score and Routing

Sum all dimension scores and modifiers:

- Score **< 3** : Route to **BASIC** investigation
- Score **3-5** : Route to **INTERMEDIATE** investigation
- Score **>= 6** : Route to **ADVANCED** investigation

## Workflow

### Step 0: Check Known Issues (/dso:fix-bug)

Before any investigation, check whether this bug (or a similar pattern) is already documented:

```bash
grep -i "<keyword>" "$(git rev-parse --show-toplevel)/.claude/docs/KNOWN-ISSUES.md" 2>/dev/null || true
```

If a known issue matches, note the match for later — after Step 0.5 establishes `BUG_TICKET_ID`, record it via `ticket comment <BUG_TICKET_ID> "Known issue match: ..."`. The known issue context informs investigation but does not skip it.

### Step 0.5: Ticket Lifecycle Setup (/dso:fix-bug)

Ensure a bug ticket exists and is set to in-progress before investigation begins.

1. **If a ticket ID was provided** (via argument or orchestrator context): use it.
2. **If no ticket ID was provided**: search for an existing open bug ticket matching the error description to avoid duplicates:
   ```bash
   ticket list | python3 -c "import json,sys; tickets=json.load(sys.stdin); bugs=[t for t in tickets if t.get('ticket_type')=='bug' and t.get('status')=='open']; [print(t['ticket_id'],t['title']) for t in bugs]"
   ```
   - If a matching bug is found (same error, same file, or same root symptom): use that ticket ID.
   - If no match: create a new bug ticket:
     ```bash
     ticket create bug "<concise bug title derived from the error>"
     ```
3. **Set the ticket to in-progress** (check current status first to avoid optimistic concurrency errors):
   ```bash
   CURRENT_STATUS=$(ticket show <id> | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','open'))")
   if [ "$CURRENT_STATUS" != "in_progress" ] && [ "$CURRENT_STATUS" != "closed" ]; then
       ticket transition <id> "$CURRENT_STATUS" in_progress
   fi
   ```

Store the ticket ID as `BUG_TICKET_ID` for use throughout the workflow.

### Step 1: Score and Classify (/dso:fix-bug)

1. Read the bug description, error messages, and stack traces
2. Classify: **mechanical**, **behavioral**, or **llm-behavioral** (see Error Type Classification above)
3. If mechanical: follow the Mechanical Fix Path, then skip to Step 8
4. If llm-behavioral (dual-signal detected — ticket references LLM behavior AND affected file is in `skills/`, `agents/`, or `prompts/`): record the classification: `ticket comment <BUG_TICKET_ID> "Classification: llm-behavioral"`, then dispatch `dso:bot-psychologist` via the LLM-Behavioral Fix Path (see above), then skip to Step 8
5. If behavioral: apply the Scoring Rubric to determine investigation tier
6. Record the classification and score in a ticket note: `ticket comment <BUG_TICKET_ID> "Classification: behavioral, Score: <N> (<tier>)"`

### Step 1.5: Gate 1a — Intent Search (/dso:fix-bug)

Before dispatching the investigation sub-agent, run the intent-search gate to determine whether the bug aligns with system intent.

**Read budget config:**

```bash
INTENT_SEARCH_BUDGET=$(bash "$PLUGIN_SCRIPTS/read-config.sh" debug.intent_search_budget)
# Default: 20
```

**Dispatch intent-search agent:**

```
subagent_type: dso:intent-search
inputs:
  ticket_id: <BUG_TICKET_ID>
  intent_search_budget: <INTENT_SEARCH_BUDGET>
```

The agent returns a gate signal conforming to the shared contract defined in `plugins/dso/docs/contracts/gate-signal-schema.md`.

**Route based on gate signal outcome:**

After the agent returns its signal, record the outcome string for use by Gate 2a:

```bash
# Set GATE_1A_RESULT to "intent-aligned", "intent-contradicting", or "ambiguous"
# based on the gate signal outcome field returned by the intent-search agent.
GATE_1A_RESULT="<outcome>"   # e.g., "intent-aligned"
```

Gate 1a has three possible outcomes. The **ambiguous** outcome falls through to Gate 1b (feature-request language check via `gate-1b-feature-request-check.py`); the other two outcomes are decisive and skip Gate 1b entirely (see Step 1.7 below).

- **intent-aligned** (`triggered: false`, `confidence: high` or `medium`) — The bug is consistent with system intent. Set `GATE_1A_RESULT="intent-aligned"`. Proceed directly to Step 2 (Investigation Sub-Agent Dispatch) without additional dialog.

- **intent-contradicting** (`triggered: true`) — The bug report describes behavior that contradicts system intent (e.g., "working as designed", invalid usage, non-bug). Set `GATE_1A_RESULT="intent-contradicting"`. Auto-close:
  1. Add evidence comment:
     ```bash
     ticket comment <BUG_TICKET_ID> "Intent-contradicting: <evidence summary from gate signal>"
     ```
  2. Close ticket with reason:
     ```bash
     ticket transition <BUG_TICKET_ID> in_progress closed --reason="Fixed: Intent-contradicting — <evidence source>"
     ```
  3. **Stop** — do not proceed to investigation.

- **ambiguous** (`triggered: false`, `confidence: low`) — The intent signal is inconclusive. Set `GATE_1A_RESULT="ambiguous"`. Fall through to Gate 1b for further disambiguation before investigation.

**Graceful degradation:** If the intent-search agent dispatch fails (timeout, nonzero exit, empty output, or unparseable JSON / malformed signal), treat the result as **ambiguous** (`GATE_1A_RESULT="ambiguous"`) and fall through to Gate 1b. Agent failure must never block a legitimate bug investigation. Log the failure via `ticket comment <BUG_TICKET_ID> "Gate 1a: agent failure — treating as ambiguous. Error: <error detail>"`.

**Mechanical fix path**: Bugs routed through the Mechanical Fix Path bypass Step 1.5 entirely, so `GATE_1A_RESULT` will be unset when Gate 2a runs. Gate 2a handles this via the default guard shown in its bash snippet (`GATE_1A_RESULT=${GATE_1A_RESULT:-}`).

### Step 1.7: Gate 1b — Feature Request Check (/dso:fix-bug)

Gate 1b is a **primary** gate that runs ONLY when Gate 1a returns **ambiguous**. It is skipped entirely for `intent-aligned` and `intent-contradicting` Gate 1a outcomes — those results are decisive and require no further disambiguation.

**When to run**: Only when `GATE_1A_RESULT="ambiguous"`. Skip to Step 2 immediately if `GATE_1A_RESULT` is `intent-aligned` or `intent-contradicting`.

**How to run**: Pass the bug ticket title and description as a JSON payload via stdin to `gate-1b-feature-request-check.py`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
GATE_1B_PAYLOAD=$(python3 -c "
import json, sys
payload = {'title': sys.argv[1], 'description': sys.argv[2]}
print(json.dumps(payload))
" "<ticket title>" "<ticket description>")

GATE_1B_OUTPUT=$(echo "$GATE_1B_PAYLOAD" | python3 "$PLUGIN_SCRIPTS/gate-1b-feature-request-check.py")
```

The script exits 0 always and emits a single JSON gate signal to stdout conforming to `plugins/dso/docs/contracts/gate-signal-schema.md`:

```json
{
  "gate_id": "1b",
  "signal_type": "primary",
  "triggered": <bool>,
  "evidence": "<string>",
  "confidence": "high" | "medium" | "low"
}
```

**Parsing the gate signal**: Parse the JSON output and route based on `triggered`:

- **`triggered: true`** — Feature-request language detected. Gate 1b is a primary signal — record the evidence and escalate to the user for confirmation before continuing:
  ```bash
  ticket comment <BUG_TICKET_ID> "Gate 1b: feature-request language detected — <evidence from signal>"
  ```
  Present the evidence to the user and ask whether to close as a feature request or proceed to investigation.

- **`triggered: false`** — No feature-request language detected. Proceed directly to Step 2 (Investigation Sub-Agent Dispatch).

**Graceful degradation:** If `gate-1b-feature-request-check.py` exits nonzero, produces empty stdout, or yields unparseable JSON, treat the result as `triggered: false` and proceed to Step 2 without blocking. Construct the fallback signal explicitly:

```bash
# On failure, construct a non-blocking fallback signal
GATE_1B_FALLBACK='{"gate_id":"1b","signal_type":"primary","triggered":false,"evidence":"Gate 1b script failure — defaulting to non-blocking","confidence":"low"}'
```

Gate 1b failure must never block a legitimate bug investigation.

### Step 2: Investigation Sub-Agent Dispatch (/dso:fix-bug)

**You MUST dispatch the investigation sub-agent described below.** Do NOT investigate inline — reading source code, grepping for patterns, running hypothesis commands, or analyzing the bug yourself does not satisfy this step. The sub-agent follows a rigorous investigation template (five whys, hypothesis generation, empirical validation) that prevents confirmation bias. Dispatch the sub-agent, await its RESULT report, then proceed to Step 3.

Dispatch investigation sub-agents based on the tier determined in Step 1. All sub-agents receive pre-loaded context before dispatch:
- Existing failing tests and their output
- Stack traces and error messages
- Relevant commit history (`git log --oneline -20 -- <affected-files>`)
- Prior fix attempts from the ticket (if any)

Sub-agents must run existing tests immediately to establish a concrete failure baseline before analyzing code.

#### BASIC Investigation (score < 3)

Launch a single **sonnet** sub-agent using the prompt template at `prompts/basic-investigation.md`.

Assemble the dispatch context by populating these named slots before launching the sub-agent:

| Slot | Source |
|------|--------|
| `{ticket_id}` | The bug ticket ID (e.g., `w21-xxxx`) |
| `{failing_tests}` | Output of `$TEST_CMD` — failing test names and their output |
| `{stack_trace}` | Stack trace extracted from test output or error logs |
| `{commit_history}` | Output of `git log --oneline -20 -- <affected-files>` |
| `{prior_fix_attempts}` | Ticket notes containing previous fix attempt records (empty string if none) |

The sub-agent must produce a RESULT conforming to the Investigation RESULT Report Schema defined below.

Sub-agent instructions:
- Structured localization: file, class/function, line
- Five whys analysis
- Self-reflection before reporting root cause
- Propose a single fix

#### INTERMEDIATE Investigation (score 3-5)

Launch a single **opus** sub-agent using the prompt template determined by agent availability:

- **Primary** (when `error-debugging:error-detective` is available via `discover-agents.sh`): use `prompts/intermediate-investigation.md`
- **Fallback** (when falling back to `general-purpose` agent): use `prompts/intermediate-investigation-fallback.md`

Both prompts apply the same investigation techniques — the only difference is the agent persona/role framing. Using the fallback does not reduce investigation quality.

Assemble the dispatch context by populating these named slots before launching the sub-agent:

| Slot | Source |
|------|--------|
| `{ticket_id}` | The bug ticket ID (e.g., `w21-xxxx`) |
| `{failing_tests}` | Output of `$TEST_CMD` — failing test names and their output |
| `{stack_trace}` | Stack trace extracted from test output or error logs |
| `{commit_history}` | Output of `git log --oneline -20 -- <affected-files>` |
| `{prior_fix_attempts}` | Ticket notes containing previous fix attempt records (empty string if none) |

The sub-agent must produce a RESULT conforming to the Investigation RESULT Report Schema defined below.

Sub-agent instructions (applied by both prompts):
- Dependency-ordered code reading
- Intermediate variable tracking
- Five whys analysis
- Hypothesis generation and elimination
- Self-reflection
- Propose at least 2 fixes with recommendation, confidence, risk, and tradeoffs

#### ADVANCED Investigation (score >= 6)

Launch **two independent opus** sub-agents with differentiated lenses:
- **Agent A (Code Tracer)**: execution path tracing, intermediate variable tracking, five whys, hypothesis set from code evidence — uses the prompt template at `prompts/advanced-investigation-agent-a.md`
- **Agent B (Historical)**: timeline reconstruction, fault tree analysis, git bisect, hypothesis set from change history — uses the prompt template at `prompts/advanced-investigation-agent-b.md`

Both agents are dispatched concurrently — dispatch both before awaiting either result.

Assemble the dispatch context by populating these named slots before launching each sub-agent. Both agents receive the same context:

| Slot | Source |
|------|--------|
| `{ticket_id}` | The bug ticket ID (e.g., `w21-xxxx`) |
| `{failing_tests}` | Output of `$TEST_CMD` — failing test names and their output |
| `{stack_trace}` | Stack trace extracted from test output or error logs |
| `{commit_history}` | Output of `git log --oneline -20 -- <affected-files>` |
| `{prior_fix_attempts}` | Ticket notes containing previous fix attempt records (empty string if none) |

Each agent must produce a RESULT conforming to the Investigation RESULT Report Schema defined below.

Each agent proposes at least 2 fixes following the INTERMEDIATE format.

##### Convergence Scoring (orchestrator step — after both agents return)

After both agents return their RESULT reports, compare their `ROOT_CAUSE` fields:

- **Full agreement** (same or semantically equivalent root cause): `convergence_score = 2` — confidence elevated; proceed directly to fix selection with high confidence.
- **Partial agreement** (overlapping cause category, e.g., both point to the same subsystem but different specific defects): `convergence_score = 1` — confidence moderate; present both root causes in fix approval with reasoning.
- **Divergence** (independent root causes with no category overlap): `convergence_score = 0` — proceed to fishbone synthesis.

##### Fishbone Synthesis (when convergence_score = 0)

When agents diverge, synthesize findings into a unified root cause report using the six fishbone categories:

For each category (Code Logic, State, Configuration, Dependencies, Environment, Data):
- Merge Agent A and Agent B findings for that category
- Note agreements and disagreements between agents
- Weight findings by evidence strength

The synthesized fishbone becomes the orchestrator's unified root cause report, which is used for fix approval (Step 4).

The orchestrator applies convergence scoring across both agents. Agents independently converging on the same root cause or fix increases confidence. Synthesize findings using fishbone categories: Code Logic, State, Configuration, Dependencies, Environment, Data.

#### ESCALATED Investigation

Triggered when ADVANCED investigation fails to resolve the issue. Launch **four opus** sub-agents with differentiated lenses:

<!-- REVIEW-DEFENSE: Agents 1-3 prompt files (escalated-investigation-agent-1.md, escalated-investigation-agent-2.md, escalated-investigation-agent-3.md) are created by upcoming GREEN tasks dso-mn94, dso-sjck, and dso-cxuh respectively. This SKILL.md is updated in GREEN task dso-bgqs as part of a TDD RED→GREEN sequence. The RED tests for those prompt files already exist and are expected to fail until the corresponding GREEN tasks create the files. Only agent-4.md exists at this stage; the remaining prompts will be added incrementally. -->
- **Agent 1 (Web Researcher)**: error pattern analysis, similar issue correlation, dependency changelogs — authorized to use WebSearch/WebFetch — uses the prompt template at `prompts/escalated-investigation-agent-1.md`
- **Agent 2 (History Analyst)**: timeline reconstruction, fault tree analysis, commit bisection — uses the prompt template at `prompts/escalated-investigation-agent-2.md`
- **Agent 3 (Code Tracer)**: execution path tracing, dependency-ordered reading, intermediate variable tracking, five whys — uses the prompt template at `prompts/escalated-investigation-agent-3.md`
- **Agent 4 (Empirical Agent)**: authorized to add logging and enable debugging to empirically validate or veto hypotheses from agents 1-3 — uses the prompt template at `prompts/escalated-investigation-agent-4.md`

**Dispatch concurrency and sequencing**: Dispatch Agents 1, 2, and 3 concurrently — dispatch all three before awaiting any result. After agents 1-3 return, dispatch Agent 4 with their findings included in `{escalation_history}` so the Empirical Agent can design targeted tests against the theoretical consensus.

Assemble the dispatch context by populating these named slots before launching each sub-agent. All agents receive the same base context; Agent 4 additionally receives agents 1-3 RESULT reports via `escalation_history`:

| Slot | Source |
|------|--------|
| `{ticket_id}` | The bug ticket ID (e.g., `w21-xxxx`) |
| `{failing_tests}` | Output of `$TEST_CMD` — failing test names and their output |
| `{stack_trace}` | Stack trace extracted from test output or error logs |
| `{commit_history}` | Output of `git log --oneline -20 -- <affected-files>` |
| `{prior_fix_attempts}` | Ticket notes containing previous fix attempt records (empty string if none) |
| `{escalation_history}` | Previous ADVANCED RESULT report, discovery file contents, and (for Agent 4) the RESULT reports from Agents 1-3 in this ESCALATED tier |

Each agent proposes at least 3 fixes not already attempted. Agents 1-3 use read-only sub-agents. Agent 4 is authorized to make temporary modifications (logging/debugging only) but must revert all such additions before returning results.

**Artifact revert requirement**: Agent 4's logging and debugging additions are investigation artifacts. They must be reverted or stashed after evidence is collected — investigation artifacts must not persist in the working tree. Findings go in the investigation RESULT report. Agent 4 must confirm revert via `artifact_revert_confirmed: true` in its RESULT.

##### Veto Logic (after all four agents return)

After all four agents return their RESULT reports, evaluate Agent 4's `veto_issued` field:

- **No veto** (`veto_issued: false`): proceed to fix selection with confidence weighted by Agent 4's empirical validation of the agents 1-3 consensus.
- **Veto issued** (`veto_issued: true`): Agent 4's empirical evidence directly contradicts the root cause proposed by the consensus of agents 1-3. The veto supersedes the theoretical analysis. When a veto is issued, dispatch a **resolution agent**.

**Resolution agent dispatch (on veto)**: The resolution agent receives all four RESULT reports, weighs the theoretical evidence from agents 1-3 against the empirical evidence from Agent 4, conducts additional targeted tests to break any remaining tie, and surfaces the highest-confidence conclusion. The resolution agent's conclusion governs fix selection.

##### Terminal Escalation

If ESCALATED investigation (with or without resolution agent) cannot produce a high-confidence root cause, this is the **ESCALATED terminal condition**. Log `ESCALATED terminal — user escalation required` and do NOT attempt any further autonomous fix. Surface all findings to the user:

- All root causes considered with confidence levels
- All fixes attempted with results
- All hypothesis test results
- All RESULT reports from agents 1-4 (and the resolution agent if dispatched)
- Recommendation for manual investigation

### Step 3: Hypothesis Testing (/dso:fix-bug)

For each root cause proposed by Step 2:
1. Propose a concrete test (bash command, unit test, or assertion) that would **prove or disprove** the suspected root cause
2. Run the test
3. Record the result in the discovery file (see Discovery File Protocol below)

Example:
```bash
# Hypothesis: the config parser silently drops keys with dots
echo '{"a.b": 1}' | python3 -c "import json,sys; d=json.load(sys.stdin); print('a.b' in d)"
# Expected: True (if hypothesis wrong) or False (if hypothesis correct)
```

Tests that confirm a root cause increase confidence. Tests that disprove a root cause eliminate it from consideration.

### Step 3.5: Hypothesis Validation Gate (/dso:fix-bug)

Before proceeding to fix approval or fix implementation, validate the `hypothesis_tests` section of the investigation RESULT report.

**Gate logic** (applied after Step 3 completes):

1. **Check for hypothesis_tests entries**: If the investigation RESULT has no `hypothesis_tests` section, or the section is missing or empty (zero entries), escalate to the next investigation tier. A missing or empty `hypothesis_tests` section means the investigation produced no testable root cause — fix implementation must not proceed without confirmed evidence.

2. **Check for at least one confirmed verdict**: If all `hypothesis_tests` entries have `verdict: disproved` or `verdict: inconclusive` (no `verdict: confirmed` entry exists), escalate to the next investigation tier. All hypotheses being disproved means the true root cause has not been identified — proceeding to fix implementation would be speculative.

3. **Proceed only with confirmed evidence**: If at least one `hypothesis_tests` entry has `verdict: confirmed`, the root cause is sufficiently validated. Proceed to Step 4 (Fix Approval).

**Escalation on gate failure**: When the gate rejects the investigation result (missing/empty `hypothesis_tests`, or all disproved), escalate following the standard escalation path (BASIC → INTERMEDIATE → ADVANCED → ESCALATED → User). Include the gate failure reason and all investigation findings in the escalation context so the next tier can build on prior work.

```
GATE_FAILURE_REASON: no_confirmed_hypothesis
current_tier: <BASIC|INTERMEDIATE|ADVANCED|ESCALATED>
hypothesis_tests_count: <number of entries, 0 if missing>
confirmed_count: 0
finding_summary: <brief summary of what the investigation found before gate rejection>
```

Record the gate failure in the discovery file and as a ticket comment before escalating.

### Step 4: Fix Approval (/dso:fix-bug)

Determine whether the fix can be auto-approved or requires user input:

- **Auto-approve** if: there is exactly one proposed fix, OR one fix is high confidence + low risk + does not degrade functionality
- **User approval required** if: multiple competing fixes with comparable confidence/risk, OR all fixes degrade functionality, OR confidence is medium or below

When presenting fixes for user approval, display:
- Each proposed fix with description, risk level, and whether it degrades functionality
- Confidence level in each root cause
- Confidence level in each fix
- Results from hypothesis testing (Step 3) alongside corresponding root causes
- Convergence notes (when multiple agents independently identified the same root cause or fix)

### Step 4.5: Fix Complexity Evaluation (/dso:fix-bug)

Before writing a RED test or implementing the fix, evaluate the complexity of the proposed fix scope using the complexity-evaluator agent definition:

```
Read: plugins/dso/agents/complexity-evaluator.md
Input: approved fix description, files affected, estimated change scope
```

**Note**: fix-bug reads the complexity-evaluator agent definition inline (rather than dispatching a sub-agent) to avoid nested dispatch — fix-bug often runs as a sub-agent of debug-everything, and dispatching a sub-agent from within a sub-agent risks Critical Rule 23 failures. The agent definition file contains the same five-dimension rubric and classification rules.

**TRIVIAL or MODERATE fix**: proceed to Step 5 (RED Test).

**COMPLEX fix**: the fix scope is too large for a single bug fix track. The behavior depends on execution context:

**When running as orchestrator (not a sub-agent)**:
1. Record the finding: `ticket comment <BUG_TICKET_ID> "Fix complexity: COMPLEX — escalating to epic"`
2. Invoke `/dso:brainstorm` to create an epic for the refactor or larger change
3. Stop — do NOT proceed to Step 5 or Step 6 in this session

**When running as a sub-agent** (detected per Sub-Agent Context Detection below):
1. Record the finding: `ticket comment <BUG_TICKET_ID> "Fix complexity: COMPLEX — returning escalation to orchestrator"`
2. Return a COMPLEX_ESCALATION report to the calling orchestrator instead of invoking `/dso:brainstorm` directly (sub-agents cannot reliably invoke skills):

```
COMPLEX_ESCALATION: true
escalation_type: COMPLEX
bug_id: <ticket-id>
investigation_tier_needed: orchestrator-level re-dispatch
investigation_findings: <summary of root cause candidates, confidence, and evidence from investigation>
escalation_reason: <why the fix is COMPLEX — e.g., cross-system refactor, multiple subsystems affected>
```

3. Stop — do NOT proceed to Step 5 or Step 6. The orchestrator receives this report and decides how to proceed (e.g., re-dispatch `/dso:fix-bug` at orchestrator level with full authority, or invoke `/dso:brainstorm` to create an epic).

### Step 5: RED Test (/dso:fix-bug)

If the bug already causes an existing test to fail, skip this step — the existing test serves as the RED test.

Otherwise, write a RED test by dispatching `dso:red-test-writer`. If the writer rejects the task, follow the three-tier escalation protocol.

### RED Test Dispatch via dso:red-test-writer

Dispatch a task to `dso:red-test-writer` (sonnet) with the bug context (bug description, root cause from investigation, files affected, and the approved fix description from Step 4).

Parse the leading `TEST_RESULT:` line from the output:

| Result | Action |
|--------|--------|
| `TEST_RESULT:written` | Success. Proceed to Step 5.5 using `TEST_FILE` and `RED_ASSERTION` fields. |
| `TEST_RESULT:rejected` | This inline dispatch was the sonnet attempt. On rejection, proceed to **Tier 2** of the escalation protocol in `plugins/dso/skills/sprint/prompts/red-task-escalation.md` (skip Tier 1 — already attempted here). `TEST_RESULT:rejected` is **not** an infrastructure failure. See fix-bug verdict mapping below. |
| Timeout / malformed / non-zero exit | Treat as `TEST_RESULT:rejected`. Proceed to Tier 2 of the escalation protocol. |

**Fix-bug verdict mapping** (how escalation verdicts map to fix-bug workflow):
- `VERDICT:CONFIRM` (TDD infeasible) → return to Step 2 and escalate to the next investigation tier. The bug may require a different fix approach that is testable.
- `VERDICT:REVISE` (task spec insufficient) → re-run investigation (Step 2) with the evaluator's revision guidance appended to the investigation context.
- `VERDICT:REJECT` (retry at opus) → proceed to Tier 3 per the escalation template.

When `TEST_RESULT:written`, run the new test to confirm it fails (RED):

```bash
# Run the new test to confirm it fails (RED)
$TEST_CMD  # Should see the new test FAIL
```

The test failure should confirm the root cause identified during investigation when possible.

If a previous investigation loop created a RED test for this bug, the existing test may be edited rather than creating a new one — dispatch `dso:red-test-writer` with the existing test file path so it can update rather than create.

**If no RED test can be written** (all three tiers in `red-task-escalation.md` are exhausted): return to Step 2 and escalate to the next investigation tier. Include the rejection payloads and reasoning with the investigation prompt.

### Step 5.5: RED-before-fix Gate (/dso:fix-bug)

**Mechanical bug exemption**: This gate does NOT apply to mechanical bugs (import errors, lint violations, config syntax errors, type annotations) routed through the Mechanical Fix Path. Those bugs bypass Steps 2–5 entirely and proceed directly from Step 1 to a direct fix. The Mechanical Fix Path has no RED test requirement because the fix is deterministic and verified by running `$TEST_CMD` and `$LINT_CMD` after applying it.

Before dispatching any fix implementation (Step 6), verify that a RED test exists and has been confirmed failing. This gate blocks any code modification — Edit, Write, or fix sub-agent dispatch — until it is satisfied.

**Gate logic** (applied after Step 5 completes):

1. **Check that a RED test exists**: If Step 5 was skipped because an existing test was already failing, that test counts as the RED test. If Step 5 was executed, the new test written there is the RED test.

2. **Check that the RED test has been confirmed failing**: The RED test must have been run and confirmed to fail before fix implementation proceeds. If the test was not run or the run result is not available, run it now:
   ```bash
   $TEST_CMD  # Must show the RED test FAILING
   ```
   If the test does not fail, do NOT proceed to Step 6. Return to Step 5 to diagnose why the test passes unexpectedly — this indicates either the test is wrong or the bug is already fixed.

3. **Do not proceed to Step 6 if the RED test has not been confirmed failing.** Any code modification (Edit, Write, sub-agent fix dispatch) is blocked until the RED test is confirmed failing in a test run output you have observed in this session.

**Gate failure action**: If no RED test can be confirmed failing, do NOT skip to fix implementation. Return to Step 5 and address why the RED test cannot be confirmed.

**LLM-behavioral bug exemption**: This gate is relaxed for llm-behavioral bugs. LLM behavioral bugs (prompt regressions, agent guidance gaps, skill misinterpretation) cannot always have a traditional executable RED unit test written before the fix — the behavioral regression lives in natural language instructions, not in executable code paths. For llm-behavioral bugs, the RED unit test requirement is replaced with eval-based verification: define an eval assertion that would fail with the current skill/agent/prompt content and pass after the fix. If no eval framework is available, document the behavioral assertion in the ticket as the verification criterion before proceeding to fix implementation.

### Step 6: Fix Implementation (/dso:fix-bug)

Launch a sub-agent to implement the approved fix:
- The sub-agent receives the full investigation RESULT (root cause, confidence, approved fix)
- Change ONLY what is necessary — no refactoring, no scope creep
- One logical change at a time

### Step 7: Verify Fix (/dso:fix-bug)

Verify that RED tests are now GREEN:

```bash
$TEST_CMD           # RED tests should now PASS
$LINT_CMD           # No lint regressions
$FORMAT_CHECK_CMD   # No format regressions
```

**If verification fails**: return to Step 2 and escalate to the next investigation tier. Include the attempted fix and test results with the investigation prompt.

**If ESCALATED investigation has already been attempted and verification still fails**: this is the terminal **ESCALATED** condition. Surface all findings to the user — do NOT attempt another blind fix. Report:
- All root causes considered with confidence levels
- All fixes attempted with results
- All hypothesis test results
- Recommendation for manual investigation

### Gate 2a: Reversal Check (/dso:fix-bug)

After verification passes (Step 7) and before committing (Step 8), run the reversal check gate to detect whether the proposed fix unintentionally undoes a recent committed change.

**Dispatch**: Run `gate-2a-reversal-check.sh` with the affected file paths. If Gate 1a returned intent-aligned for this bug, pass the `--intent-aligned` flag to suppress reversal detection (the reversal is expected and intentional, so duplicate blocking is unnecessary).

Before running, populate `AFFECTED_FILES` from the investigation results — these are the source files modified by the proposed fix (obtained from the investigation sub-agent RESULT report's `affected_files` field or from `git diff --name-only`):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
# Populate AFFECTED_FILES_ARR as a bash array from investigation RESULT report
# (affected_files field) or from the working-tree diff:
#   mapfile -t AFFECTED_FILES_ARR < <(git diff --name-only)
# Each element must be a separate array entry so gate-2a-reversal-check.sh
# receives per-file arguments (it uses FILES+=("$arg") for each positional arg).
AFFECTED_FILES_ARR=( "<file1>" "<file2>" )   # replace with actual paths
# Guard against unset GATE_1A_RESULT (e.g., mechanical fix path that bypassed Step 1.5)
GATE_1A_RESULT=${GATE_1A_RESULT:-}
# If Gate 1a returned intent-aligned, add --intent-aligned to suppress
if [ "$GATE_1A_RESULT" = "intent-aligned" ]; then
    GATE_2A_OUTPUT=$(bash "$PLUGIN_SCRIPTS/gate-2a-reversal-check.sh" --intent-aligned "${AFFECTED_FILES_ARR[@]}" 2>/dev/null)
else
    GATE_2A_OUTPUT=$(bash "$PLUGIN_SCRIPTS/gate-2a-reversal-check.sh" "${AFFECTED_FILES_ARR[@]}" 2>/dev/null)
fi
GATE_2A_EXIT=$?
```

**Parse the gate signal**: The script outputs a JSON object conforming to `plugins/dso/docs/contracts/gate-signal-schema.md`. Parse the `triggered` and `signal_type` fields from stdout.

**Reversal behavior**: The script compares the working-tree diff against recent commit history. If >50% of a recent commit's changed lines are inverted by the proposed fix, the gate fires (`triggered: true`, `signal_type: "primary"`). The gate also recognizes revert-of-revert patterns — when the commit being reversed is itself a revert (message matches `^Revert`, case-insensitive), the inversion is treated as an intentional re-application of the original change, and the gate does not fire.

**On triggered:true**: Add a primary signal to the gate accumulator. The reversal detection is a blocking signal — present the evidence to the user and require confirmation that the reversal is intentional before proceeding to Step 8.

**Error handling (graceful degradation)**: If `gate-2a-reversal-check.sh` exits nonzero, produces empty stdout, or outputs JSON that cannot be parsed, construct a fallback gate signal and log a warning:

```json
{"gate_id": "2a", "triggered": false, "signal_type": "primary", "evidence": "gate error: <reason>", "confidence": "low"}
```

This ensures `validate-gate-signal.py` receives a complete 5-field signal on error paths. The gate degrades to triggered:false so that gate errors do not block the fix workflow.

### Gate 2b: Blast Radius Annotation (/dso:fix-bug)

Gate 2b is a **modifier** gate — it appends a blast-radius annotation to the escalation dialog context but never adds a primary signal count. On error (nonzero exit, empty stdout, or JSON parse failure), skip the annotation silently. Gate 2b cannot block the fix workflow on its own.

**When to run**: After Step 7 (Verify Fix) passes, run `gate-2b-blast-radius.sh` with the affected file path(s) and `--repo-root`:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/gate-2b-blast-radius.sh" "<affected_file_path>" --repo-root "$(git rev-parse --show-toplevel)"
```

**Parsing the gate signal**: Parse the JSON emitted to stdout. The signal conforms to `gate-signal-schema.md`:
- `gate_id`: `"2b"`
- `signal_type`: always `"modifier"` — Gate 2b is a modifier only; it enriches context but never drives a block decision
- `triggered`: `true` if the file has a convention match or fan-in > 0; `false` otherwise
- `evidence`: human-readable annotation starting with `"Note:"`
- `confidence`: `"high"` | `"medium"` | `"low"`

**Behavior on `triggered: true`**: Append the `evidence` annotation to the escalation dialog context. This enrichment is only visible when another gate has already triggered a primary signal — Gate 2b provides supporting context, not a standalone block reason.

**Behavior on `triggered: false`**: No action required. Nothing noteworthy was found.

**Error handling**: On nonzero exit, empty stdout, or JSON parse failure, skip the annotation silently. Construct a full 5-field fallback signal with `triggered: false` and proceed without blocking:

```json
{"gate_id": "2b", "triggered": false, "signal_type": "modifier", "evidence": "gate error: <reason>", "confidence": "low"}
```

Do not surface gate errors to the user or halt the fix workflow.

**ast-grep / grep fallback**: `gate-2b-blast-radius.sh` uses ast-grep for fan-in analysis when available. When ast-grep is not installed, the script automatically falls back to grep-based analysis so the gate remains functional across all environments.

**Boundary with Centrality-Aware Test Gate**: Gate 2b runs at commit-time annotation (post-investigation), while the Centrality-Aware Test Gate operates at pre-commit time. They serve different phases and do not interact.

### Gate 2c: Test Regression Analysis (/dso:fix-bug)

Gate 2c is a **primary** gate (signal_type `"primary"`) — it detects whether the proposed fix weakens, removes, or loosens existing test assertions. It delegates to `gate-2c-test-regression-check.py` which reads a unified diff from stdin. On error, the gate defaults to triggered:false (non-blocking). A specific-to-specific value swap (e.g., `assertEqual(x, 42)` to `assertEqual(x, 57)`) does not fire this gate — both values are specific literals, so assertion specificity is preserved. This gate runs post-investigation after the fix is implemented (Step 6) and verified (Step 7), before commit (Step 8).

**When to run (Step 6.5)**: After Step 7 (Verify Fix) passes, pipe the working-tree diff of test files to the script via stdin. If Gate 1a returned `intent-aligned` for this bug, pass the `--intent-aligned` flag to suppress regression detection — when the fix corrects an assertion against documented intent, the test change is expected and intentional, so Gate 2c does not fire (epic SC3: 1a→2c suppression interaction).

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
TEST_DIR=$(bash "$PLUGIN_SCRIPTS/read-config.sh" test_gate.test_dirs)
TEST_DIR=${TEST_DIR:-tests/}
GATE_1A_RESULT=${GATE_1A_RESULT:-}
GATE_2C_FLAGS=()
if [ "$GATE_1A_RESULT" = "intent-aligned" ]; then
    GATE_2C_FLAGS+=(--intent-aligned)
fi
GATE_2C_FLAGS+=(--test-dir "$TEST_DIR")
GATE_2C_OUTPUT=$(git diff -- "$TEST_DIR" | python3 "$PLUGIN_SCRIPTS/gate-2c-test-regression-check.py" "${GATE_2C_FLAGS[@]}" 2>/dev/null)
GATE_2C_EXIT=$?
```

**Parsing the gate signal**: Parse the JSON emitted to stdout per `plugins/dso/docs/contracts/gate-signal-schema.md`:
- `gate_id`: `"2c"`
- `signal_type`: `"primary"` — when triggered, it drives a routing decision
- `triggered`: `true` if assertion removal, specificity reduction, or skip/xfail addition is detected; `false` otherwise
- `evidence`: human-readable explanation of what was detected
- `confidence`: `"high"` | `"medium"` | `"low"`

**On triggered:true**: Add a primary signal to the gate accumulator. The test regression detection is an independent signal — any removal or broadening of assertions fires the gate regardless of other gate outcomes. Present the evidence to the user and require confirmation before proceeding to Step 8.

**Specific-to-specific replacement exemption**: A fix that replaces one specific expected value with a different specific expected value does NOT trigger Gate 2c. For example, `assertEqual(result, 42)` changed to `assertEqual(result, 57)` is a specific-to-specific value swap — the assertion method is unchanged, both the old and new expected values are literals, and assertion specificity is preserved. Only specificity-reducing changes fire the gate: assertion removal, assertion count reduction, weakened matchers (e.g., `assertEqual` to `assertIsNotNone`), literal-to-variable replacement (e.g., `assertEqual(x, 42)` to `assertEqual(x, result)`), or skip/xfail additions.

**Error handling (graceful degradation)**: If `gate-2c-test-regression-check.py` exits nonzero, produces empty stdout, or outputs JSON that cannot be parsed, construct a fallback gate signal with triggered:false and log a warning:

```json
{"gate_id": "2c", "triggered": false, "signal_type": "primary", "evidence": "gate error: <reason>", "confidence": "low"}
```

This ensures `validate-gate-signal.py` receives a complete 5-field signal on error paths. The gate degrades to triggered:false so that gate errors do not block the fix workflow.

### Gate 2d: Dependency Check (/dso:fix-bug)

Gate 2d is a **primary** gate — it detects whether the proposed fix introduces new dependencies (imports or requires) that are not already declared in the project manifest or used elsewhere in the codebase. This gate runs post-investigation, after the fix is proposed.

**When to run**: After Step 7 (Verify Fix) passes, run `gate-2d-dependency-check.sh` with the affected file path(s) and `--repo-root`:

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
GATE_2D_OUTPUT=$(bash "$PLUGIN_SCRIPTS/gate-2d-dependency-check.sh" "${AFFECTED_FILES_ARR[@]}" --repo-root "$(git rev-parse --show-toplevel)" 2>/dev/null)
GATE_2D_EXIT=$?
```

**Parsing the gate signal**: Parse the JSON emitted to stdout. The signal conforms to `plugins/dso/docs/contracts/gate-signal-schema.md`:
- `gate_id`: `"2d"`
- `signal_type`: `"primary"` — Gate 2d is a primary signal; when triggered, it drives a routing decision
- `triggered`: `true` if a new dependency/import is detected that is not in the manifest and not used elsewhere; `false` otherwise
- `evidence`: human-readable explanation of what was detected (or why the gate did not fire)
- `confidence`: `"high"` | `"medium"` | `"low"`

**On triggered:true**: Add a primary signal to the gate accumulator. The dependency detection is a blocking signal — present the evidence to the user and require confirmation that the new dependency is intentional before proceeding to Step 8.

**Existing pattern exemption**: Code that follows existing patterns in the codebase does not trigger Gate 2d. If the import/require is already used elsewhere in the codebase (even if not declared in the manifest), the gate treats it as a pre-existing dependency pattern and does not fire. This prevents false positives on established conventions — only genuinely novel dependencies trigger escalation.

**Error handling (graceful degradation)**: If `gate-2d-dependency-check.sh` exits nonzero, produces empty stdout, or outputs JSON that cannot be parsed, construct a fallback gate signal and log a warning:

```json
{"gate_id": "2d", "triggered": false, "signal_type": "primary", "evidence": "gate error: <reason>", "confidence": "low"}
```

This ensures `validate-gate-signal.py` receives a complete 5-field signal on error paths. The gate degrades to triggered:false so that gate errors do not block the fix workflow.

### Escalation Routing (/dso:fix-bug)

After all gate checks (Gates 1b, 2a, 2b, 2c, and 2d) have run, collect the resulting gate signals and route the fix workflow proportionally based on how many primary gates fired.

**Collect gate signals into an array**:

```bash
# Build a JSON array of all gate signals collected during this session.
# Signals come from: Gate 1b (feature-request check), Gate 2a (reversal check),
# Gate 2b (blast radius — modifier), Gate 2c (test regression), Gate 2d (dependency check).
# Each signal must conform to plugins/dso/docs/contracts/gate-signal-schema.md.
#
# Pass each gate output via stdin as newline-delimited JSON objects; Python reads them safely
# without bash variable interpolation inside Python string literals.
GATE_SIGNALS_JSON=$(printf '%s\n' \
    "${GATE_1B_OUTPUT:-}" \
    "${GATE_2A_OUTPUT:-}" \
    "${GATE_2B_OUTPUT:-}" \
    "${GATE_2C_OUTPUT:-}" \
    "${GATE_2D_OUTPUT:-}" \
  | python3 -c "
import json, sys
signals = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            signals.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # skip empty or unparseable gate outputs
print(json.dumps(signals))
")
```

**Determine complexity flag**: If the complexity evaluator (Step 4.5) returned `COMPLEX`, pass `--complex` to the router.

```bash
COMPLEX_FLAG=""
if [ "${FIX_COMPLEXITY:-}" = "COMPLEX" ]; then
    COMPLEX_FLAG="--complex"
fi
```

**Run `gate-escalation-router.py`**: Pass all collected gate signals as JSON stdin:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
ROUTING_OUTPUT=$(echo "$GATE_SIGNALS_JSON" | python3 "$PLUGIN_SCRIPTS/gate-escalation-router.py" $COMPLEX_FLAG)
ROUTE=$(echo "$ROUTING_OUTPUT" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('route','auto-fix'))" 2>/dev/null || echo "auto-fix")
```

**Error handling**: `gate-escalation-router.py` exits 0 always and routes malformed or empty JSON input to `route: "auto-fix"` (fail-open). If the router exits nonzero or its stdout is unparseable by the ROUTE extraction command above, default `ROUTE="auto-fix"` — consistent with the router's own fail-open contract. The `dialog` path is only triggered by the router when exactly 1 primary gate signal fires; it is not a fallback for infrastructure errors.

**Routing table**:

| Route | Condition | Action |
|-------|-----------|--------|
| `auto-fix` | 0 primary signals triggered (and not COMPLEX) | Proceed to Step 8 without any dialog |
| `dialog` | Exactly 1 primary signal triggered | Prompt 1-2 inline questions with blast radius annotation from Gate 2b if available |
| `escalate` | 2+ primary signals triggered, OR COMPLEX classification | Escalate to `/dso:brainstorm` with all gate evidence |

**Route: `auto-fix`** — no primary gates fired. Proceed directly to Step 8 without pausing for user input.

**Route: `dialog`** — one primary gate fired. Ask 1-2 focused inline questions (the exact questions are scoped to the fired gate's evidence). If Gate 2b blast radius annotation is available in `dialog_context.modifier_evidence`, include it in the question framing so the user understands the affected surface. After the dialog answers are recorded, proceed to Step 8.

**Route: `escalate`** — 2 or more primary signals fired, or COMPLEX classification was returned. Do not proceed to Step 8. Instead:

1. Record the escalation finding:
   ```bash
   ticket comment <BUG_TICKET_ID> "Escalation routing: route=escalate — $(echo $ROUTING_OUTPUT | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(str(d.get(\"signal_count\",\"?\")) + \" primary signals, reason: \" + d.get(\"reason\",\"multi-signal escalation\"))')"
   ```
2. Invoke `/dso:brainstorm` with all gate evidence — this converts the fix into a tracked epic for proper planning and scoping.
3. Stop — do NOT proceed to Step 8 in this session.

**COMPLEX always escalates**: The `--complex` flag forces `route: "escalate"` regardless of primary signal count. Even 0 primary signals + COMPLEX classification results in epic escalation. This ensures that fix scopes evaluated as COMPLEX by the complexity evaluator (Step 4.5) always receive epic-level treatment.

**Interactivity integration**: When fix-bug runs in non-interactive mode (set by `/dso:debug-everything`'s interactivity flag), the `dialog` path cannot block for user input. In non-interactive mode, defer the dialog as an `INTERACTIVITY_DEFERRED` ticket comment and proceed to Step 8 as if `auto-fix`:

```bash
if [ "${FIX_BUG_INTERACTIVE:-true}" = "false" ] && [ "$ROUTE" = "dialog" ]; then
    ticket comment <BUG_TICKET_ID> "INTERACTIVITY_DEFERRED: 1 primary gate signal — dialog deferred (non-interactive mode). Gate evidence: $(echo $ROUTING_OUTPUT | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); ctx=d.get(\"dialog_context\") or {}; print(ctx.get(\"signal\",{}).get(\"evidence\",\"no evidence\"))')"
    ROUTE="auto-fix"
fi
```

When `route: "escalate"` and non-interactive mode, defer the epic escalation as a comment and stop:

```bash
if [ "${FIX_BUG_INTERACTIVE:-true}" = "false" ] && [ "$ROUTE" = "escalate" ]; then
    ticket comment <BUG_TICKET_ID> "INTERACTIVITY_DEFERRED: escalation to /dso:brainstorm deferred (non-interactive mode). Signal count: $(echo $ROUTING_OUTPUT | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(\"signal_count\",\"?\"))'). All gate evidence attached to this ticket for follow-up."
    # Stop — do not proceed to Step 8; escalation must be handled interactively.
    exit 0
fi
```

### Step 8: Commit and Close (/dso:fix-bug)

**When running as orchestrator (not a sub-agent)**:

1. Complete the commit workflow per `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md`.
2. Close the bug ticket:
   ```bash
   ticket transition <BUG_TICKET_ID> in_progress closed --reason="Fixed: <one-line summary of the fix>"
   ```

**When running as a sub-agent** (detected per Sub-Agent Context Detection below):

1. Do NOT commit — the orchestrator owns the commit workflow.
2. Do NOT close the ticket — the orchestrator handles ticket lifecycle after the sub-agent returns.
3. Return the resolved ticket ID in the sub-agent result so the orchestrator can commit and close:

```
FIX_RESULT: resolved
BUG_TICKET_ID: <ticket-id>
fix_summary: <one-line description of what was fixed>
files_changed: <comma-separated list of modified files>
```

The orchestrator receives this result and is responsible for committing the changes and closing the ticket.

## Cluster Investigation Mode

When invoked with multiple bug IDs, `/dso:fix-bug` operates in cluster invocation mode: it investigates all bugs as a single problem before deciding whether to proceed as one track or split.

### Cluster Invocation

```
/dso:fix-bug <id1> <id2> [<id3> ...]
```

Pass two or more ticket IDs to trigger cluster mode. All listed bugs are investigated together using the prompt template at `prompts/cluster-investigation.md`.

### Cluster Scoring

The cluster is scored using the highest individual score across all bugs in the cluster (conservative rule — treats the cluster as the most complex bug it contains). This determines the investigation tier for the single unified dispatch.

### Single-Problem Investigation

All bugs in the cluster are investigated as a single problem. A single investigation sub-agent is dispatched (at the tier determined by the highest-scoring bug) with the full context for every bug in the cluster. The sub-agent determines whether one root cause explains all symptoms or whether multiple independent root causes are present.

### Root-Cause-Based Splitting

After the cluster investigation completes:

- **Single root cause**: if one root cause explains all bugs, proceed as a single fix track from Step 3 onward.
- **Multiple independent root causes**: if the investigation identifies multiple independent root causes, split into one per-root-cause track. Each track follows the standard single-bug workflow from Step 3 onward.

Split tracks are independent — they may be worked in parallel or sequentially depending on resource availability.

## Investigation RESULT Report Schema

All investigation tiers produce a RESULT report with this schema. Higher tiers include additional fields.

```
ROOT_CAUSE: <one sentence describing the identified root cause>
confidence: high | medium | low
proposed_fixes:
  - description: <what the fix does>
    risk: high | medium | low
    degrades_functionality: true | false
    rationale: <why this fix addresses the root cause>
hypothesis_tests:
  - hypothesis: <what was tested>
    test: <the test command>
    observed: <what actually happened>
    verdict: confirmed | disproved | inconclusive
prior_attempts:
  - commit: <sha>
    description: <what was tried>
    outcome: <why it failed>
```

INTERMEDIATE and above add:
```
alternative_fixes: [...]  # at least 2 total proposals
tradeoffs_considered: <analysis of approach tradeoffs>
recommendation: <which fix and why>
```

ADVANCED adds:
```
convergence_score: <how many agents agreed on this root cause>
fishbone_categories:
  code_logic: <findings>
  state: <findings>
  configuration: <findings>
  dependencies: <findings>
  environment: <findings>
  data: <findings>
```

## Discovery File Protocol

Investigation findings are persisted to a discovery file for passing context between phases (investigation to fix, or across escalation tiers).

- **Path convention**: `/tmp/fix-bug-discovery-<ticket-id>.json`
- **Required fields**:
  - `root_cause` — one-sentence root cause description
  - `confidence` — high, medium, or low
  - `proposed_fixes` — array of fix proposals (each with description, risk, degrades_functionality)
  - `hypothesis_tests` — array of hypothesis test results
  - `prior_fix_attempts` — array of previous fix attempts (empty if none)
- **Written by**: investigation sub-agents (Step 2) and hypothesis testing (Step 3)
- **Read by**: fix approval (Step 4), fix implementation (Step 6), and escalation re-entry (Step 2 on retry)
- **Lifecycle**: created at first investigation, updated on escalation, deleted after successful commit (Step 8)

When escalating to the next tier, the discovery file from the previous tier is included in the new sub-agent's context so it does not repeat work.

## Sub-Agent Context Detection

When `/dso:fix-bug` is invoked inside a larger workflow (e.g., from `/dso:sprint` or `/dso:debug-everything`), it runs as a sub-agent. Sub-agent context affects which investigation tiers are available.

### Re-entry from COMPLEX_ESCALATION

When the invocation prompt contains a `### COMPLEX_ESCALATION Context` block (emitted by `/dso:debug-everything` Phase 6 Step 3a during orchestrator-level re-dispatch), skip Steps 1-3 and proceed directly to Step 4 (Fix Approval):

1. Parse the `investigation_findings` from the `COMPLEX_ESCALATION Context` block
2. Write the findings to the discovery file (`/tmp/fix-bug-discovery-<bug-id>.json`) with the parsed root cause, confidence, and proposed fixes
3. Skip to Step 4 (Fix Approval) — the prior investigation is pre-loaded and does not need to be repeated

This avoids re-running classification and investigation work that was already completed by the sub-agent before escalation.

### Detection Methods

**Primary — Agent tool availability**: Before dispatching investigation sub-agents, check whether the Agent tool is available in the current context. If the Agent tool is not available, the skill is running as a sub-agent (dispatched via the Task tool) and must surface findings to the caller instead of escalating.

**Fallback — orchestrator signal**: The orchestrator may also set `You are running as a sub-agent` in the dispatch prompt. When present, this confirms sub-agent context.

### Behavior in Sub-Agent Context

- **Ticket lifecycle (Step 0.5)**: Step 0.5 runs normally in sub-agent context — the sub-agent creates the ticket if needed and sets it to in-progress. The sub-agent does NOT close the ticket; it returns `BUG_TICKET_ID` in its result for the orchestrator to close after committing.
- **Commit and Close (Step 8)**: the sub-agent does NOT commit or close the ticket. It returns a `FIX_RESULT` report with the ticket ID, fix summary, and changed files. The orchestrator handles commit and ticket closure.
- **BASIC and INTERMEDIATE** investigation tiers: fully supported in sub-agent context (single sub-agent dispatch).
- **ADVANCED investigation** (two concurrent agents): check Agent tool availability before dispatch; if unavailable, treat as INTERMEDIATE with a note.
- **ESCALATED investigation** (four agents): check Agent tool availability before dispatch; if unavailable, surface findings and return a `COMPLEX_ESCALATION` report to the calling orchestrator (see Escalation Report Format below).
- **COMPLEX fix** (Step 4.5): when the complexity evaluator classifies a fix as COMPLEX, return a `COMPLEX_ESCALATION` report instead of invoking `/dso:brainstorm` directly (see Step 4.5 for the report format). The orchestrator receives this report and handles re-dispatch or epic creation.

### Escalation Report Format

When running as a sub-agent and ADVANCED or ESCALATED investigation is needed but cannot be performed due to Agent tool unavailability or other blocking conditions, return a `COMPLEX_ESCALATION` report to the calling orchestrator. This uses the same format as Step 4.5's COMPLEX_ESCALATION — one unified format for all escalation paths:

```
COMPLEX_ESCALATION: true
escalation_type: advanced_needed | escalated_needed | terminal
bug_id: <ticket-id>
investigation_tier_needed: ADVANCED | ESCALATED
investigation_findings: <summary of root cause candidates, confidence, evidence, and hypothesis test results from investigation>
escalation_reason: <why escalation is needed and cannot proceed autonomously>
```

The calling orchestrator detects `COMPLEX_ESCALATION: true` and parses the same fields regardless of whether the escalation originated from complexity evaluation (Step 4.5) or tier unavailability (this section). See `/dso:debug-everything` Phase 6 Step 3a for the orchestrator's handling of this signal.

## Escalation Triggers

Escalation to the next investigation tier occurs when:

1. **Fix verification fails** (Step 7) — the implemented fix did not resolve the bug. The attempted fix and test results are passed to the next tier.
2. **No or low-confidence root cause** (Step 2) — investigation returned no root cause, or confidence is medium or low. The investigation findings are passed to the next tier.

Escalation path: BASIC -> INTERMEDIATE -> ADVANCED -> ESCALATED -> **User** (terminal).

When ESCALATED investigation fails to produce a high-confidence root cause, the skill enters the **ESCALATED terminal condition**: surface all findings to the user with the full investigation history. No blind fix is attempted.

## Context Pre-Loading

Before dispatching any investigation sub-agent, the orchestrator pre-loads:

1. **Existing failing tests**: run `$TEST_CMD` and capture output showing which tests fail and how
2. **Stack traces**: extract from test output or error logs
3. **Commit history**: `git log --oneline -20 -- <affected-files>` for recent changes to relevant files
4. **Prior fix attempts**: read ticket notes for any CHECKPOINT or fix-attempt records

This context is included in every sub-agent dispatch prompt so agents begin with concrete evidence rather than starting from scratch.

## Escalation Handoff Context

When escalating from one tier to the next, the following context is passed:

- Previous tier's complete RESULT report
- Discovery file contents (`/tmp/fix-bug-discovery-<ticket-id>.json`)
- Hypothesis test results from Step 3
- Any fix attempts and their verification results from Step 7
- The original bug description and all ticket notes

The next tier receives everything the previous tier learned, preventing duplicated investigation work.
