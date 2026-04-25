# Test-Failure Dispatch Protocol

This document defines when and how orchestrators delegate test failures to sub-agents,
including model selection, input/output contracts, and integration points for each workflow.

Reference: `docs/designs/test-failure-subagent-strategy.md` for the full strategy analysis.

---

## When to Delegate vs Fix Inline

| Condition | Action |
|-----------|--------|
| Single obvious failure (typo, missing import, one-line fix) | Fix inline -- no sub-agent needed |
| >1 failing test | **Delegate** to sub-agent |
| Failure persists after 1 inline fix attempt | **Delegate** to sub-agent |
| CI-only failure (passes locally) | **Delegate** with `context=sprint-ci-failure` |
| Multi-file failure spanning 3+ modules | **Delegate** with opus model |

**Threshold rule**: If the orchestrator cannot fix it in one inline attempt, delegate.
Do not spend orchestrator context on debugging -- that is what the sub-agent is for.

---

## Model Selection Table

### By Attempt Number (Default Escalation)

| Attempt | Model | Rationale |
|---------|-------|-----------|
| 1 | `sonnet` | Fast turnaround. Most failures are 1-2 tests broken by the current changeset. |
| 2+ | `opus` | If sonnet could not fix it, the failure likely involves cross-module reasoning or subtle state bugs. |
| > `review.max_resolution_attempts` (default: 5) | **Escalate to user** | Failed attempts indicate a problem requiring human judgment (design question, external dependency, ambiguous requirement). |

### By Scenario (Sprint-Time Overrides)

| Scenario | Model | Rationale |
|----------|-------|-----------|
| Single sub-agent failure (1 task broke tests) | `sonnet` | Scoped to one task's changes. |
| Multi-file batch failure (2+ tasks, shared file overlap) | `sonnet` first, `opus` on retry | File overlap may cause interference patterns. |
| CI-only failure (passes locally, fails in CI) | `opus` | Environment-dependent failures require deeper reasoning. |
| Post-E2E failure | `sonnet` | E2E failures are typically DOM/route-level. Escalate to opus if failure spans multiple blueprints. |

---

## Input Contract

The orchestrator provides these fields when dispatching a test-failure sub-agent:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `test_command` | string | yes | The exact command that failed (e.g., `cd app && make test-unit-only`) |
| `exit_code` | int | yes | Process exit code from the test run |
| `stderr_tail` | string | yes | Last 50 lines of stderr/stdout from the failed command |
| `changed_files` | list[string] | yes | Files modified in the current batch/commit (from `git diff --name-only`) |
| `task_id` | string | yes | Ticket ID for checkpoint notes (`.claude/scripts/dso ticket comment`) |
| `context` | enum | yes | One of: `commit-time`, `sprint-post-batch`, `sprint-ci-failure` |
| `attempt` | int | yes | 1-based attempt counter (drives model escalation) |
| `parent_task_id` | string | no | Parent epic/task ID for discovered-work tickets |
| `batch_task_ids` | list[string] | no | IDs of all tasks in the sprint batch (sprint-time only) |

---

## Output Contract

The sub-agent returns this exact structured format:

```
RESULT: PASS | FAIL | PARTIAL
ISSUE_ID: <task_id>
FILES_MODIFIED: <path1>, <path2>, ... (or "none")
FILES_CREATED: <path1>, <path2>, ... (or "none")
ROOT_CAUSE: <1-2 sentence explanation>
TESTS: <N> passed, <M> failed
CONCERNS: <any remaining issues, or "none">
TASKS_CREATED: <ticket-id1>, <ticket-id2> (or "none", or "error: <reason>")
```

When the two-file protocol is active (stderr > 100 lines or sprint-time context),
verbose output is written to:
```
$(get_artifacts_dir)/agent-result-${task_id}.md
```

### Parsing the Output

The orchestrator extracts the `RESULT` line to decide the next action:
- `PASS` -- continue workflow normally
- `FAIL` -- increment attempt counter, retry with escalated model (or escalate to user if attempt exceeds `review.max_resolution_attempts` (default: 5))
- `PARTIAL` -- log concerns, continue workflow with caveats

---

## Sub-Agent Type Selection

