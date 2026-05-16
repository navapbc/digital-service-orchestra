# Shared Worktree Dispatch Protocol

Standalone sub-workflow for configuring Agent/Task dispatch isolation when running in a worktree session. Consulted by orchestrators before dispatching sub-agents to determine whether to pass `isolation: "worktree"` to the Agent tool.

## Purpose

When an orchestrator is running inside a worktree, sub-agents dispatched via the Agent/Task tool receive a separate working tree and CWD (`isolation: "worktree"`). Worktree isolation is always enabled.

### What `isolation: "worktree"` IS and IS NOT

`isolation: "worktree"` is **CWD redirection plus a separate git working tree**. It is **NOT a filesystem sandbox**. The sub-agent process still has full read/write access to the orchestrator's working tree via:

- Absolute paths derived from `ORCHESTRATOR_ROOT`
- `cd "$ORCHESTRATOR_ROOT"` followed by ordinary writes / git operations on the session branch
- Any script or helper that derives its `REPO_ROOT` from sources other than `$(git rev-parse --show-toplevel)` of its own CWD

Empirically verified (bug c9df-0538): from inside an isolated sub-agent worktree, a write to `$ORCHESTRATOR_ROOT/some-file.txt` succeeds, and `cd "$ORCHESTRATOR_ROOT"` lands on the session branch with unrestricted git access.

**Implication**: write-path safety is the *agent's* responsibility, not the platform's. Every implementer-class sub-agent must (a) run the Git Root Verification snippet as its first action, (b) treat `ORCHESTRATOR_ROOT` as a *read-only* reference for invoking the orchestrator's shim (`$ORCHESTRATOR_ROOT/.claude/scripts/dso`), and (c) never use `ORCHESTRATOR_ROOT` as a write base. Reviewer-family agents that intentionally write to the orchestrator's shared artifacts directory are the documented exception.

## Step 1 — Set Isolation Mode

Isolation is always enabled:

```bash
ISOLATION_ENABLED=true
```

## Step 2 — Set Dispatch Parameters

**Isolation is always active:**

#### SESSION_BRANCH / SESSION_HEAD Injection (mandatory)

When the orchestrator is running inside a session worktree, the Claude Code Agent tool creates sub-agent worktrees from the **main repo's HEAD**, not from the session branch HEAD. To ensure sub-agents start from the correct commit, callers **must** inject `SESSION_BRANCH` and `SESSION_HEAD` into every sub-agent dispatch prompt.

Detect whether the orchestrator is in a session worktree:

```bash
IS_SESSION_WORKTREE=$([ -f "$(git rev-parse --show-toplevel)/.git" ] && echo "true" || echo "false")
```

**Push prerequisite**: Before injecting, if `IS_SESSION_WORKTREE=true`, the caller must have already pushed the session branch to origin so sub-agents can fetch it:

```bash
git push -u origin HEAD
```

Capture the values to inject:

```bash
SESSION_BRANCH=$(git rev-parse --abbrev-ref HEAD)
SESSION_HEAD=$(git rev-parse HEAD)
```

Include `SESSION_BRANCH=<value>` and `SESSION_HEAD=<value>` in every sub-agent dispatch prompt. Sub-agents call `worktree-session-head-sync.sh` on startup to sync to the session HEAD automatically (see `.claude/scripts/dso worktree-session-head-sync`).

Add `isolation: "worktree"` to the Agent/Task dispatch parameters so each sub-agent receives a sandboxed working directory independent of the orchestrator's directory.

Example dispatch with isolation enabled:

```yaml
agent: dso:my-agent
isolation: "worktree"
prompt: |
  <task instructions>
```

## Sub-Agent Constraints

All sub-agents dispatched under this protocol MUST observe the following constraints without exception:

### No-Commit Constraint

Sub-agents must NOT commit, push, or run any commit-related command. Prohibited actions include:

- `git commit` (any form, including `git commit --amend`)
- `/dso:commit` skill invocation
- `git push` or `git push --force`
- Any command that writes to git history

Sub-agents implement only and return results to the orchestrator. The orchestrator is solely responsible for all commit and push operations.

### Git Root Verification

As the **first action after loading task context**, sub-agents MUST verify that their working directory root differs from the orchestrator's root when isolation is enabled:

```bash
SUB_AGENT_ROOT=$(git rev-parse --show-toplevel)
# Orchestrator passes its root via the dispatch prompt as ORCHESTRATOR_ROOT
if [ "$SUB_AGENT_ROOT" = "$ORCHESTRATOR_ROOT" ]; then
  echo "ERROR: Sub-agent git root matches orchestrator root — isolation not in effect" >&2
  exit 1
fi
echo "Git root verified: $SUB_AGENT_ROOT (differs from orchestrator root: $ORCHESTRATOR_ROOT)"
```

If `ORCHESTRATOR_ROOT` is not set, exit 1: `"ERROR: ORCHESTRATOR_ROOT not injected — refusing to proceed."` Do NOT log-and-continue (proceeding risks corrupting the orchestrator's session branch).

## Orchestrator Responsibilities

When using this protocol, orchestrators must:

1. Set `ISOLATION_ENABLED=true` before the first Agent dispatch (Step 1 above).
2. Pass `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` in each sub-agent's dispatch prompt so the sub-agent can verify isolation.
3. Apply the isolation parameter consistently — do not mix isolated and non-isolated dispatches within the same sprint or debug session.
4. On sub-agent isolation error (exit 1), HALT the batch, record the failure as a ticket comment, and surface to the user. Do not silently re-dispatch.

## Non-Interactive Fallback

In non-interactive mode, on sub-agent isolation error:
1. Add ticket comment: `.claude/scripts/dso ticket comment <task-id> "ISOLATION_ERROR: sub-agent exited 1 — ORCHESTRATOR_ROOT not injected"`
2. Transition task back to open: `.claude/scripts/dso ticket transition <task-id> in_progress open`
3. Do NOT silently continue — re-dispatch only after confirming the dispatch prompt includes `ORCHESTRATOR_ROOT`.

## Post-Dispatch Integration

### Multi-Agent Callers (sprint)

Multi-agent orchestrators (e.g., `/dso:sprint`) collect results from all sub-agents, then commit and merge each worktree serially via `per-worktree-review-commit.md`. The `harvest-worktree.sh` script handles the final merge into the session branch.

### Single-Agent Callers (fix-bug, debug-everything Bug-Fix Mode)

Single-agent callers dispatch one sub-agent at a time and use a simpler integration path. After the sub-agent returns, follow `single-agent-integrate.md` to review, commit, and merge the sub-agent's worktree back into the session branch.

The dispatch prompt for single-agent callers must inject the orchestrator's working directory so the sub-agent can verify isolation. Before constructing the dispatch prompt, set:

```bash
ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)
```

Then include `{orchestrator_root}` in the dispatch prompt template. At runtime, replace `{orchestrator_root}` with the value of `$ORCHESTRATOR_ROOT` so the sub-agent receives the correct absolute path for isolation verification.
