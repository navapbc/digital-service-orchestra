---
name: fix-bug
description: Classify bugs by type and severity, then route through the appropriate investigation and fix path. Replaces tdd-workflow for bug fixes.
user-invocable: true
---

# Fix Bug: Investigation-First Bug Resolution

Enforce a hard separation between investigation and implementation. Bugs are classified, scored, investigated to root cause, and only then fixed — with TDD discipline ensuring the fix is verified.

This skill replaces `/dso:tdd-workflow` for bug fixes. For new feature development using TDD, continue to use `/dso:tdd-workflow`.

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

## Error Type Classification

Before scoring, classify the error:

### Mechanical Errors

Mechanical errors have an obvious, deterministic fix that requires no investigation. These skip the scoring rubric and route directly to the **Mechanical Fix Path** (read the error, apply the fix, validate).

Types of mechanical errors:
- **import error** — missing or incorrect import statement
- **type annotation** — incorrect or missing type hint
- **lint violation** — ruff, mypy, or similar linter failure with a clear fix
- **config syntax** — malformed YAML, TOML, JSON, or conf file

Mechanical Fix Path:
1. Read the error message and identify the exact file and line
2. Apply the deterministic fix (add import, fix type, fix lint, fix syntax)
3. Run `$TEST_CMD` and `$LINT_CMD` to validate
4. If validation passes, proceed to Step 8 (Commit)
5. If validation fails with a NEW error, reclassify — it may be behavioral

### Behavioral Errors

All errors that are NOT mechanical are behavioral. These require investigation and proceed to Step 1 (Score and Classify).

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

If a known issue matches, add its details to the bug ticket via `tk add-note <id> "Known issue match: ..."`. The known issue context informs investigation but does not skip it.

### Step 1: Score and Classify (/dso:fix-bug)

1. Read the bug description, error messages, and stack traces
2. Classify: **mechanical** or **behavioral** (see Error Type Classification above)
3. If mechanical: follow the Mechanical Fix Path, then skip to Step 8
4. If behavioral: apply the Scoring Rubric to determine investigation tier
5. Record the classification and score in a ticket note: `tk add-note <id> "Classification: behavioral, Score: <N> (<tier>)"`

### Step 2: Investigation Sub-Agent Dispatch (/dso:fix-bug)

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

### Step 5: RED Test (/dso:fix-bug)

If the bug already causes an existing test to fail, skip this step — the existing test serves as the RED test.

Otherwise, create a unit test that fails because of the bug:

```bash
# Run the new test to confirm it fails (RED)
$TEST_CMD  # Should see the new test FAIL
```

The test failure should confirm the root cause identified during investigation when possible.

If a previous investigation loop created a RED test for this bug, the existing test may be edited rather than creating a new one.

**If no RED test can be written**: return to Step 2 and escalate to the next investigation tier. Include the failed test attempt and reasoning with the investigation prompt.

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

### Step 8: Commit (/dso:fix-bug)

Complete the commit workflow per `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md`.

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
tests_run:
  - hypothesis: <what was tested>
    command: <the test command>
    result: confirmed | disproved | inconclusive
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
  - `tests_run` — array of hypothesis test results
  - `prior_fix_attempts` — array of previous fix attempts (empty if none)
- **Written by**: investigation sub-agents (Step 2) and hypothesis testing (Step 3)
- **Read by**: fix approval (Step 4), fix implementation (Step 6), and escalation re-entry (Step 2 on retry)
- **Lifecycle**: created at first investigation, updated on escalation, deleted after successful commit (Step 8)

When escalating to the next tier, the discovery file from the previous tier is included in the new sub-agent's context so it does not repeat work.

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
