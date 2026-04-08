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
| [Recipe Execution](#recipe-execution) | 1 | 2026-04 |

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
| INC-018 | Recipe Engine Prerequisites | Recipe Execution | recipe, rope, ts-morph, isort, scaffold |

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

---

## Review and Commit Workflow

### INC-016: git stash Destroys Staged Files During Diagnosis
- **Date**: 2026-04
- **Keywords**: git stash, staged files, pre-commit, review workflow, diagnosis
- **Symptom**: Running `git stash` while diagnosing a pre-commit failure unstages all previously staged files. After `git stash pop`, files return to the working tree as unstaged modifications, requiring manual re-staging of every file.
- **Root cause**: `git stash` (without flags) saves both the index (staged) and working tree changes, then resets both to HEAD. On pop, changes are restored as unstaged working tree modifications — the original staging state is lost.
- **Detection**: After `git stash pop`, `git status` shows all previously staged files as unstaged (`M` not `M `). Any staged test files (new files) may appear as untracked.
- **Fix**: Re-stage all files manually: `git add <file1> <file2> ...`. For new files, use `git add` to re-stage them.
- **Prevention**: Never use bare `git stash` when staged files must be preserved. Use one of these alternatives instead:
  - `git stash --keep-index` — stashes only unstaged changes; leaves the index intact.
  - Save the diff first: `git diff --cached > /tmp/staged.patch`, then restore with `git apply --cached /tmp/staged.patch` after the stash pop.
  - For read-only diagnosis (just want to see what HEAD looks like): use `git diff HEAD <file>` or `git show HEAD:<file>` instead of stashing.
- **Rule added**: When staged files are present, never use `git stash` without `--keep-index`.

### INC-017: Review Orchestrator Uses Wrong Hash Method Causing record-review.sh Failures
- **Date**: 2026-04
- **Keywords**: compute-diff-hash, record-review, diff hash mismatch, review gate, sha256sum
- **Symptom**: `record-review.sh --expected-hash <hash>` fails with "diff hash mismatch — code changed between review dispatch and recording" even though no code changed. Multiple review re-dispatches required.
- **Root cause**: The review orchestrator captured the diff hash using `git diff HEAD | sha256sum` or `git diff --cached | sha256sum`, but `record-review.sh` validates against the output of `plugins/dso/hooks/compute-diff-hash.sh`. These produce different hashes for the same staged state because `compute-diff-hash.sh` applies an exclusion pathspec allowlist (`.tickets-tracker/**`, `docs/**`, `.claude/docs/**`, `*.png`, etc.) before hashing.
- **Detection**: `record-review.sh` exits 1 with "Expected: <hash-A> / Current: <hash-B>" where both hashes are non-trivially different despite no visible code change.
- **Fix**: Always use `plugins/dso/hooks/compute-diff-hash.sh` (or its shim equivalent) as the canonical hash capture method. Run it directly: `DIFF_HASH=$(bash "$PLUGIN_ROOT/hooks/compute-diff-hash.sh")`. Never substitute `git diff | sha256sum` — the exclusion pathspecs make them non-equivalent.
- **Rule added**: Diff hash for review must always be captured via `compute-diff-hash.sh`, not via raw `git diff | sha256sum`. Tracked in ticket 0815-cee3 for REVIEW-WORKFLOW.md update and shim registration.

---

## Recipe Execution

### INC-018: Engine Prerequisites for Recipe Adapters

- **Date**: 2026-04
- **Keywords**: recipe, rope, ts-morph, isort, scaffold, engine, command not found
- **Symptom**: `recipe-executor.sh` exits with adapter error; error JSON contains engine-not-found message; 'command not found: rope' / 'Cannot find module ts-morph' / 'isort: command not found'
- **Root cause**: Each recipe adapter requires its engine to be installed in the current environment. The executor does not auto-install engines.
- **Required by engine**:
  - **rope** (Python AST adapter): `pip install rope` or add to `pyproject.toml` dev dependencies
  - **ts-morph** (TypeScript AST adapter): `npm install ts-morph` in the project root (ts-morph-adapter looks for node_modules/ts-morph relative to CWD)
  - **isort** (Python import sorting): `pip install isort` or add to dev dependencies
  - **scaffold** (file generation): No engine dependency — uses bash + template files in `recipes/templates/`
- **Fix**: Install the required engine for the recipe being run. For CI: add engine installs to the CI job that runs recipes.
- **Rule candidate**: 3+ failures → propose CLAUDE.md rule requiring engine prerequisite check before recipe execution.
