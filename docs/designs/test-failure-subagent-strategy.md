# Test-Failure Sub-Agent Strategy

Design document for reusing and adapting `/dso:debug-everything` debugging patterns
in `/dso:sprint` (post-batch) and `COMMIT-WORKFLOW.md` (commit-time) contexts.

Parent epic: `lockpick-doc-to-logic-vs5gl` — Add automated test-failure debugging
sub-agents to /dso:sprint, /dso:commit, and /dso:debug-everything.

> **SUPERSEDED (2026-04-24)** — `fix-task-tdd.md` and `fix-task-mechanical.md` were removed when `/dso:debug-everything` consolidated all bug-resolution dispatch to `/dso:fix-bug` (which encapsulates the TDD-vs-mechanical routing decision internally). The shared structured RESULT format and anti-patterns now live inside fix-bug. The shared test-failure prompt was relocated to `plugins/dso/skills/shared/prompts/test-failure-fix.md`. References to `skills/debug-everything/prompts/fix-task-*.md` below are historical.

---

## Section 1: Existing Pattern Catalog

The table below maps each existing `/dso:debug-everything` pattern to a reuse decision
for the commit-time and sprint-time sub-agent protocols.

| Pattern | Source File | Decision | Rationale |
|---------|------------|----------|-----------|
| TDD fix prompt (RED-GREEN-VALIDATE) | `skills/debug-everything/prompts/fix-task-tdd.md` | **Reuse** | The 7-step TDD flow (investigate, research, RED test, GREEN fix, validate, structured report) applies identically at commit-time and sprint-time. Inject context via existing `{placeholders}`. |
| Mechanical fix prompt | `skills/debug-everything/prompts/fix-task-mechanical.md` | **Reuse** | Simpler 5-step flow for non-behavioral fixes (imports, type annotations, config). Same placeholder injection. Works as-is for lint/type failures surfaced at commit time. |
| Diagnostic and clustering | `skills/debug-everything/prompts/diagnostic-and-cluster.md` | **Adapt** | Full 5-step diagnostic (format, ruff, mypy, unit, E2E) + clustering is overkill for commit-time (1-2 known failures). Sprint-time can reuse when post-batch validation fails across multiple categories. Adaptation: skip Steps 1/3 (summary + tickets) at commit-time; pass only the failing test output + stderr tail instead of running the full suite. |
| Structured RESULT format | `fix-task-tdd.md` lines 52-60, `fix-task-mechanical.md` lines 31-38 | **Reuse** | The `RESULT: PASS/FAIL/PARTIAL` + `ISSUE_ID` + `FILES_MODIFIED` + `ROOT_CAUSE` + `TESTS` + `CONCERNS` + `TASKS_CREATED` format is the standard sub-agent output contract. Reuse verbatim for all three contexts. |
| Anti-patterns table | `fix-task-tdd.md` lines 73-81, `fix-task-mechanical.md` lines 49-57 | **Reuse** | The 7 anti-patterns (no `# type: ignore`, no `@pytest.mark.skip`, no scope creep, etc.) are universal. Include in every fix sub-agent prompt regardless of context. |
| Two-file protocol (report on disk + compact summary) | `fix-task-tdd.md` lines 38-48, `diagnostic-and-cluster.md` lines 140-158 | **Adapt** | At commit-time, a single failure rarely produces enough output to justify disk I/O. Use the two-file protocol only when stderr exceeds 100 lines; otherwise inline the compact RESULT directly. Sprint-time should always use disk reports (batches produce verbose output). |
| Model escalation (sonnet default, opus on retry) | `SKILL.md` Phase 5 "Escalation" (line 468) | **Reuse** | The pattern "try sonnet first, retry with opus on failure" applies everywhere. Commit-time starts with sonnet; sprint-time starts with sonnet; both escalate to opus if the first attempt returns FAIL. |
| Subagent type selection table | `SKILL.md` Phase 5 lines 442-455 | **Adapt** | The 12-row table covers all `/dso:debug-everything` tiers. Commit-time and sprint-time need a subset: unit-test failures use `unit-testing:debugger`, type errors use `debugging-toolkit:debugger`, lint uses `code-simplifier:code-simplifier`. Complex multi-file bugs escalate to `error-debugging:error-detective` with opus. |
| Checkpoint protocol | `SKILL.md` Phase 5 Steps 1-6 | **Adapt** | Full checkpoint (verify, file-overlap, critic, validate, commit) is designed for multi-agent batches. Commit-time uses a single sub-agent, so skip file-overlap and critic review. Sprint-time already has Phase 5 Steps 3-10 for post-batch validation; the test-failure sub-agent slots into the existing failure-handling path (Step 9). |
| Validation gate skip map | `diagnostic-and-cluster.md` lines 35-41 | **New** | Commit-time needs a lightweight variant: the caller already knows which test command failed and has stderr. No skip map needed — pass the failure directly. Sprint-time can reuse the skip map when re-validating after a fix. |

---

## Section 2: Model Selection Guidance

### Commit-Time (COMMIT-WORKFLOW.md Step 1 failure path)

