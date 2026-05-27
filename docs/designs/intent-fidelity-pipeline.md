# Intent Fidelity Pipeline

Remediation plan for Shape-Over-Substance Closure (SOSC) — the chronic failure pattern where epics close P1=PASS with load-bearing functions implemented as empty stubs.

**Status**: Plan complete, reviewed (2x opus, 1x bot-psychologist). Ready for brainstorm.
**Date**: 2026-05-26
**Absorbed epics**: 6111-fc7f (Execution Trace Requirement), 6068-cb2d (Goal-backward verification)

## Problem Statement

The DSO pipeline enforces process compliance but not outcome compliance. Epics close P1=PASS with load-bearing functions implemented as empty stubs. 72% of audited epics show architecture-vs-evidence gaps. The root cause: every verification checkpoint evaluates structural presence rather than behavioral outcome.

### Evidence

- **Epic 4047**: 6/7 inbound mutation leaves were empty stubs. Verifier signed off P1=PASS. The reconciler "converged" by flowing 2,050 mutations through no-op handlers.
- **Bug cd24-6553**: CI workflow epic closed as complete, but the workflow never fired for the next consumer. Verifier accepted "file exists" as evidence.
- **Bug 41b5-cd7f**: Orchestrator spent 600 tool calls deferring a 10-line fix via RED markers instead of implementing.
- **Bug 1761-21ca**: Epic→story→task decomposition allows behavioral implementation gaps to satisfy DDs as shape-only, producing P1=PASS closures with no-op load-bearing functions.
- **d076 postmortem**: 39-epic audit found 72% gap rate (28 HIGH + 6 MEDIUM architecture-vs-evidence gaps).

### Root Causes (from opus audit)

1. **Verification gap**: Completion verifier reads code but cannot execute it — structurally unable to detect empty stubs that look correct to grep
2. **DD measurability is self-assessed**: No mechanical check that a Done Definition requires behavioral evidence vs. structural presence
3. **Defer-as-skip**: RED markers, obligation tickets, and tracking-ticket creation have no enforcement that deferred work is ever completed
4. **Decomposition coverage gaps**: Framework tasks are generated but per-leaf behavioral tasks are not
5. **Scrutiny gates are bypassable**: Behavioral-only gates are bypassed under context pressure

## Goal

Reliably translate user-defined intent into verified execution. What the user defines and approves during brainstorming is what gets implemented, tested, and proven working before closure.

## Design Principles

1. **Intent flows from brainstorm; proof flows from implementation** — brainstorm defines *what to prove*; agents close to implementation define *how to prove it*
2. **Mechanical over behavioral** — classification, execution, and validation are scripts, not LLM judgment calls
3. **One script call, one trace file** — the orchestrator runs one command; the verifier reads one file
4. **Missing evidence is inconclusive** — `EVIDENCE_PENDING` replaces both silent-PASS and hard-FAIL
5. **Each phase delivers measurable value independently** — no phase depends on a later phase for its benefit

## Known Phase 1 Limitation (Explicitly Accepted)

Phase 1 does not validate that a Verify command tests what its parent Verify-intent describes. A story-decomposer could produce a syntactically valid command that tests the wrong behavior. This semantic fidelity gap is accepted until Phase 3's cross-check closes it. Phase 1 provides the *plumbing*; Phase 3 provides the *semantic validation*.

---

## Phase 1: Execution Trace Infrastructure

**Delivers**: A mechanical proof layer — every story closure includes execution traces from DD Verify commands. The completion verifier evaluates traces as primary evidence instead of relying on code inspection.

