# Sub-Agent Boundaries

Rules for all sub-agents dispatched by orchestrators (`/dso:sprint`, `/dso:debug-everything`, ad-hoc Task calls). Orchestrators include this file in sub-agent prompts via reference or inline.

## Prohibited Actions

Sub-agents must NOT:
- `git commit`, `git push` — orchestrator handles all commits
- `.claude/scripts/dso ticket transition <id> open closed`, `.claude/scripts/dso ticket link`, `.claude/scripts/dso ticket transition <id> <current> <status>` — orchestrator manages issue lifecycle
- Invoke `/dso:commit`, `/dso:review`, or any slash-command — sub-agents are workers, not orchestrators
- Dispatch nested Task tool calls or code-review sub-agents
- **NEVER set `isolation: "worktree"` on this sub-agent.** Code-review and fix-resolution
  sub-agents must share the orchestrator's working directory. Worktree isolation gives the
  agent a separate branch where `reviewer-findings.json` and `write-reviewer-findings.sh`
  are not present, causing the review to fail.
- Modify files outside the scope of their assigned task
- Modify files outside `$(git rev-parse --show-toplevel)` (worktree boundary)
- Add `# type: ignore`, `# noqa`, `@pytest.mark.skip`, or any suppression comments
- Use any prohibited fix pattern — see [Prohibited Fix Patterns](#prohibited-fix-patterns) below
- Follow the "Task Completion Workflow" in CLAUDE.md — that applies to orchestrators only
- Use `--tags CLI_user` when creating bug tickets for autonomously discovered defects (anti-pattern scans, debug-everything discovery, or any defect found without explicit human request). The `CLI_user` tag is reserved for bugs that a human explicitly asked the agent to file during an interactive session.

**Resolution sub-agents** (launched via `review-fix-dispatch.md`) have an additional prohibition:
- MUST NOT dispatch a nested re-review Task tool call. Two levels of nesting
  (orchestrator → resolution → re-review) cause `[Tool result missing due to internal error]`.
  Resolution sub-agents apply fixes only and return `RESOLUTION_RESULT: FIXES_APPLIED`.
  The orchestrator dispatches re-review sub-agents after the resolution agent returns.
  See CLAUDE.md Never Do These rule 23.

## Prohibited Fix Patterns

These are cover-up anti-patterns — ways to make a test pass or silence an error without fixing the root cause. Sub-agents must never use them. Each pattern below is documented with a code example showing what NOT to do, a rationale for why it is harmful, and a concrete alternative.

---

### 1. Skipping or removing tests

**Description**: Deleting test files or test functions, applying `@pytest.mark.skip`, or removing test cases because they fail.

**What NOT to do:**
```python
# BAD: @pytest.mark.skip hides the failure — the bug still exists
@pytest.mark.skip(reason="flaky, fix later")
def test_data_pipeline_returns_correct_count():
    result = run_pipeline(sample_data)
    assert result.count == 42
```

**Rationale**: Skipping a test hides the root cause. The underlying bug remains in production code; the test suite now gives a false green signal. Future developers lose the safety net and may introduce regressions that go undetected.

**Do this instead**: Fix the implementation so the test passes, or if the test itself is wrong, update the assertion to reflect the correct expected behavior.
```python
# GOOD: Fix the implementation, not the test
def run_pipeline(data):
    # ... actual fix here ...
    return PipelineResult(count=len(data))
```

---

### 2. Loosening assertions

**Description**: Weakening assert conditions — broadening tolerance, replacing strict equality with `assertIn` or `assertTrue`, or removing boundary checks — so a failing test passes without fixing the underlying issue.

**What NOT to do:**
```python
# BAD: Original strict assertion
assert result == expected_value  # fails because result is wrong

# BAD: Loosened to pass despite wrong value
assert result is not None        # now passes but proves nothing
assert expected_value in str(result)  # hides a type or precision bug
```

**Rationale**: A loosened assertion masks the real failure. The test no longer verifies the behavior it was designed to protect. Bugs that the original assertion would have caught are now invisible.

**Do this instead**: Fix the implementation so the original strict assertion passes.
```python
# GOOD: Keep the strict assertion, fix the code
assert result == expected_value  # passes after the underlying bug is resolved
```

---

### 3. Broad exception handlers

**Description**: Adding bare `except:`, `except Exception:`, or overly broad `try/except` blocks that silently swallow errors rather than handling them specifically.

**What NOT to do:**
```python
# BAD: Swallows all errors — the caller never knows something went wrong
try:
    result = process_record(record)
except Exception:
    pass  # silently ignore every possible failure

# BAD: Bare except catches even KeyboardInterrupt and SystemExit
try:
    validate_schema(data)
except:
    pass
```

**Rationale**: Broad exception handlers hide failures from callers, from logs, and from monitoring. Errors that should propagate and be fixed are silently discarded. The system appears healthy when it is not.

**Do this instead**: Catch only the specific exception types you intend to handle, and always log or re-raise unexpected errors.
```python
# GOOD: Specific exception, intentional handling, unexpected errors propagate
try:
    result = process_record(record)
except RecordValidationError as exc:
    logger.warning("Skipping invalid record %s: %s", record.id, exc)
    return None
# All other exceptions propagate normally
```

---

### 4. Downgrading error severity

**Description**: Changing `ERROR` log calls to `WARNING`, removing error logging entirely, or converting hard failures (raised exceptions, assert statements) into soft warnings that allow execution to continue.

**What NOT to do:**
```python
# BAD: Was an assertion; changed to a warning so the test passes
# Original: assert len(results) > 0, "Expected at least one result"
logging.warning("No results found — continuing anyway")  # WARNING hides the problem

# BAD: Changed log level from ERROR to WARNING to silence an alert
log.warning("Database connection failed")  # was log.error(...)
```

**Rationale**: Downgrading severity reduces the signal-to-noise ratio of logs and alerts. Operators miss real failures. Tests that asserted an error was raised now pass because no error propagates — but the underlying condition is still wrong.

**Do this instead**: Keep or restore the original severity. Fix the root cause so the error condition no longer occurs.
```python
# GOOD: Preserve the error signal; fix the condition that causes it
assert len(results) > 0, "Expected at least one result"
# — or fix the code so results is never empty
```

---

### 5. Commenting out failing code

**Description**: Commenting out the lines of code that produce an error or a test failure instead of fixing the root cause.

**What NOT to do:**
```python
# BAD: Comment out the validation that reveals the bug
def process(data):
    # assert data is not None, "data must not be None"   # commented out to suppress failure
    # check_schema(data)                                  # commented out — was raising
    return transform(data)
```

**Rationale**: Commented-out code silences the symptom while leaving the root cause in place. The validation that was commented out was there for a reason; disabling it means the bug is now undetected at runtime, not just in tests.

**Do this instead**: Fix the root cause so validation passes, then keep the validation active.
```python
# GOOD: Fix the calling code so data is never None, then restore the check
def process(data):
    assert data is not None, "data must not be None"  # stays active
    check_schema(data)                                  # stays active
    return transform(data)
```

---

## Required Actions

Sub-agents MUST:
- Run `pwd` first to confirm working directory
- Write code + tests (TDD: tests before implementation when possible)
- Run `make format-check && make lint` from `app/`, then `.claude/scripts/dso validate.sh --ci` as final validation
- Write checkpoint notes: `.claude/scripts/dso ticket comment {id} "CHECKPOINT N/6: ..."`
- Use the DSO shim for scripts: `.claude/scripts/dso <script-name>`
- Follow existing code patterns and naming conventions
- Read code before modifying it

## Permitted Actions

Sub-agents MAY:
- `.claude/scripts/dso ticket create bug "..." --parent <parent-id>` for discovered bugs (use positional `bug` type when filing defects, not positional `task` type; do NOT add `--tags CLI_user` — these are autonomous discoveries, not user-requested bugs)
- `.claude/scripts/dso ticket comment <id> "..."` for checkpoint progress notes
- Read any file in the repo to understand context
- Write discovery files to `$ARTIFACTS_DIR/agent-discoveries/<task-id>.json` (resolve via: `source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh && get_artifacts_dir`) (atomic: write `.tmp`, then `mv`) when encountering bugs, missing dependencies, API changes, or convention violations during execution. Schema: `{"task_id": "<id>", "type": "<bug|dependency|api_change|convention>", "summary": "<one-line>", "affected_files": ["<path>", ...]}`. Discovery writing is non-fatal — failures must not block task completion.
- Read `${TMPDIR:-/tmp}/dso-blackboard-<worktree-name>/blackboard.json` for file ownership awareness (written by orchestrator before dispatch). Respect ownership boundaries: only modify files listed under your ownership; report concerns for files owned by other agents. If a required modification falls outside your listed `files_owned`, add a checkpoint note explaining the deviation before proceeding.

## Worktree Sessions

When running in a worktree:
- Only modify files under `$(git rev-parse --show-toplevel)`
- `.claude/` and `scripts/` always live at `$(git rev-parse --show-toplevel)` — never relative to CWD
- Memory files are at `~/.claude/projects/<encoded-worktree-path>/memory/`

### Worktree Isolation (`isolation: worktree`)

When a sub-agent is launched with `isolation: worktree`, the framework creates a dedicated per-agent worktree. Sub-agents in this mode:

**Must NOT commit in worktrees (implement only)**:
- Sub-agents with `isolation: worktree` are workers — they implement code changes only
- All git commits are prohibited; the orchestrator handles all commits after reviewing the work
- This ensures review/test state is validated before any commit enters the branch history

**Allowlist replaces categorical block**:
- The blanket prohibition on `isolation: worktree` for code-review and fix-resolution sub-agents (see Prohibited Actions above) is replaced by a per-agent allowlist
- Agents on the authorized worktree isolation allowlist may receive `isolation: worktree` when the orchestrator explicitly configures it
- Code-review sub-agents (`dso:code-reviewer-*`) and fix-resolution sub-agents remain categorically blocked from worktree isolation — they require `reviewer-findings.json` and `write-reviewer-findings.sh` to be present in the shared orchestrator directory

**Artifact isolation semantics**:
- `ARTIFACTS_DIR` resolves per-worktree using a hash of `REPO_ROOT`
- Compute: `source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh && get_artifacts_dir`
- Each per-agent worktree gets its own artifact namespace; artifacts do NOT bleed across worktrees
- Discovery files written to `$ARTIFACTS_DIR/agent-discoveries/<task-id>.json` are scoped to the worktree

**Review/test state flows through worktree ARTIFACTS_DIR**:
- Test status records written by `record-test-status.sh` use the worktree-scoped `ARTIFACTS_DIR`
- Review outcomes written by `record-review.sh` are also scoped per-worktree via `ARTIFACTS_DIR`
- The orchestrator collects state from each sub-agent's worktree `ARTIFACTS_DIR` after the agent returns; state is never shared directly between concurrent per-agent worktrees

## Model Selection

| Model | Use for |
|-------|---------|
| `haiku` | Structured I/O, validation-only, classification |
| `sonnet` | Code generation, code review, standard implementation |
| `opus` | Architecture decisions, high-blast-radius changes, safeguard files |

Escalation on failure: haiku -> sonnet -> opus.

## Dispatch Failure Recovery

When a Task tool call returns an infrastructure-level dispatch failure (no `STATUS:` or `FILES_MODIFIED:` lines, error references agent type or internal errors), the orchestrator retries before giving up:

1. **Retry with general-purpose**: Same model, `subagent_type="general-purpose"`
2. **Escalate model**: If retry fails, upgrade model (sonnet → opus) with `subagent_type="general-purpose"`
3. **Mark failed**: If all retries fail, revert task to open

This is distinct from task-level failures (where the agent ran but produced incorrect work). Task-level failures follow normal Step 9 handling (revert to open, record failure reason).

Dispatch failure retries are sequential and do not count toward batch size limits. Both `/dso:sprint` (Phase 5 Step 0) and `/dso:debug-everything` (Phase H Step 1) implement this protocol.

## Checkpoint Protocol

Sub-agents write progress via `.claude/scripts/dso ticket comment {id} "CHECKPOINT N/6: ..."`:

| Checkpoint | Meaning |
|-----------|---------|
| 1/6 | Task context loaded |
| 2/6 | Code patterns understood |
| 3/6 | Tests written (or "none required") |
| 4/6 | Implementation complete |
| 5/6 | Validation passed (or "failed — summary") |
| 6/6 | Done |

## Report Format

Sub-agent final message must include:
```
STATUS: pass|fail
FILES_MODIFIED: path1, path2
FILES_CREATED: path3 or none
TESTS: N passed, N failed
AC_RESULTS: criterion1: pass/fail (if acceptance criteria present)
TASKS_CREATED: ticket-id1, ticket-id2 (or "none", or "error: reason")
```

## Recovery

Orchestrators recover interrupted sub-agents via checkpoint notes:
- CHECKPOINT 5/6 or 6/6 → fast-close (spot-check files, close task)
- CHECKPOINT 3/6 or 4/6 → re-dispatch with resume context
- CHECKPOINT 1/6 or 2/6 or missing → revert to open, full re-execution