| Attempt | Model | Rationale |
|---------|-------|-----------|
| 1st attempt | `sonnet` | Fast turnaround. Most commit-time failures are 1-2 tests broken by the current changeset. Sonnet handles single-file and simple multi-file fixes reliably. |
| 2nd+ attempt (after sonnet FAIL) | `opus` | If sonnet could not fix it, the failure likely involves cross-module reasoning, subtle state bugs, or architectural misunderstanding. Opus has stronger multi-file correlation. |
| attempt > `review.max_resolution_attempts` (default: 5) | N/A — escalate to user | Failed attempts indicate a problem that requires human judgment (design question, external dependency, ambiguous requirement). |

### Sprint-Time (Sprint Phase 5 Step 4 / Phase 6 failure path)

| Scenario | Model | Rationale |
|----------|-------|-----------|
| Single sub-agent failure (1 task broke tests) | `sonnet` | Scoped to one task's changes. Same as commit-time first attempt. |
| Multi-file batch failure (2+ tasks, shared file overlap) | `sonnet` first, `opus` on retry | File overlap may cause interference patterns. Start fast, escalate if needed. |
| CI-only failure (passes locally, fails in CI) | `opus` | Environment-dependent failures require deeper reasoning about CI vs local differences (Docker, DB, env vars). |
| Post-E2E failure (Step 0.5b) | `sonnet` | E2E failures are typically DOM/route-level; sonnet handles template + route fixes well. Escalate to opus if the failure spans multiple blueprints. |

### /dso:debug-everything

No changes needed. The existing model selection table in `SKILL.md` Phase 5 (lines 442-455) already covers all tiers with appropriate model assignments. The escalation rule (line 468: "retry with opus before investigating manually") remains the fallback.

---

## Section 3: Dispatch Contract

### Input Specification

The orchestrator (commit workflow or sprint workflow) provides these fields to the
test-failure debugging sub-agent:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `test_command` | string | yes | The exact command that failed (e.g., `cd app && make test-unit-only`) |
| `exit_code` | int | yes | Process exit code from the test run |
| `stderr_tail` | string | yes | Last 50 lines of stderr/stdout from the failed command |
| `changed_files` | list[string] | yes | Files modified in the current batch/commit (from `git diff --name-only`) |
| `task_id` | string | yes | Ticket ID for checkpoint notes (`.claude/scripts/dso ticket comment`) |
| `context` | enum | yes | One of: `commit-time`, `sprint-post-batch`, `sprint-ci-failure` |
| `attempt` | int | yes | 1-based attempt counter (for model escalation) |
| `parent_task_id` | string | no | Parent epic/task ID for discovered-work tickets |
| `batch_task_ids` | list[string] | no | IDs of all tasks in the sprint batch (sprint-time only) |

### Output Specification (Structured RESULT Report)

The sub-agent returns this exact format (reused from `fix-task-tdd.md`):

```
RESULT: PASS | FAIL | PARTIAL
ISSUE_ID: <task_id>
FILES_MODIFIED: <path1>, <path2>, ... (or "none")
FILES_CREATED: <path1>, <path2>, ... (or "none")
ROOT_CAUSE: <1-2 sentence explanation>
TESTS: <N> passed, <M> failed
CONCERNS: <any remaining issues, or "none">
TASKS_CREATED: <ticket-id1>, <ticket-id2> (or "none")
```

When the two-file protocol is active (stderr > 100 lines or sprint-time context),
verbose output is written to:
```
$(get_artifacts_dir)/agent-result-${task_id}.md
```

The sub-agent returns only the structured RESULT block plus the file path.
The orchestrator reads the disk file for post-hoc inspection if needed.

### Dispatch Flow

```
Orchestrator detects test failure
  |
  v
Build input payload (test_command, exit_code, stderr_tail, changed_files, ...)
  |
  v
Select prompt template:
  - Behavioral failure (test assertion, runtime error) --> fix-task-tdd.md
  - Mechanical failure (import, type, lint) --> fix-task-mechanical.md
  |
  v
Select model:
  - attempt == 1 --> sonnet
  - attempt >= 2 --> opus
  - attempt > review.max_resolution_attempts (default: 5) --> escalate to user
  |
  v
Select subagent_type:
  - Unit test failure --> unit-testing:debugger
  - Type error --> debugging-toolkit:debugger
  - Lint violation --> code-simplifier:code-simplifier
  - Multi-file / complex --> error-debugging:error-detective
  |
  v
Launch Task sub-agent with filled prompt template
  |
  v
Parse RESULT line:
  - PASS --> continue workflow
  - FAIL --> increment attempt, retry with escalated model (or escalate to user)
  - PARTIAL --> log concerns, continue workflow with caveats
```

---

## Section 4: Scope Difference Analysis

### Commit-Time vs Sprint-Time vs Project-Health

