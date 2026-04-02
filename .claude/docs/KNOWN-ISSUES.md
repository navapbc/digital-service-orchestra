# Known Issues and Incident Log

> **Search tips**: Use Ctrl+F with keywords like "exit 144", "worktree", "timeout", "hook", "cascade", "venv", "review gate", "nesting", "PLUGIN_ROOT", "merge conflict"

> **When to read this file**: Reference when debugging unexpected behavior or understanding why certain rules exist in CLAUDE.md.

> **Workflow**: ALWAYS search this file before debugging. After solving a new issue, add it here. If 3+ similar incidents accumulate, propose a rule in CLAUDE.md.

## Index by Category

| Category | Issue Count | Most Recent |
|----------|-------------|-------------|
| [Timeouts/Performance](#timeouts-and-performance) | 3 | 2026-03 |
| [Paths/Directories](#paths-and-directories) | 2 | 2026-03 |
| [Sub-Agents/Orchestration](#sub-agents-and-orchestration) | 3 | 2026-03 |
| [Hooks/Gates](#hooks-and-gates) | 1 | 2026-03 |
| [Tickets/Version Control](#tickets-and-version-control) | 1 | 2026-03 |

## Quick Reference by Incident ID

| ID | Title | Category | Keywords |
|----|-------|----------|----------|
| INC-001 | Tool Timeout Ceiling (exit 144) | Timeouts/Performance | exit 144, SIGURG, timeout, test-batched |
| INC-002 | Path Confusion in Worktrees | Paths/Directories | worktree path, relative, CWD, git rev-parse, show-toplevel |
| INC-003 | Broad Test Commands Killed by Timeout | Timeouts/Performance | test timeout, make test-unit-only, make test-e2e, test-batched |
| INC-004 | Worktree venv / Command-Not-Found | Paths/Directories | venv, command-not-found, poetry env, worktree |
| INC-005 | Review Gate Blocks Sub-Agent Commits | Sub-Agents/Orchestration | review gate, sub-agent commit, pre-commit hook |
| INC-006 | Sub-Agent Nesting Causes Tool-Result Errors | Sub-Agents/Orchestration | nesting, nested Task, tool result missing |
| INC-007 | Hook Failure Cascades | Hooks/Gates | hook cascade, hook-error-log, cascade circuit breaker |
| INC-008 | Ticket Index Merge Conflicts | Tickets/Version Control | ticket merge conflict, worktree-sync, orphan branch |
| INC-009 | CLAUDE_PLUGIN_ROOT Unbound in Parallel Execution | Sub-Agents/Orchestration | CLAUDE_PLUGIN_ROOT, unbound variable, sub-agent, env var |
| INC-010 | Cascading Failure Runaway | Timeouts/Performance | cascading failure, runaway, fix-cascade-recovery |

---

## Timeouts and Performance

### INC-001: Tool Timeout Ceiling (exit 144)
- **Date**: 2026-03
- **Keywords**: exit 144, SIGURG, timeout, tool-call ceiling, validate.sh, test-batched, killed, 73s
- **Symptom**: Long-running commands are killed mid-run with exit code 144 (SIGURG). Output is truncated; test results appear as spurious failures even when tests would pass.
- **Root cause**: Claude Code tool calls have a hard ceiling of approximately 73 seconds. Any Bash tool call exceeding this ceiling receives SIGURG and is killed.
- **Detection**: Command exits with code 144. Output ends abruptly mid-test.
- **Fix**: Set `timeout: 600000` on all Bash tool calls expected to exceed 30s. Use `plugins/dso/scripts/test-batched.sh --timeout=50 --runner=bash --test-dir=tests/scripts` for test suites.
- **Rule added**: Always set `timeout: 600000` on Bash calls expected to exceed 30s AND on all Bash calls during commit/review workflows.

---

### INC-003: Broad Test Commands Killed by Timeout
- **Date**: 2026-03
- **Keywords**: test timeout, make test-unit-only, make test-e2e, test-batched, killed, exit 144, broad test commands
- **Symptom**: Running `make test-unit-only` or `make test-e2e` results in the command being killed (exit 144) before completing, producing spurious test failures.
- **Root cause**: These broad test commands exceed the ~73s tool timeout ceiling and are killed mid-run by SIGURG.
- **Detection**: Exit code 144 from `make test-unit-only` or `make test-e2e`. Output stops mid-test-file.
- **Fix**: Use `plugins/dso/scripts/test-batched.sh --timeout=50 --runner=bash --test-dir=tests/scripts` for incremental execution. For final validation, use `plugins/dso/scripts/validate.sh --ci`.
- **Rule added**: Never run `make test-unit-only` or `make test-e2e` as a full-suite validation command.

---

### INC-010: Cascading Failure Runaway
- **Date**: 2026-03
- **Keywords**: cascading failure, runaway, fix-cascade-recovery, 5 failures, cascade, spiral
- **Symptom**: An attempted fix causes a new failure, which triggers another fix attempt. The session spirals with increasing error counts and no convergence.
- **Root cause**: Fixing symptoms rather than root causes. Each fix introduces a new regression, triggering another fix loop iteration.
- **Detection**: More than 5 consecutive fix-validate cycles, each ending in failure. FAIL count grows across cycles with no converging trajectory.
- **Fix**: Stop immediately after 5 cascading failures. Run `/dso:fix-cascade-recovery` to assess damage and decide whether to revert. Do NOT continue attempting fixes.
- **Rule added**: Never continue fixing after 5 cascading failures.

---

## Paths and Directories

### INC-002: Path Confusion in Worktrees
- **Date**: 2026-03
- **Keywords**: worktree path, relative path, CWD, git rev-parse, show-toplevel, worktree, absolute path
- **Symptom**: Scripts fail with "file not found" errors when run from a git worktree. Relative paths resolve to wrong locations.
- **Root cause**: In a git worktree, CWD differs from the repository root. Relative paths resolve relative to the worktree working directory, not the project root.
- **Detection**: `pwd` returns a worktree path. File-not-found errors on paths that appear correct.
- **Fix**: Always use `REPO_ROOT=$(git rev-parse --show-toplevel)` and construct paths as `$REPO_ROOT/relative/path`. Never use bare relative paths in scripts run from worktrees.
- **Rule added**: Use `REPO_ROOT=$(git rev-parse --show-toplevel)` for all repo-root-relative paths in worktree sessions.

---

### INC-004: Worktree venv / Command-Not-Found
- **Date**: 2026-03
- **Keywords**: venv, command-not-found, poetry, poetry env, worktree, .venv, python
- **Symptom**: `poetry run pytest` or project CLI commands fail with "command not found" or import errors in a worktree session. The `.venv` virtual environment is missing.
- **Root cause**: `.venv` is not shared across git worktrees. Each worktree needs its own virtual environment created locally.
- **Detection**: `ls app/.venv` returns "No such file or directory". `poetry run python` fails with ModuleNotFoundError.
- **Fix**: `cd app && rm -rf .venv && poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13 && poetry install`
- **Rule added**: Added to CLAUDE.md Common Fixes table.

---

## Sub-Agents and Orchestration

### INC-005: Review Gate Blocks Sub-Agent Commits
- **Date**: 2026-03
- **Keywords**: review gate, sub-agent commit, pre-commit hook, review state, git commit
- **Symptom**: A sub-agent attempts `git commit` and is blocked by the pre-commit review gate with an error about missing review state or diff hash mismatch.
- **Root cause**: The review gate requires a reviewer-findings.json with a valid diff hash. Sub-agents cannot produce this state; only the full `/dso:review` orchestration pipeline can.
- **Detection**: Pre-commit hook exits with "review gate: no valid review found". Sub-agent reports commit failure.
- **Fix**: Sub-agents must NOT commit. They report STATUS output at the end of their task. The orchestrator handles all commits via `/dso:commit` after collecting sub-agent results.
- **Rule added**: Never run `git commit` from a sub-agent. Use `/dso:commit` only from the orchestrator.

---

### INC-006: Sub-Agent Nesting Causes Tool-Result Errors
- **Date**: 2026-03
- **Keywords**: nesting, nested Task, tool result missing, internal error, Task tool
- **Symptom**: A sub-agent dispatches a nested Task call. The inner task returns [Tool result missing due to internal error].
- **Root cause**: The Claude Code Agent tool does not support nesting. A Task call from within a Task sub-agent is not permitted; the runtime drops the result.
- **Detection**: Sub-agent output contains [Tool result missing due to internal error].
- **Fix**: Never dispatch nested Task calls from within a sub-agent. The orchestrator (main session) is solely responsible for dispatching all sub-agents.
- **Rule added**: Resolution sub-agents must NOT dispatch nested Task calls for re-review.

---

### INC-009: CLAUDE_PLUGIN_ROOT Unbound in Parallel Execution
- **Date**: 2026-03
- **Keywords**: CLAUDE_PLUGIN_ROOT, unbound variable, sub-agent, env var, parallel execution
- **Symptom**: Plugin scripts fail with CLAUDE_PLUGIN_ROOT: unbound variable when executed from sub-agents or parallel Task batches.
- **Root cause**: Sub-agents do not inherit the parent session environment variables. CLAUDE_PLUGIN_ROOT set in the main session is not propagated to sub-agent shells.
- **Detection**: Script output includes `CLAUDE_PLUGIN_ROOT: unbound variable`. Scripts cannot locate plugin files in sub-agents.
- **Fix**: Use the fallback pattern `${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}` in all plugin scripts, where `REPO_ROOT=$(git rev-parse --show-toplevel)`.
- **Rule added**: Plugin scripts must use the `${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}` fallback pattern.

---

## Hooks and Gates

### INC-007: Hook Failure Cascades
- **Date**: 2026-03
- **Keywords**: hook cascade, pre-bash.sh, hook-error-log, cascade circuit breaker, dispatcher
- **Symptom**: One hook error causes cascading failures across multiple hook dispatchers. Subsequent tool calls fail with hook errors unrelated to the original issue.
- **Root cause**: The consolidated hook dispatcher runs multiple hooks in sequence. If one hook fails, it can affect subsequent hooks. The cascade circuit breaker trips if the error threshold is exceeded.
- **Detection**: Check ~/.claude/hook-error-log.jsonl for repeated hook errors. Multiple unrelated commands fail with hook errors.
- **Fix**: Check ~/.claude/hook-error-log.jsonl to identify the root hook. Fix the root hook error. Run /dso:fix-cascade-recovery if more than 5 cascading failures have occurred.
- **Rule added**: Never continue fixing after 5 cascading failures.

---

## Tickets and Version Control

### INC-008: Ticket Index Merge Conflicts
- **Date**: 2026-03
- **Keywords**: ticket merge conflict, worktree-sync, orphan branch, event log, JSON conflict
- **Symptom**: Merging a worktree branch to main produces merge conflicts in ticket tracker files. The ticket event log has conflicting entries from main and worktree branches.
- **Root cause**: The ticket system uses an orphan git branch (tickets) mounted at the ticket tracker directory. When both worktree and main have progressed, ticket event files can diverge. Naive git merge does not know how to reconcile JSON event log files.
- **Detection**: git merge main produces conflict markers inside ticket tracker JSON files. git status shows both modified for tracker files.
- **Fix**: Use `merge-to-main.sh` which handles ticket branch syncing inline via `_phase_sync`. Never use raw `git merge main` in worktrees.
- **Rule added**: Always use `merge-to-main.sh` (which includes inline ticket sync) for worktree merge operations.

# Known Issues and Incident Log

> **Search Tips**: Use Ctrl+F with keywords like "CI", "path", "timeout", "hook", "config", "deploy", "test", "flaky"

> **When to read this file**: Reference when debugging unexpected behavior or understanding why certain rules exist in your project configuration.

> **Workflow**: ALWAYS search this file before debugging (`grep -i "keyword" .claude/docs/KNOWN-ISSUES.md`). After solving a new issue, add it here using the incident format below. If 3+ similar incidents accumulate, propose a rule in your project configuration.

> **Archive**: Resolved/historical incidents can be moved to a `KNOWN-ISSUES-ARCHIVE.md` file. Search there if a pattern recurs.

## Index by Category

<!-- Update this table as you add new incidents. Keep counts and dates current. -->

| Category | Issue Count | Most Recent |
|----------|-------------|-------------|
| [CI/Deployment](#ci-and-deployment) | 1 | YYYY-MM |
| [Paths/Directories](#paths-and-directories) | 1 | YYYY-MM |
| [Testing/Flakiness](#testing-and-flakiness) | 1 | YYYY-MM |

## Quick Reference by Incident ID

<!-- Add a row for each incident. This index enables fast lookup by ID or keyword search. -->

| ID | Title | Category | Keywords |
|----|-------|----------|----------|
| INC-001 | Example: CI Lock File Out of Sync | CI/Deployment | CI, lock, sync, dependency |
| INC-002 | Example: Relative Path Breaks in Subprocesses | Paths/Directories | path, relative, absolute, subprocess |
| INC-003 | Example: Flaky Integration Test | Testing/Flakiness | flaky, timeout, retry, test |

---

## CI and Deployment

### INC-001: Example: CI Lock File Out of Sync
- **Date**: YYYY-MM
- **Keywords**: CI, lock, sync, dependency, manifest
- **Symptom**: CI fails with dependency mismatch while local builds succeed
- **Root cause**: Dependency manifest was updated without regenerating the lock file. Local tooling auto-resolves, but CI uses strict validation.
- **Detection**: Run your dependency check command (e.g., `npm ci`, `poetry check --lock`, `bundle check`)
- **Fix**: Regenerate the lock file after modifying the dependency manifest
- **Rule added**: Always regenerate the lock file after modifying dependencies

---

## Paths and Directories

### INC-002: Example: Relative Path Breaks in Subprocesses
- **Date**: YYYY-MM
- **Keywords**: path, relative, absolute, subprocess, working directory
- **Symptom**: Script fails with "file not found" when invoked from a different directory
- **Root cause**: Script used a relative path that only worked from the project root
- **Detection**: Run the script from a subdirectory and observe if paths resolve correctly
- **Fix**: Convert to absolute paths using the project root (e.g., `$(git rev-parse --show-toplevel)/path/to/file`)
- **Rule added**: Always use absolute paths in scripts and subprocess calls

---

## Testing and Flakiness

### INC-003: Example: Flaky Integration Test
- **Date**: YYYY-MM
- **Keywords**: flaky, timeout, retry, test, integration, intermittent
- **Symptom**: Test passes locally but fails intermittently in CI
- **Root cause**: Test relied on timing assumptions that do not hold under CI load
- **Detection**: Run the test in a loop: `for i in $(seq 1 10); do your-test-command; done`
- **Fix**: Replace sleep-based waits with polling/retry logic; add explicit timeouts
- **Rule added**: Never rely on fixed sleep durations in integration tests

---

## Adaptation Guidance

<!-- Customize this file for your project by following these steps: -->

To adapt this template for your project:

1. **Replace placeholder categories** with categories relevant to your codebase (e.g., "Database/Migrations", "API/Authentication", "Build System").
2. **Replace example incidents** (INC-001 through INC-003) with real incidents from your project. Keep the format consistent.
3. **Update the Index by Category** table whenever you add or remove a category section.
4. **Update the Quick Reference** table whenever you add a new incident.
5. **Set a threshold for rule promotion** — the default is 3 similar incidents before proposing a project-wide rule.
6. **Create an archive file** (`KNOWN-ISSUES-ARCHIVE.md`) for resolved incidents that are no longer actively relevant but may contain useful historical context.
7. **Customize search tips** in the header to reflect keywords common in your project (e.g., hook, config, deploy, flaky).

### Incident Entry Format

Use this format for each new incident:

```markdown
### INC-NNN: Short Descriptive Title
- **Date**: YYYY-MM
- **Keywords**: keyword1, keyword2, keyword3
- **Symptom**: What the user or CI observes
- **Root cause**: Why it happens
- **Detection**: How to check if this issue is occurring
- **Fix**: What to do about it
- **Rule added**: (optional) Rule added to prevent recurrence
```
