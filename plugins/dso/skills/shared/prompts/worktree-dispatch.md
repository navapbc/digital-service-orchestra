# Shared Worktree Dispatch Protocol

Standalone sub-workflow for configuring Agent/Task dispatch isolation when running in a worktree session. Consulted by orchestrators before dispatching sub-agents to determine whether to pass `isolation: "worktree"` to the Agent tool.

## Purpose

When an orchestrator is running inside a worktree, sub-agents dispatched via the Agent/Task tool receive a separate working tree and CWD (`isolation: "worktree"`). Worktree isolation is always enabled.

### What `isolation: "worktree"` IS and IS NOT

`isolation: "worktree"` is **CWD redirection plus a separate git working tree**. It is **NOT a filesystem sandbox**. A sub-agent still has read/write access to the broader filesystem via absolute paths and shares the main repo's git object database, so `git worktree list` enumerates every registered worktree (including the orchestrator's session worktree). The platform does not — and cannot, at this layer — prevent a sub-agent that *constructs* an absolute path from writing there.

The dispatch protocol below addresses this by NEVER giving the sub-agent the session-worktree path. Sub-agents derive their own `REPO_ROOT` from `$(git rev-parse --show-toplevel)` of their own CWD (which the Agent runtime points at their isolated worktree). They have no canonical reason to single out the session worktree from the multitude of worktrees `git worktree list` returns, and the dispatch prompt offers no such pointer. This shifts the breach surface from "the sub-agent knows exactly which absolute path is the session" to "the sub-agent would have to autonomously decide to enumerate and target a specific sibling worktree" — which has no use case in any documented agent workflow.

Bug history: 9679-695c-6e11-4d95 closed the deliberate-pointer surface by removing the `ORCHESTRATOR_ROOT` injection from dispatch prompts. The complementary agent-layer guard (every implementer agent derives write paths exclusively from its own CWD, never from `git worktree list` or absolute paths outside its worktree) is tracked under epic b36c-3e66-c0f2-413d.

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

### Isolation Self-Check (path-shape verification)

As the **first action after loading task context**, sub-agents SHOULD verify that their working directory matches the agent-worktree convention. Unlike the prior `ORCHESTRATOR_ROOT`-comparison check (which provided false reassurance — the platform already guarantees a distinct CWD under isolation), this check confirms the agent is in a recognized isolated location:

```bash
SUB_AGENT_ROOT=$(git rev-parse --show-toplevel)
if [[ "$SUB_AGENT_ROOT" != *"/.claude/worktrees/agent-"* ]]; then
  echo "WARNING: Sub-agent root does not match the isolated-worktree convention." >&2
  echo "         Got: $SUB_AGENT_ROOT" >&2
  echo "         Expected substring: /.claude/worktrees/agent-" >&2
  # Continue rather than exit — the convention check is a tripwire for
  # mis-configured dispatches, not a hard barrier (the platform's CWD
  # redirection already differentiates the sub-agent from the orchestrator).
fi
```

The check is informational. Even when it fails (e.g., for non-isolated dispatches in test fixtures), the sub-agent proceeds — there is no safe "wrong place to do work" that this check could detect, because the platform's CWD redirection already ensures the sub-agent is in its own worktree.

## Orchestrator Responsibilities

When using this protocol, orchestrators must:

1. Set `ISOLATION_ENABLED=true` before the first Agent dispatch (Step 1 above).
2. Inject `SESSION_BRANCH` and `SESSION_HEAD` into every sub-agent dispatch prompt when running from a session worktree (per Step 2 above).
3. Apply the isolation parameter consistently — do not mix isolated and non-isolated dispatches within the same sprint or debug session.
4. Do NOT inject the orchestrator's session-worktree absolute path into sub-agent prompts (closed in bug 9679-695c-6e11-4d95). The agent layer derives its own paths from its own CWD; the dispatch prompt never names the session worktree.

## Post-Dispatch Integration

### Multi-Agent Callers (sprint)

Multi-agent orchestrators (e.g., `/dso:sprint`) collect results from all sub-agents, then commit and merge each worktree serially via `per-worktree-review-commit.md`. The `harvest-worktree.sh` script handles the final merge into the session branch.

### Single-Agent Callers (fix-bug, debug-everything Bug-Fix Mode)

Single-agent callers dispatch one sub-agent at a time and use a simpler integration path. After the sub-agent returns, follow `single-agent-integrate.md` to review, commit, and merge the sub-agent's worktree back into the session branch.

The dispatch prompt for single-agent callers must NOT name the orchestrator's session-worktree absolute path (per bug 9679-695c-6e11-4d95). The orchestrator computes `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` for its own bash context (used by `single-agent-integrate.md` to compare against the sub-agent's `WORKTREE_PATH` after return), but that variable lives only in the orchestrator's shell — it is not injected into the sub-agent prompt.