| Dimension | Commit-Time | Sprint Post-Batch | Project-Health (/dso:debug-everything) |
|-----------|------------|-------------------|-----------------------------------|
| **Trigger** | `make test-unit-only` fails in COMMIT-WORKFLOW Step 1 | `validate-phase.sh post-batch` fails in Sprint Phase 5 Step 4 | Explicit `/dso:debug-everything` invocation |
| **Typical failure count** | 1-2 tests | 1-10 tests across batch | 0-50+ across all categories |
| **Failure source** | Current uncommitted changes | One or more sub-agents in the batch | Accumulated project-wide issues |
| **Triage step** | None (failure is self-evident) | Minimal — identify which sub-agent broke what | Full diagnostic scan + clustering + issue creation |
| **Sub-agent count** | 1 | 1 per failed task (up to 5 in parallel) | Batches of up to 5, across multiple tiers |
| **Diagnostic depth** | None — stderr from the failed command is sufficient | Post-batch validation output is sufficient | Full 5-category diagnostic + verbose error collection |
| **Model default** | sonnet | sonnet | Per-tier table (sonnet or opus) |
| **Escalation path** | sonnet -> opus -> user | sonnet -> opus -> user | Per Phase 5 table + Phase 6 critic review |
| **Checkpoint protocol** | None (single sub-agent, no batching) | Existing Sprint Phase 5 Steps 8-10 | Full Phase 6 (verify, overlap, critic, validate, commit) |
| **Two-file protocol** | Only if stderr > 100 lines | Always (batch output is verbose) | Always |
| **Max retries** | 2 (sonnet, then opus) | 2 per failed task | 5 full diagnostic cycles |
| **File overlap risk** | None (single agent) | Yes — batch overlap detection in Sprint Phase 5 Step 3 | Yes — Phase 6 Step 1a |
| **Critic review** | No | Via Sprint Phase 5 Step 7 (formal code review) | Phase 6 Step 1b (complex fixes only) |

### Key Gaps to Fill

1. **Commit-time dispatch point**: COMMIT-WORKFLOW.md Step 1 currently says "fix the code and restart from Step 1" with no sub-agent dispatch. The new protocol adds an automated fix attempt before requiring human intervention.

2. **Sprint failure attribution**: When post-batch validation fails, the orchestrator needs to attribute the failure to a specific sub-agent's changes. This requires `git diff --name-only` per sub-agent (already collected in Sprint Phase 5 Step 1a file-overlap check) cross-referenced with the failing test's imports/fixtures.

3. **Prompt template injection**: Both `fix-task-tdd.md` and `fix-task-mechanical.md` use `{placeholders}` for issue-specific details. The new dispatch contract adds `stderr_tail` and `changed_files` which are not in the current templates. Adaptation: inject these as a new `### Failure Context` section after `### Error Details`.

---

## Section 5: Protocol Testability

### How to Verify the Protocol Works in CI

The test-failure sub-agent protocol can be validated through three mechanisms:

#### 1. Hook Integration Tests (existing pattern)

The validation gate hook (`lockpick-workflow/hooks/`) already has tests that verify
hook behavior. The new dispatch protocol can be tested similarly:

- **State file test**: Verify that the dispatch writes the correct validation state
  file (`$(get_artifacts_dir)/status`) after a fix attempt.
- **RESULT parsing test**: Unit test that parses the structured RESULT format and
  extracts `RESULT`, `FILES_MODIFIED`, `ROOT_CAUSE` fields correctly.
- **Model escalation test**: Verify that attempt=1 selects sonnet, attempt=2 selects
  opus, attempt > `review.max_resolution_attempts` (default: 5) produces an escalation signal.

#### 2. Mock Sub-Agent Tests

Using `USE_MOCK_LLM=true`, the dispatch flow can be tested end-to-end:

- **Dispatch contract test**: Verify that the input payload contains all required
  fields (`test_command`, `exit_code`, `stderr_tail`, `changed_files`, `task_id`,
  `context`, `attempt`).
- **Template selection test**: Given a test failure type (assertion vs import error),
  verify the correct prompt template is selected (`fix-task-tdd.md` vs
  `fix-task-mechanical.md`).
- **Subagent type selection test**: Given a failure category, verify the correct
  `subagent_type` is selected from the selection table.

#### 3. CI Regression Guards

The existing CI pipeline runs `make test-unit-only` and `make test-e2e`. The
protocol's correctness is implicitly validated by:

- **Pre-commit hook**: Format and lint checks run before every commit. If the
  sub-agent's fix introduces formatting issues, the hook catches it.
- **Assertion density gate**: `check_assertion_density.py` ensures new test files
  maintain >= 1 assertion per test function. Sub-agent-created tests are held to
  the same standard.
- **Review gate**: The commit workflow's review gate (Step 5) reviews all changes
  including sub-agent fixes, catching anti-patterns.

#### 4. Observability

Each sub-agent fix attempt produces artifacts that can be audited:

- **Disk reports**: `$(get_artifacts_dir)/agent-result-${task_id}.md`
  contains the full validation output for post-hoc analysis.
- **Ticket notes**: `.claude/scripts/dso ticket comment` checkpoints record attempt number, model used,
  and outcome for each fix attempt.
- **Tool-use logging**: When enabled (`toggle-tool-logging.sh`), JSONL logs capture
  every tool call made by the sub-agent, enabling `analyze-tool-use.py` to detect
  anti-patterns (e.g., excessive file reads, serial tool calls).