| Failure Category | Sub-Agent Type | Prompt Path |
|-----------------|----------------|-------------|
| Unit test failure (assertion, runtime error) | Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`) | TDD path in `test-failure-fix.md` |
| Type error (mypy) | Resolve via `discover-agents.sh` routing category `mechanical_fix` (see `agent-routing.conf`) | Mechanical path in `test-failure-fix.md` |
| Lint violation (ruff) | Resolve via `discover-agents.sh` routing category `code_simplify` (see `agent-routing.conf`) | Mechanical path in `test-failure-fix.md` |
| Multi-file / complex (cross-module, CI-only) | `error-debugging:error-detective` | TDD path in `test-failure-fix.md` |

## Prompt Template Selection

| Failure Signal | Template Path | Path Within Template |
|---------------|---------------|---------------------|
| Assertion failure (`AssertionError`, wrong value) | `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/test-failure-fix.md` | TDD path (RED -> GREEN) |
| Runtime error (`KeyError`, `TypeError`, `AttributeError`) | `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/test-failure-fix.md` | TDD path (RED -> GREEN) |
| Import error (`ModuleNotFoundError`, `ImportError`) | `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/test-failure-fix.md` | Mechanical path |
| Type annotation error (mypy) | `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/test-failure-fix.md` | Mechanical path |
| Lint violation (ruff) | `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/test-failure-fix.md` | Mechanical path |
| Config/env issue | `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/test-failure-fix.md` | Mechanical path |

---

## Integration Hooks

### COMMIT-WORKFLOW.md

**Step 1 (Validation failure)**:
When `make test-unit-only` or `make lint` fails during commit validation:
1. Capture `test_command`, `exit_code`, and last 50 lines of stderr
2. Collect `changed_files` from `git diff --name-only`
3. Set `context=commit-time`, `attempt=1`
4. Dispatch sub-agent per this protocol
5. If `RESULT: PASS` -- re-run validation and continue to Step 2
6. If `RESULT: FAIL` -- increment attempt, retry with opus (attempt=2)
7. If attempt exceeds `review.max_resolution_attempts` (default: 5) -- escalate to user

**Step 1.5 (Post-fix re-validation)**:
After a successful sub-agent fix, re-run the full validation suite before proceeding
to the commit step. Do not assume the fix is clean -- validate.

### /dso:sprint (Sprint Workflow)

**Phase 5 Step 4 (Post-batch validation failure)**:
When `validate-phase.sh post-batch` reports test failures:
1. Attribute failure to specific sub-agent(s) using `git diff --name-only` per task
2. For each failing task, build the input payload with `context=sprint-post-batch`
3. Dispatch up to 5 fix sub-agents in parallel (one per failing task)
4. Collect RESULT reports; re-validate after all agents complete
5. If any remain FAIL after attempt exceeds `review.max_resolution_attempts` (default: 5), escalate to user

**Phase 6 Step 0.5b (Post-E2E failure)**:
When E2E tests fail after all batches complete:
1. Capture E2E test output and identify failing test(s)
2. Set `context=sprint-ci-failure` (E2E failures behave like CI-only issues)
3. Dispatch sub-agent with the E2E test command and stderr
4. Follow standard escalation (sonnet -> opus -> user)

### /dso:debug-everything

No changes needed. The existing `/dso:debug-everything` workflow already uses
`fix-task-tdd.md` and `fix-task-mechanical.md` directly. The test-failure
dispatch protocol is a layer above these prompts, used by `/dso:sprint` and
`COMMIT-WORKFLOW.md` to automate what `/dso:debug-everything` does manually.

---

## Failure Handling

| Failure Mode | Action |
|-------------|--------|
| Sub-agent timeout (no response within tool timeout) | Fall back to inline fix attempt by orchestrator |
| Malformed output (missing RESULT line) | Retry once with same model; if still malformed, fall back to inline fix |
| Sub-agent returns `FAIL` | Increment attempt, escalate model per Model Selection Table |
| Sub-agent returns `PARTIAL` | Log concerns in ticket notes, continue workflow |
| Sub-agent creates new tickets | Orchestrator validates tickets exist, includes in batch report |

---

## Dispatch Flow (Summary)

```
Orchestrator detects test failure
  |
  v
Can fix inline? (single obvious fix, first attempt)
  |-- Yes --> Fix inline, re-validate
  |-- No  --> Continue to dispatch
  |
  v
Build input payload (test_command, exit_code, stderr_tail, changed_files, ...)
  |
  v
Select prompt template:
  - Behavioral failure (assertion, runtime error) --> test-failure-fix.md (TDD path)
  - Mechanical failure (import, type, lint) --> test-failure-fix.md (Mechanical path)
  |
  v
Select model:
  - attempt == 1 --> sonnet
  - attempt == 2 --> opus
  - attempt exceeds `review.max_resolution_attempts` (default: 5) --> escalate to user
  |
  v
Select subagent_type:
  - Unit test failure --> resolve via discover-agents.sh routing category test_fix_unit
  - Type error --> resolve via discover-agents.sh routing category mechanical_fix
  - Lint violation --> resolve via discover-agents.sh routing category code_simplify
  - Multi-file / complex --> error-debugging:error-detective
  |
  v
Launch Task sub-agent with filled prompt template
  |
  v
Parse RESULT line:
  - PASS --> re-validate, continue workflow
  - FAIL --> increment attempt, retry with escalated model (or escalate to user)
  - PARTIAL --> log concerns, continue workflow with caveats
```

---

## Protocol Verification

This protocol can be verified through three mechanisms, as described in the
strategy document (`docs/designs/test-failure-subagent-strategy.md`, Section 5):

### 1. Hook Integration Tests
- **State file test**: Verify dispatch writes correct validation state to `$(get_artifacts_dir)/status`
- **RESULT parsing test**: Unit test that parses the structured RESULT format and extracts all fields
- **Model escalation test**: Verify attempt=1 selects sonnet, attempt=2 selects opus, attempt > `review.max_resolution_attempts` (default: 5) produces escalation signal

### 2. Mock Sub-Agent Tests
- **Dispatch contract test**: Verify input payload contains all required fields
- **Template selection test**: Given failure type, verify correct prompt template path is selected
- **Sub-agent type selection test**: Given failure category, verify correct `subagent_type`

### 3. CI Regression Guards
- Pre-commit hooks catch formatting issues in sub-agent fixes
- Assertion density gate ensures sub-agent-created tests maintain >= 1 assertion per function
- Review gate reviews all changes including sub-agent fixes

### 4. Observability
- Disk reports at `$(get_artifacts_dir)/agent-result-${task_id}.md`
- Ticket checkpoint notes record attempt number, model used, and outcome
- Tool-use JSONL logging (when enabled) captures all sub-agent tool calls for anti-pattern analysis
