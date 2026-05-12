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
| [Tickets/Version Control](#tickets-and-version-control) | 2 | 2026-04 |
| [Recipe Execution](#recipe-execution) | 1 | 2026-04 |
| [Plugin System](#plugin-system) | 3 | 2026-05 |
| [Bridge](#bridge) | 1 | 2026-05 |
| [Compliance Verifier / Commit Steps](#compliance-verifier-and-commit-steps) | 6 | 2026-05 |
| [PRECONDITIONS / Ack Mechanism](#preconditions-and-ack-mechanism) | 2 | 2026-05 |

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
| INC-019 | /reload-plugins Skill Count Undercounts | Plugin System | reload-plugins, skill count, 3 skills, commands, allowed-tools |
| INC-020 | validate.sh ENOBUFS / OSError 75 in CI | Plugin System | validate.sh, ENOBUFS, OSError 75, file descriptor, ulimit, CI |
| INC-030 | DSO Skills Unavailable on Session Start — Require /reload-plugins | Plugin System | plugin-loader, session start, skills unavailable, reload-plugins, 57cb-ea0c |
| INC-022 | `git checkout tickets` Fails Silently, Rebase Hits Wrong Branch | Tickets/Version Control | checkout tickets, tickets worktree, rebase wrong branch, .tickets-tracker, push ticket changes |
| INC-023 | Bridge: silent event drops (HEAD~1..HEAD blindness pattern) | Bridge | bridge, outbound, checkpoint, HEAD~1, silent drop, SHA cursor, BRIDGE_ENV_ID, BRIDGE_USER_MAP |
| INC-024 | Hook executable bit lost — compliance verifier stops running | Compliance Verifier / Commit Steps | pre-commit-compliance-verifier, executable bit, chmod, reinstall-hooks |
| INC-025 | First-run absent ARTIFACTS_DIR emits warning, exits 0 | Compliance Verifier / Commit Steps | WORKFLOW_PLUGIN_ARTIFACTS_DIR, absent dir, warn, fail-open, fresh worktree |
| INC-026 | ARTIFACTS_DIR path shared across CI jobs on same runner | Compliance Verifier / Commit Steps | WORKFLOW_PLUGIN_ARTIFACTS_DIR, CI, ephemeral, cross-job, artifact pollution |
| INC-027 | Branch-name slashes do not cause ARTIFACTS_DIR path divergence | Compliance Verifier / Commit Steps | ARTIFACTS_DIR, SHA-256, REPO_ROOT hash, branch name, slashes |
| INC-028 | Combined skip conditions write one .skipped file, not two | Compliance Verifier / Commit Steps | enforcement.strategy=ci, SKIP_REVIEW, .skipped, commit-step, first-wins |
| INC-029 | record-test-status.sh --attest is harvest-mode, not a pass-recorder | Compliance Verifier / Commit Steps | record-test-status, --attest, worktree harvest, harvest sub-agent, passing test |
| INC-031 | Non-Latin precondition text requires human ack review | PRECONDITIONS / Ack Mechanism | preconditions-ack, non-Latin, MANUAL_REVIEW_REQUIRED, exit 2, rationale, unicode |
| INC-032 | Cross-worktree ack race window | PRECONDITIONS / Ack Mechanism | check-unacked-degradations, ack, worktree, tickets branch, sync, race window |

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
- **Detection**: Check ~/.claude/logs/dso-hook-errors.jsonl for repeated hook errors. Multiple unrelated commands fail with hook errors.
- **Fix**: Check ~/.claude/logs/dso-hook-errors.jsonl to identify the root hook. Fix the root hook error. Run /dso:fix-cascade-recovery if more than 5 cascading failures have occurred.
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

### INC-022: `git checkout tickets` Fails Silently, Rebase Hits Wrong Branch
- **Date**: 2026-04
- **Keywords**: checkout tickets, tickets worktree, rebase wrong branch, .tickets-tracker, push ticket changes, fast-forward rejected, git -C
- **Symptom**: Pushing accumulated ticket events (ticket creates, edits, links, comments, tags) is rejected because `origin/tickets` has diverged. The natural recovery — `git checkout tickets && git rebase origin/tickets` — fails on the checkout step but does NOT stop the script; the subsequent `git rebase` then runs against the current branch (typically the feature branch), attempting to replay hundreds of unrelated commits onto `origin/tickets`, producing conflicts on files like `.gitignore`, `CLAUDE.md`, and source code that have nothing to do with the tickets branch.
- **Root cause**: The tickets orphan branch is always checked out as a worktree at `.tickets-tracker/`. Git refuses to check out a branch in a second working tree (`fatal: 'tickets' is already used by worktree at '...'`), but this is a fatal-to-the-command error, not a fatal-to-the-script error — the checkout fails while the shell continues. A following `git rebase origin/tickets` then acts on the current branch, which is the feature branch, not tickets.
- **Detection**: You see `fatal: 'tickets' is already used by worktree at '.tickets-tracker'` followed by a `Rebasing (1/N)` progress message where N is much larger than the ~10 ticket commits you expected (indicating the feature branch is being replayed). Conflicts appear on files that tickets branch does not track (e.g., `.gitignore`, source files, CLAUDE.md).
- **Fix**: Abort immediately with `git rebase --abort`. Then operate on the tickets branch via its worktree using the `-C .tickets-tracker` flag — do not attempt to `checkout tickets` from the main worktree. Canonical sequence:
  ```bash
  git -C .tickets-tracker fetch origin tickets
  git -C .tickets-tracker rebase origin/tickets
  git -C .tickets-tracker push origin tickets
  ```
  For routine pushes, prefer `.claude/scripts/dso merge-to-main.sh` (which handles the tickets branch sync inline), or the ticket CLI's built-in best-effort auto-push via `_push_tickets_branch`.
- **Prevention**: When a push is rejected on the tickets branch, always use `git -C .tickets-tracker` to operate on the tickets worktree directly. Never attempt to `git checkout tickets` from the primary worktree — it will silently fail and expose the following rebase to the wrong branch.

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

---

## Plugin System

### INC-020: validate.sh ENOBUFS / OSError 75 Under CI File-Descriptor Limits

- **Date**: 2026-04
- **Keywords**: validate.sh, ENOBUFS, OSError 75, file descriptor, fd limit, CI, ulimit, resource exhaustion
- **Ticket**: 3cd9-5a95
- **Symptom**: `validate.sh --ci` exits with `OSError: [Errno 75] Value too large for defined data type` (ENOBUFS on some platforms) during subprocess execution inside CI. The failure is non-deterministic and more likely under parallelism or when many files are open.
- **Root cause**: The CI runner hits its file-descriptor ceiling (`ulimit -n`). When subprocesses inherit open FDs from the parent shell and the OS-level limit is reached, writes to pipes or sockets fail with ENOBUFS (errno 75). This is a resource-exhaustion condition, not a test logic error.
- **Detection**: Exit code from validate.sh is non-zero; stderr contains `OSError: [Errno 75]` or `ENOBUFS`. The failure is intermittent and correlates with parallel job counts.
- **Fix**:
  1. Raise the file-descriptor limit before running: `ulimit -n 65536 && .claude/scripts/dso validate.sh --ci`
  2. In CI job YAML, add `ulimit -n 65536` as a pre-step shell command, or set `nofile` via the runner's resource-limits config.
  3. If the runner does not allow raising limits, reduce parallelism: set `orchestration.max_agents=1` in `dso-config.conf` for the CI job.
- **Rule candidate**: 3+ occurrences → propose CLAUDE.md rule to always raise `ulimit -n` before running validate.sh in CI.

---

### INC-019: /reload-plugins Skill Count Undercounts — Shows 3 Instead of 32

- **Date**: 2026-04
- **Keywords**: reload-plugins, skill count, 3 skills, commands, allowed-tools, SKILL.md, plugin loader
- **Symptom**: `/reload-plugins` reports "1 plugin · 3 skills · 29 agents · 14 hooks" but all 32 dso skills are actually loaded and invocable via the Skill tool. The system-reminder skill list shows all 32 `dso:*` skills available.
- **Root cause**: The `/reload-plugins` "skills" counter counts files in the `commands/` directory (flat `.md` files), NOT structured skills in `skills/*/SKILL.md`. The DSO plugin has exactly 3 command files (`commands/commit.md`, `commands/end.md`, `commands/review.md`), which matches the reported count. This is an upstream Claude Code bug — see [anthropics/claude-code#41842](https://github.com/anthropics/claude-code/issues/41842).
- **Detection**: `/reload-plugins` shows a low skill count, but the system-reminder skill list shows all expected `dso:*` skills. Skills can be invoked normally via the Skill tool.
- **Fix**: No fix needed — this is cosmetic. All 32 skills load correctly and are invocable. The "3 skills" count is misleading but does not indicate a functional problem.
- **History**: Three fix attempts targeted `allowed-tools` frontmatter (bugs 06fc-1ebc, 9a3b-7426, 844b-f190) before root cause was identified as upstream. The `allowed-tools` fixes were not wrong (null values did need fixing) but were unrelated to the reported count.
- **Upstream**: [anthropics/claude-code#41842](https://github.com/anthropics/claude-code/issues/41842), [#35641](https://github.com/anthropics/claude-code/issues/35641), [#36646](https://github.com/anthropics/claude-code/issues/36646)
- **Rule candidate**: Do not treat the `/reload-plugins` skill count as a correctness indicator. Verify skill availability via the system-reminder skill list or by invoking the Skill tool directly.

---

### INC-030: DSO Skills Unavailable on Session Start — Require /reload-plugins

- **Date**: 2026-05
- **Keywords**: plugin-loader, session start, skills unavailable, reload-plugins, DSO skills, /dso:sprint, /dso:fix-bug, session init, harness, 57cb-ea0c
- **Symptom**: When a new Claude Code session starts in a project where the DSO plugin is installed, DSO skills (`/dso:sprint`, `/dso:fix-bug`, `/dso:create-bug`, etc.) are not registered and not invocable. The user must run `/reload-plugins` to load them. After running it, the harness reports "1 plugin · 3 skills · 45 agents · 14 hooks". Skills and agents are then fully available.
- **Root cause**: Upstream Claude Code harness behavior. The plugin loader lifecycle hook that registers skills at session initialization does not fire reliably for marketplace plugins. This is NOT a DSO defect — the plugin's `plugin.json`, `skills/*/SKILL.md`, and agent files are correctly defined and load correctly once `/reload-plugins` is triggered. Upstream references: [anthropics/claude-code#48963](https://github.com/anthropics/claude-code/issues/48963) (Plugin skills not appearing in / menu after v2.1.110), [#37862](https://github.com/anthropics/claude-code/issues/37862) (/reload-plugins doesn't rebuild slash-command index).
- **Detection**: Attempting to invoke a DSO skill falls back to non-skill behavior, OR the Skill tool is called but the skill is not in the `system-reminder` available-skills list. After `/reload-plugins`, skills appear normally.
- **Workaround**: Run `/reload-plugins` at the start of every new session as a precaution. After it runs, verify the system-reminder skill list contains the expected `dso:*` entries.
- **DSO-side action**: Documented in KNOWN-ISSUES.md. No code fix possible within DSO — this is owned by the Claude Code harness. The CLAUDE.md "Always Do These" rules (e.g., rule 1: use `/dso:sprint` or `/dso:fix-bug`) silently no-op if skills are not loaded, so the `/reload-plugins` workaround must precede any skill invocation in an affected session.
- **Rule candidate**: Add a one-line note to INSTALL.md advising users to run `/reload-plugins` at the start of each session if DSO skills are not available.
- **Upstream ticket**: Bug 57cb-ea0c-066b-4ba1.

---

### INC-021: debug-everything worktree tracking gap

- **Date**: 2026-04
- **Keywords**: debug-everything, WORKTREE_TRACKING, resume scan, abandoned worktree, bug-fix mode
- **Symptom**: Sub-agents dispatched by debug-everything have `WORKTREE_TRACKING:start` comments (from the sub-agent task-execution prompt), but debug-everything's Bug-Fix Mode has no resume scan. If a debug-everything session is interrupted mid-sub-agent, the abandoned worktree is not automatically recovered on the next run.
- **Root cause**: The WORKTREE_TRACKING resume scan was added to sprint and fix-bug orchestrators but not to debug-everything's Bug-Fix Mode. debug-everything operates differently (dispatches many parallel bug-fix sub-agents) and the scan logic was not ported.
- **Workaround**: Before re-running debug-everything, check for `WORKTREE_TRACKING:start` comments on open bug tickets via `.claude/scripts/dso ticket show <id>`. If unmatched `:start` comments are found, manually invoke `.claude/scripts/dso harvest-worktree <branch> <artifacts-dir>` for each abandoned branch, or run `resolve-abandoned-worktrees.sh` if available.
- **Fix**: Add a WORKTREE_TRACKING resume scan step to debug-everything's Bug-Fix Mode initialization (tracked as future work).

---

### INC-022: Epic shipped without external deliverable (TDD-exemption misuse)

- **Date**: 2026-04
- **Keywords**: TDD exemption, external deliverable, repository not found, baff-7163, completion-verifier, smoke test, PATH stubbing
- **Symptom**: Epic `baff-7163` (the original DSO NextJS template work) was marked complete and merged. When users tried to run `bash <(curl ... create-dso-app.sh) my-project`, the installer failed with `fatal: repository not found` because the live template repo at `navapbc/digital-service-orchestra-nextjs-template` had never been created. The completion-verifier and smoke-test gates both passed because the only verification path was a unit test that PATH-stubbed `git`.
- **Root cause**: A combination of four process gaps:
  1. **TDD exemption**: story `caf7-e03d` / task `0e30-57fd` closed under a TDD exemption that allowed claiming completion of an external-system deliverable with no out-of-repo verification (bug `0f2a-95c9`).
  2. **Narrative evidence accepted**: completion-verifier accepted prose evidence (a closing comment that asserted the repo was created) for an observable-behavior success criterion (bug `b306-d9ac`).
  3. **URL drift undetected**: the story's done-definition URL was never reconciled against the implementation; review did not flag the gap (bug `91aa-b725`).
  4. **Mocked verification path**: the only smoke test PATH-stubbed `git`, so a successful clone was never exercised against a real URL (bug `068c-1e8a`, resolved by epic `e772-d73b` story `6bf8-858d`).
- **Detection**: A user attempted to run the installer; the failure surfaced immediately because the repo did not exist. No automated detection was possible because every gate had a vacuous-pass path.
- **Fix**: Epic `e772-d73b` delivered the missing template repo, the NOTICE attribution, and a real-URL e2e validation path (`tests/scripts/test-create-dso-app-real-url.sh`) that does not stub `git`. The four contributing process bugs (`0f2a-95c9`, `b306-d9ac`, `91aa-b725`, `068c-1e8a`) are tracked separately so the underlying gates can be hardened independently. `068c-1e8a` is closed; the others remain open.
- **Rule candidate**: When a story's done-definition references an externally-observable artifact (a URL, a published package, a deployed service), the verification path MUST exercise the real artifact end-to-end. PATH-stubbing, mocking, or accepting a closing comment as "evidence" all fail open. Either the test runs against the real artifact (preferred) or the closure requires explicit human attestation that the artifact is reachable.

---

## Bridge

### INC-023: Bridge silent event drops (HEAD~1..HEAD blindness pattern)

- **Date**: 2026-05
- **Keywords**: bridge, outbound, checkpoint, HEAD~1, silent drop, SHA cursor, BRIDGE_ENV_ID, BRIDGE_USER_MAP, cron, multi-commit
- **Symptom**: The outbound bridge misses STATUS, COMMENT, or other events between cron ticks when multiple commits land on the tickets branch in a single interval. Jira issues appear stale despite activity in the ticket tracker.
- **Root cause**: Pre-fix, the outbound bridge used `HEAD~1..HEAD` to find ticket events, which only captured the single most-recent commit. When 4+ commits landed between cron runs (e.g., HEAD~4..HEAD~6), events from all but the last commit were invisible to the bridge.
- **Fix**: SHA-cursor checkpoint in `plugins/dso/scripts/bridge/_outbound_cursor.py`. The cursor persists the last-processed commit SHA in `.outbound-checkpoint.json` on the `tickets` orphan branch. Each run fetches events since the stored SHA, then updates the cursor. Cold-start, corrupt, or unreachable SHA all seed the cursor at HEAD and emit `BRIDGE_ALERT` so the event is surfaced without blocking the run.
- **Recovery**: If `.outbound-checkpoint.json` is absent or corrupt, the bridge self-heals on the next cron tick (seeds at HEAD, emits BRIDGE_ALERT). Manual recovery is not required unless events from the gap must be replayed — in that case, manually set the checkpoint SHA to the desired start commit and trigger the bridge run.
- **Related**:
  - `BRIDGE_ENV_ID` fail-fast: if the bridge is not starting at all, verify `gh variable list | grep BRIDGE_ENV_ID`. An empty or missing value causes both bridges to exit immediately.
  - `BRIDGE_USER_MAP` assignee issues: if Jira issues are created unassigned, check that the commit author's email is present (case-insensitively) in the `BRIDGE_USER_MAP` JSON env var. Missing entries fall through to BRIDGE_ALERT + `unassign_issue()`.
  - Full bridge reference: `plugins/dso/scripts/bridge/README.md`.

---

## Compliance Verifier and Commit Steps

### INC-024: Hook Executable Bit Lost — Compliance Verifier Stops Running

- **Date**: 2026-05
- **Keywords**: pre-commit-compliance-verifier, executable bit, chmod, reinstall-hooks, .pre-commit-config.yaml
- **Symptom**: `.pre-commit-config.yaml` entries for the compliance verifier are present, but the hook never fires. Commits proceed without enforcement checks.
- **Root cause**: The executable bit on `plugins/dso/hooks/pre-commit-compliance-verifier.sh` was lost (e.g., after a checkout on a filesystem that does not preserve execute permissions, or after a git operation that reset file modes).
- **Detection**: `ls -la plugins/dso/hooks/pre-commit-compliance-verifier.sh` — the permission string should be `-rwxr-xr-x`. If it shows `-rw-r--r--`, the bit is missing.
- **Fix**:
  ```bash
  chmod +x plugins/dso/hooks/pre-commit-compliance-verifier.sh
  bash plugins/dso/scripts/reinstall-hooks.sh
  ```
- **Rule added**: When creating a new `.sh` file, always set the executable bit immediately (`chmod +x`).

---

### INC-025: First-Run Absent ARTIFACTS_DIR Emits Warning, Exits 0

- **Date**: 2026-05
- **Keywords**: WORKFLOW_PLUGIN_ARTIFACTS_DIR, absent dir, warn, fail-open, fresh worktree, first-run
- **Symptom**: On a fresh worktree before any commit-step has run, the compliance verifier emits a warning about a missing directory and then exits 0 (fail-open). No enforcement occurs.
- **Root cause**: `WORKFLOW_PLUGIN_ARTIFACTS_DIR` is set to a path that has not yet been created. The verifier treats an absent directory as "no artifacts yet" rather than an error, so it warns and exits cleanly.
- **Detection**: Verifier output contains a warning about the artifacts directory not existing, followed by a clean exit. This happens on the very first commit in a new worktree session before any commit-step wrapper has written artifacts.
- **Fix**: No action needed — this is expected behavior. After the first commit-step (e.g., `commit-step.sh test ...`) runs and creates the directory, subsequent compliance checks operate normally.
- **Prevention**: If you want the verifier to enforce on the first commit, pre-create the directory: `mkdir -p "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"`.

---

### INC-026: ARTIFACTS_DIR Path Shared Across CI Jobs on the Same Runner

- **Date**: 2026-05
- **Keywords**: WORKFLOW_PLUGIN_ARTIFACTS_DIR, CI, ephemeral, cross-job, artifact pollution, shared runner
- **Symptom**: In CI, artifacts from one job are visible to a subsequent job on the same runner, causing stale or incorrect compliance state. A job that should fail passes because it reads a `.passed` file written by a previous job.
- **Root cause**: The default `WORKFLOW_PLUGIN_ARTIFACTS_DIR` resolves to `/tmp/workflow-plugin-<hash>/` where `<hash>` is derived from `REPO_ROOT`. On a shared runner where the workspace path is stable, multiple jobs share the same hash and therefore the same directory.
- **Detection**: CI logs show a commit-step reading artifacts that were not written in the current job. The artifacts directory is not cleaned between jobs.
- **Fix**: In the CI job YAML, set `WORKFLOW_PLUGIN_ARTIFACTS_DIR` explicitly to an ephemeral per-job path:
  ```yaml
  env:
    WORKFLOW_PLUGIN_ARTIFACTS_DIR: /tmp/workflow-plugin-${{ github.run_id }}-${{ github.job }}
  ```
- **Prevention**: Always set `WORKFLOW_PLUGIN_ARTIFACTS_DIR` explicitly in CI environments. Do not rely on the default `/tmp/` path when multiple jobs share a runner.

---

### INC-027: Branch-Name Slashes Do Not Cause ARTIFACTS_DIR Path Divergence

- **Date**: 2026-05
- **Keywords**: ARTIFACTS_DIR, SHA-256, REPO_ROOT hash, branch name, slashes, feat/foo/bar, path divergence
- **Symptom**: Developers expect branches with slashes in their names (e.g., `feat/foo/bar`) to produce different `ARTIFACTS_DIR` paths than flat branches (e.g., `feat-foo-bar`), creating confusion when artifacts appear to be shared across branches.
- **Root cause**: `ARTIFACTS_DIR` is derived from a SHA-256 hash of `REPO_ROOT` (the absolute path to the repository root), not from the branch name. Branch names with slashes or any other characters have no effect on the hash.
- **Detection**: Run `get_artifacts_dir` (sourced from `plugins/dso/hooks/lib/deps.sh`) on two branches with different names from the same repo root — the path is identical.
- **Fix**: No fix needed — this is by design. Artifact isolation across branches is not a goal of `ARTIFACTS_DIR`; isolation across repository roots is. If per-branch isolation is required, set `WORKFLOW_PLUGIN_ARTIFACTS_DIR` explicitly to include a branch identifier.

---

### INC-028: Combined Skip Conditions Write One .skipped File, Not Two

- **Date**: 2026-05
- **Keywords**: enforcement.strategy=ci, SKIP_REVIEW, .skipped, commit-step, first-wins, combined skip
- **Symptom**: When both `enforcement.strategy=ci` and `SKIP_REVIEW=true` are active simultaneously, only one `.skipped` file is written per step instead of two. Tooling that counts `.skipped` files may show an unexpected count.
- **Root cause**: `commit-step.sh` evaluates skip conditions in order and exits after the first matching condition writes the `.skipped` file. The second condition is never evaluated. Both `enforcement.strategy=ci` and `SKIP_REVIEW=true` produce identical outcomes (step is skipped), so the single-file behavior is correct.
- **Detection**: After a commit with both conditions active, `ls "$ARTIFACTS_DIR"/<step>/` shows exactly one `.skipped` file, not two.
- **Fix**: No fix needed — this is correct behavior. Both conditions produce the same outcome; one `.skipped` file accurately represents the step status.
- **Note**: If you need to distinguish *why* a step was skipped, inspect the `.skipped` file content — it records the skip reason from the first matching condition.

---

### INC-029: record-test-status.sh --attest Is Harvest-Mode, Not a Pass-Recorder

- **Date**: 2026-05
- **Keywords**: record-test-status, --attest, worktree harvest, harvest sub-agent, passing test, attestation
- **Symptom**: A developer or sub-agent calls `record-test-status.sh --attest` intending to record a passing test result, but the test status is not recorded as expected. The commit-step gate later fails because no `.passed` artifact is present.
- **Root cause**: `--attest` is a worktree-import mode designed for cross-worktree harvest (used by harvest sub-agents via `harvest-worktree.sh`). It imports pre-existing artifacts from a source worktree rather than recording a new test result. Calling it to record a normal passing status has no effect in standard workflows.
- **Detection**: After `record-test-status.sh --attest ...`, the test artifact directory does not contain the expected `.passed` file. The commit-step gate rejects the commit.
- **Fix**: To record a normal passing test status, call `record-test-status.sh` without `--attest`:
  ```bash
  bash plugins/dso/scripts/record-test-status.sh passed "tests/scripts/test-foo.sh"
  ```
  Use `--attest` only when you are a harvest sub-agent importing results from a completed worktree branch.
- **Rule added**: `--attest` is only for harvest sub-agents. Never use it to record a passing test status in a normal workflow.

---

## PRECONDITIONS and Ack Mechanism

### INC-031: Non-Latin Precondition Text Requires Human Ack Review

- **Date**: 2026-05
- **Keywords**: preconditions-ack, non-Latin, MANUAL_REVIEW_REQUIRED, exit 2, rationale, unicode, CJK, Arabic, Cyrillic
- **Symptom**: `dso preconditions-ack` exits 2 with a `MANUAL_REVIEW_REQUIRED` message when the precondition text or the provided rationale contains non-Latin characters (CJK, Arabic, Cyrillic, etc.).
- **Root cause**: The automated 3-word-window validation algorithm matches key terms from the precondition text against the rationale. The windowing logic uses Latin-alphabet tokenization and cannot reliably match non-Latin scripts, so it conservatively escalates to manual review rather than risk a false-positive approval.
- **Detection**: Exit code 2 from `preconditions-ack`; stderr includes `MANUAL_REVIEW_REQUIRED`. Latin-only preconditions with equivalent English rationale pass without this error.
- **Workaround**: A human reviewer must manually verify the rationale and perform the ack with their own `--if-skipped` text that references an English translation of the precondition. The automated gate cannot approve non-Latin rationales.
- **Rule candidate**: If 3+ non-Latin preconditions appear in the same project, propose adding a `PRECONDITIONS_LOCALE` config key to route to a locale-aware validator.

---

### INC-032: Cross-Worktree Ack Race Window

- **Date**: 2026-05
- **Keywords**: check-unacked-degradations, ack, worktree, tickets branch, sync, race window, cross-worktree
- **Symptom**: `check-unacked-degradations.sh` reports unacknowledged degradations even though another worktree session has already written ACK files for those degradations.
- **Root cause**: ACK files are written to the `tickets` orphan branch. If the `tickets` branch has not been synced between worktrees (e.g., via `git -C .tickets-tracker fetch origin tickets && git -C .tickets-tracker rebase origin/tickets`), the check reads a stale branch state and cannot see ACKs written by the other session.
- **Detection**: `check-unacked-degradations.sh` exits non-zero listing degradations that you know were already acked in another worktree. Running `git -C .tickets-tracker log --oneline -5` shows that the local tickets branch is behind the remote.
- **Workaround**: Run `.claude/scripts/dso ticket sync` (or the equivalent `git -C .tickets-tracker fetch && git -C .tickets-tracker rebase origin/tickets`) between worktrees before running `check-unacked-degradations.sh`. This ensures all ACKs written in other sessions are visible locally.
- **Prevention**: Always sync the tickets branch when switching between worktree sessions that involve PRECONDITIONS acks.