**Measurable outcome**: Run the pipeline on a past epic that exhibited SOSC (e.g., replay epic 4047's stories). Count how many stories that previously closed P1=PASS would now produce trace FAIL or EVIDENCE_PENDING. Target: >=80% of SOSC stories blocked.

### 1.1 Execution Trace Contract

**New file**: `plugins/dso/docs/contracts/execution-trace.md`

Shared schema referenced by both the execution script and the completion verifier:

```yaml
schema_version: 1
trace:
  story_id: string
  generated_at: ISO8601
  manifest:                          # ALL DDs — executed or not
    - dd_id: string                  # e.g., "dd-1"
      dd_text: string                # verbatim DD text
      verify_command: string | null  # null = no command found
      executed: boolean
      skip_reason: string | null     # e.g., "no verify command", "parse error"
  results:                           # only executed DDs
    - dd_id: string
      verify_command: string
      exit_code: integer
      stdout_tail: string            # last 20 lines
      stderr_tail: string            # last 20 lines
      duration_ms: integer
      attempt: integer               # 1 or 2 (retry on first failure)
      outcome: PASS | FAIL | TIMEOUT | SKIP
      confidence: high | normal      # high = known test runner; normal = other
  summary:
    total_dds: integer
    executed: integer
    passed: integer
    failed: integer
    timeout: integer
    skipped: integer
    no_command: integer
```

The **manifest** is built from the ticket's DD list independently of Verify command extraction. A DD with a malformed or missing Verify command appears as `verify_command: null, executed: false, skip_reason: "no verify command"`. This ensures the verifier can detect coverage gaps even when extraction fails.

The **confidence** field on results provides a quality signal: commands invoking a known test runner (`pytest`, `make`, `npm test`, `bash` on a `test-*.sh`, `curl`, `httpie`) get `high`; others get `normal`. Informational only — does not block.

### 1.2 Structured Verify Command Storage

**File**: `plugins/dso/docs/ticket-cli-reference.md` (new subcommand)

Add `set-verify-commands` following the existing `set-file-impact` pattern:

```
.claude/scripts/dso ticket set-verify-commands <ticket_id> <json-array>
```

```json
[
  {"dd_id": "dd-1", "dd_text": "The reconciler creates local tickets...", "command": "pytest tests/integration/test_inbound_create.py -k test_creates_ticket"},
  {"dd_id": "dd-2", "dd_text": "Invalid mode exits non-zero...", "command": "bash tests/test-mode-validation.sh"}
]
```

Last-write-wins semantics. Compiled state field: `verify_commands`. This eliminates fragile extraction-from-prose — the script reads a structured JSON field, not free-text markdown.

### 1.3 Pre-Verifier Execution Script

**New file**: `plugins/dso/scripts/pre-verifier-execute.sh`

Standalone script with a clean contract:
- **Input**: story ID
- **Output**: JSON trace file path (printed to stdout)
- **Behavior**:
  1. Reads `verify_commands` structured field from ticket via `ticket show`
  2. Builds manifest from the story's DD list (independently of verify_commands — DDs without commands appear as `skip_reason: "no verify command"`)
  3. Executes each command with configurable timeout (default 60s, from `dso-config.conf` key `verify.timeout_seconds`)
  4. On first failure: retries once (flake tolerance)
  5. On timeout: records `outcome: TIMEOUT`
  6. Classifies command confidence (known runner -> `high`, other -> `normal`)
  7. Writes trace JSON to temp file per contract schema
  8. Prints temp file path to stdout

Does NOT attempt fixes. Does NOT dispatch sub-agents. Pure execution and reporting.

### 1.4 Sprint Orchestrator Integration

**File**: `plugins/dso/skills/sprint/SKILL.md` (Phase F, new step before Step 18)

One HARD-GATE step:

```
<HARD-GATE>
Before dispatching dso:completion-verifier, run the pre-verifier
execution script. This is NOT optional. "All tests pass" and "all
tasks closed" do not substitute for DD-level verification.

VERIFY_TRACE=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/pre-verifier-execute.sh" <story-id>)

Pass VERIFY_TRACE_PATH=$VERIFY_TRACE in the completion-verifier prompt.

If VERIFY_TRACE is empty or the script exits non-zero, log the error
and pass VERIFY_TRACE_PATH="" to the verifier (backward-compat path).
</HARD-GATE>
```

One bash command. No loop. No conditional branching. No fix dispatching.

### 1.5 Completion Verifier Trace Evaluation

**File**: `plugins/dso/agents/completion-verifier.md`

New Step 2.7 between Step 2 (Load Implementation Evidence) and Step 3 (Evaluate Each Criterion):

**Step 2.7: Load Execution Traces**

When `VERIFY_TRACE_PATH` is present and non-empty:
1. Read the trace file
2. For each DD being evaluated, look up the trace result

**Modified Step 3 evaluation rules** (for DDs with traces):

| Trace Outcome | Verifier Behavior |
|--------------|-------------------|
| PASS | Primary evidence for PASS. Aspirational-implementation detection still runs as secondary check — a PASS trace with countervailing aspirational signals (e.g., test asserts `True` with no behavioral content) produces a finding, not an automatic PASS. |
| FAIL | Definitive FAIL. No code-inspection override. Evidence is stderr/stdout from trace. |
| TIMEOUT | `EVIDENCE_PENDING`. Code inspection is supplementary but CANNOT produce PASS alone. Finding: "Verify command timed out after {duration_ms}ms." |
| SKIP | Existing code-inspection behavior. No change. |
| DD in manifest with no command | `EVIDENCE_PENDING`. Finding: "DD has no Verify command. Verification gap." |
| DD missing from manifest | `EVIDENCE_PENDING`. Finding: "DD not found in execution trace manifest." |
| No trace file (VERIFY_TRACE_PATH empty) | Full backward compatibility. Existing behavior. No regression. |

**EVIDENCE_PENDING** is a new P1-level signal:
- P1 = `EVIDENCE_PENDING` (not PASS, not FAIL)
- Story cannot close
- Remediation: "run the Verify command manually, fix the timeout, or add a Verify command to the DD"

### 1.6 EVIDENCE_PENDING Escalation Protocol

**File**: `plugins/dso/skills/sprint/SKILL.md` (Phase F, after verifier dispatch)

When the verifier returns `P1: EVIDENCE_PENDING`:

1. Re-run `pre-verifier-execute.sh` once (retry — the timeout may have been transient)
2. If EVIDENCE_PENDING persists after retry, **escalate to user** with structured summary:
   ```
   HALT_FOR_USER: Story <id> has EVIDENCE_PENDING verification.
   DDs pending:
   - dd-1: TIMEOUT after 60000ms (command: pytest tests/...)
   - dd-3: No Verify command
   Action needed: fix the timeout, add a Verify command, or approve closure without trace.
   ```
3. Do NOT attempt autonomous remediation of EVIDENCE_PENDING. It signals infrastructure problems (slow tests, missing fixtures, absent commands), not code defects.

---

## Phase 2: Intent Specification

**Delivers**: Every SC carries a structured proof-intent statement. Every DD carries a concrete Verify command resolved from that intent. The planning pipeline produces verification-ready artifacts, not just implementation-ready artifacts.

**Measurable outcome**: After Phase 2, count the percentage of stories entering sprint with at least one DD that has a `verify_commands` entry. Target: >=90%. Measure before/after: how many stories require remediation cycles at Step 18 verification (the pre-verifier trace should surface failures earlier, reducing remediation depth).

### 2.1 Verify-Intent on Success Criteria

**Files**: `plugins/dso/skills/shared/prompts/verifiable-sc-check.md`, `plugins/dso/skills/brainstorm/SKILL.md`

Every SC carries a `Verify-intent:` clause — a plain-language statement describing the observable outcome that constitutes proof. NOT a command. Does not reference test file paths.

**Format**:
```
- The reconciler processes inbound create mutations and creates local tickets
  Verify-intent: Run the reconciler against a fixture with inbound create mutations; confirm local tickets are created with correct field mapping
```

**Minimum structure requirement** (replaces sycophancy-prone self-check): Every Verify-intent must contain three elements:
1. **Subject** — what component or feature (e.g., "the reconciler")
2. **Action** — what operation to perform (e.g., "run against a fixture with inbound create mutations")
3. **Observable** — what measurable outcome to check (e.g., "confirm local tickets are created with correct field mapping")

Reject intents missing any element. "The feature works correctly" fails (no subject specificity, no action, no observable). "The login endpoint accepts valid credentials and returns a 200 with a session token" passes (subject: login endpoint, action: accepts valid credentials, observable: returns 200 with session token).

**Timing**: Verify-intents are drafted in a batch step AFTER all SCs are written, not during the Socratic dialogue.

**No classification at brainstorm time.** Deferred to Phase 3's mechanical classifier.

### 2.2 Verify Commands on Done Definitions

**File**: `plugins/dso/agents/story-decomposer.md`

The story-decomposer receives SCs with their Verify-intent as structured input:
```
sc-3:
  text: "The reconciler processes inbound create mutations and creates local tickets"
  verify_intent: "Run the reconciler against a fixture with inbound create mutations; confirm local tickets are created with correct field mapping"
```

Each DD includes a `Verify:` field — a concrete, executable command resolved from the parent SC's Verify-intent:

```
- The reconciler creates local tickets for inbound create mutations
  <- Satisfies: sc-3
  Verify: pytest tests/integration/test_inbound_create.py -k test_creates_ticket_with_correct_fields
```

**Required field** in the `done_definitions` array of the output schema.

**Negative-constraint list** (mechanical, not judgment): A Verify command is **invalid** if it matches any of: `grep`, `find`, `ls`, `wc`, `cat`, `head`, `stat`, `test -f`, `test -e`, `[ -f`, `[ -e`, `file `, `du `, `diff `.

**Step 7 extended**: Self-verification confirms every DD has a Verify command that passes the negative-constraint check.

### 2.3 Preplanning Integration

**File**: `plugins/dso/skills/preplanning/SKILL.md`

After the story-decomposer returns and the orchestrator writes story tickets (Phase H), call `set-verify-commands` with the DD verify commands from the decomposer's output:

```bash
.claude/scripts/dso ticket set-verify-commands <story-id> '<json-array>'
```

This bridges Phase 2 (planning produces Verify commands) and Phase 1 (execution infrastructure reads them).

---

## Phase 3: Semantic Validation

**Delivers**: Mechanical enforcement that Verify commands test what the intent describes. Closes the semantic fidelity gap acknowledged in Phase 1.

**Measurable outcome**: After Phase 3, audit a sample of 20 stories. For each, compare the Verify-intent text to the Verify command and the test content. Count how many commands actually test the stated intent vs. testing something adjacent. Target: >=85% semantic fidelity. Compare against a pre-Phase-3 baseline.

### 3.1 Deterministic SC Classifier

**New file**: `plugins/dso/scripts/classify-sc-type.sh`

Takes SC text as input, outputs `behavioral` or `structural`.

Decision procedure:
- SC text contains action verb from curated list (`exports`, `creates`, `returns`, `handles`, `processes`, `rejects`, `validates`, `sends`, `receives`, `transforms`, `converts`, `dispatches`, `routes`, `applies`, `executes`, `runs`, `produces`, `generates`, `invokes`, `fires`, `triggers`) -> **behavioral**
- SC text contains state/existence verb from curated list (`exists`, `is configured`, `has`, `contains`, `includes`, `is present`, `is defined`, `is documented`, `is absent`) -> **structural**
- Neither list matches -> **behavioral** (default — cost of unnecessary behavioral test < cost of missed stub)

Runs at brainstorm time post-SC-drafting. Classification stored as SC metadata. Downstream agents receive it as data.

### 3.2 Behavioral Coverage Cross-Check

**File**: `plugins/dso/skills/implementation-plan/SKILL.md`

After the task-decomposer returns, dispatch a **haiku-tier cross-check sub-agent**:

> "For each DD classified as behavioral, does the owning task's Verify command invoke the code under test, or does it only check file/string existence?"

The haiku sub-agent receives ONLY:
- The DD text and classification
- The task's Verify command
- The negative-constraint list

Returns pass/fail per DD. No other context. Structurally independent (different agent, different context, different model tier).

If any behavioral DD fails the cross-check, the implementation-plan orchestrator revises the task's Verify command before writing to the tracker.

### 3.3 Verify-Intent to Verify-Command Fidelity Check

Add a check to `pre-verifier-execute.sh` (or companion script):

Before executing Verify commands, compare each command against its parent SC's Verify-intent using a mechanical heuristic: extract the subject noun from the Verify-intent and confirm it appears in the Verify command or the test file it references. Mismatches produce `confidence: low` warning in trace, not a block.

---

## Phase 4: Remediation Efficiency

**Delivers**: Faster resolution of verification failures. Direct fixes for clear errors instead of multi-agent dispatch chains. Verify command evolution during implementation.

**Measurable outcome**: Compare remediation cycle count per story before and after Phase 4. Measure: average verifier dispatches per story and average sub-agent dispatches per remediation. Target: >=40% reduction in remediation dispatches for stories with clear-error failures.

### 4.1 Simplified Remediation for Clear Errors

**File**: `plugins/dso/skills/sprint/SKILL.md` (Phase F)

When `pre-verifier-execute.sh` produces a FAIL trace and the `stderr_tail` matches a **mechanically classified clear error**, the orchestrator MAY dispatch a single fix sub-agent BEFORE the planner.

**Clear error string-match list** (exact patterns, not LLM judgment):
- `NotImplementedError`
- `raise NotImplementedError`
- `# stub`
- `# TODO`
- `pass  # placeholder`
- `AttributeError: module .* has no attribute`
- `ImportError: cannot import name`

Any error not matching -> full planner path.

**Constraints**:
- Max 1 simplified remediation per story per sprint
- After fix, re-run `pre-verifier-execute.sh` for ALL DDs (regression detection)
- If re-run still shows ANY failure -> abandon simplified path, route through full planner
- Fix sub-agent does NOT receive the Verify command's expected output — it implements based on DD description and AC

### 4.2 Verify Command Mutability

**Files**: `plugins/dso/skills/sprint/SKILL.md`, story-decomposer.md

When implementation diverges from plan:
- Sub-agents update the Verify command via `set-verify-commands` as part of task completion
- Updated commands must pass the same negative-constraint validation as originals
- A `VERIFY_COMMAND_UPDATED` ticket comment records the change for audit trail

### 4.3 Soft Allowlist Quality Signal

**File**: `plugins/dso/scripts/pre-verifier-execute.sh`

Known test runners (`pytest`, `make test`, `npm test`, `bash` on `test-*.sh`, `curl`, `httpie`, `./validate.sh`) get `confidence: high`. Commands matching neither blocklist nor allowlist get `confidence: normal` with warning in trace manifest. Verifier applies extra scrutiny to `normal`-confidence traces.

---

## Phase Summary

| Phase | Delivers | Key Artifacts | Measurable Outcome | Depends On |
|-------|----------|--------------|-------------------|------------|
| **1** | Execution trace infrastructure | `execution-trace.md` contract, `pre-verifier-execute.sh`, `set-verify-commands` CLI, verifier Step 2.7, EVIDENCE_PENDING protocol | >=80% of past SOSC stories blocked on replay | Nothing |
| **2** | Intent specification pipeline | Verify-intent on SCs, Verify commands on DDs, preplanning integration | >=90% of stories enter sprint with Verify commands; reduced remediation depth | Phase 1 |
| **3** | Semantic validation | SC classifier, haiku cross-check, intent-to-command fidelity check | >=85% semantic fidelity between intent and command | Phase 2 |
| **4** | Remediation efficiency | Simplified remediation, command mutability, allowlist quality signal | >=40% reduction in remediation dispatches for clear-error stories | Phases 1-2 |

## Absorbed Ticket Closure Plan

This plan absorbs 2 epics and addresses 6 bugs. Each ticket is closed at the phase boundary where its scope is demonstrably resolved — not before. Closure requires the phase's measurable outcome to pass, confirming the ticket's concern is mechanically addressed.

### Absorbed Epics

These epics are superseded by this plan. They are closed with `--reason` referencing the implementing phase's verification evidence.

| Epic | Superseded By | Close After | Verification |
|------|--------------|-------------|--------------|
| `6111-fc7f` (Execution Trace Requirement for Plan and Fidelity Reviewers) | Phase 1 execution trace chain + Phase 3 cross-check | Phase 1 ships and measurable outcome passes (>=80% SOSC replay blocked) | Confirm: `pre-verifier-execute.sh` produces execution traces; verifier evaluates them as primary evidence. The execution trace requirement is end-to-end, superseding the narrower "plan and fidelity reviewer" scope. |
| `6068-cb2d` (Completion verifier: goal-backward verification with must_haves separation) | Phase 2 Verify-intent -> Verify-command chain | Phase 2 ships and measurable outcome passes (>=90% stories have Verify commands) | Confirm: Verify-intent on SCs flows through DDs to execution. The goal-backward chain (SC intent -> DD command -> execution trace -> verifier evaluation) supersedes the `must_haves` separation approach. |

**Closure commands** (execute at the specified phase boundary):

```bash
# After Phase 1 measurable outcome verified:
.claude/scripts/dso ticket transition 6111-fc7f open closed \
  --reason="Superseded: intent-fidelity-pipeline Phase 1 ships end-to-end execution traces (pre-verifier-execute.sh + verifier Step 2.7). Broader scope than plan/fidelity-reviewer-only traces. See docs/designs/intent-fidelity-pipeline.md."

# After Phase 2 measurable outcome verified:
.claude/scripts/dso ticket transition 6068-cb2d open closed \
  --reason="Superseded: intent-fidelity-pipeline Phase 2 ships Verify-intent -> Verify-command -> execution trace chain, which is goal-backward by construction. See docs/designs/intent-fidelity-pipeline.md."
```

### Addressed Bugs

These bugs describe symptoms of the SOSC failure pattern. Each is closed at the phase boundary where the root cause is mechanically resolved. Bug `41b5-cd7f` is already closed; the remaining 4 open bugs are closed with `--reason` citing the specific mechanical fix.

| Bug | Status | Root Cause Addressed By | Close After | Verification |
|-----|--------|------------------------|-------------|--------------|
| `1761-21ca` (shape-only DDs -> P1=PASS) | open | Phase 1: execution traces expose stub failures | Phase 1 measurable outcome passes | Replay a story from epic 4047 that had stub handlers. Confirm the Verify command produces trace FAIL (not PASS). |
| `cd24-6553` (epic closed, functionality not shipping) | open | Phase 2: Verify-intent requires observable outcome; negative-constraint list blocks file-existence checks | Phase 2 measurable outcome passes | Confirm: an SC like "workflow fires for downstream consumers" produces a Verify-intent with action + observable, and the DD Verify command is not a file-existence check. |
| `41b5-cd7f` (defer-over-implement bias) | closed | Phase 1 makes failures visible; Phase 4 adds direct-fix path | Already closed | No action needed. |
| `975e` (bypass mechanisms lack governance) | open | Phase 1: HARD-GATE on pre-verifier execution replaces bypassable behavioral gates | Phase 1 measurable outcome passes | Confirm: the HARD-GATE in sprint SKILL.md is non-bypassable (no skip rationalization path). |
| `bca0` (spec phases lack coverage assertion) | open | Phase 3: haiku cross-check validates behavioral coverage | Phase 3 measurable outcome passes | Confirm: a task with a grep-based Verify command for a behavioral DD is caught and revised by the haiku cross-check. |
| `f552` (orchestrator skipping mandatory steps) | open | Phase 1: pre-verifier execution is one atomic bash command behind a HARD-GATE | Phase 1 measurable outcome passes | Confirm: the orchestrator cannot skip the pre-verifier step without violating a HARD-GATE (structural impossibility, not behavioral guidance). |

**Closure commands** (execute at the specified phase boundary):

```bash
# After Phase 1 measurable outcome verified:
.claude/scripts/dso ticket transition 1761-21ca-cb74-44a6 open closed \
  --reason="Fixed: intent-fidelity-pipeline Phase 1 — pre-verifier execution traces expose stub failures. Verify commands on DDs produce trace FAIL for no-op handlers. See docs/designs/intent-fidelity-pipeline.md."

.claude/scripts/dso ticket transition 975e-d11c-444e-476d open closed \
  --reason="Fixed: intent-fidelity-pipeline Phase 1 — HARD-GATE on pre-verifier-execute.sh replaces bypassable behavioral gates with a single atomic script call. See docs/designs/intent-fidelity-pipeline.md."

.claude/scripts/dso ticket transition f552-8bde-6040-41ad open closed \
  --reason="Fixed: intent-fidelity-pipeline Phase 1 — pre-verifier execution is one bash command behind a HARD-GATE. No multi-step skippable sequence. See docs/designs/intent-fidelity-pipeline.md."

# After Phase 2 measurable outcome verified:
.claude/scripts/dso ticket transition cd24-6553-9d69-40fe open closed \
  --reason="Fixed: intent-fidelity-pipeline Phase 2 — Verify-intent requires subject+action+observable; negative-constraint list blocks file-existence Verify commands. See docs/designs/intent-fidelity-pipeline.md."

# After Phase 3 measurable outcome verified:
.claude/scripts/dso ticket transition bca0-8305-4722-4fd2 open closed \
  --reason="Fixed: intent-fidelity-pipeline Phase 3 — haiku cross-check validates behavioral coverage at task decomposition. See docs/designs/intent-fidelity-pipeline.md."
```

### Closure Sequencing Rule

No ticket is closed until:
1. The implementing phase's code changes are merged to main
2. The phase's measurable outcome has been evaluated and passes the stated target
3. The ticket-specific verification (rightmost column above) has been performed

Closing a ticket before its phase ships is itself a SOSC violation — closing on the plan rather than the implementation.

## What Does NOT Change

- Code review pipeline, test gate, lint hooks
- Ticket system mechanics (structured field follows existing `set-file-impact` pattern)
- Scrutiny pipeline structure
- Remediation loop protocol for complex failures (Phases 1-3 don't touch it)
- Backward compatibility: stories without Verify commands work exactly as today

## Review History

- **V1** (2026-05-26): Initial plan. Reviewed by opus plan reviewer + opus bot-psychologist. 14 findings.
- **V2** (2026-05-26): Incorporated all 14 findings. Re-reviewed by both. All findings resolved/mitigated. 7 new recommendations.
- **V3 / Final** (2026-05-26): Incorporated all 7 recommendations. Structured into 4 independently valuable phases with measurable outcomes.
