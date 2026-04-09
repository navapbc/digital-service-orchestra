# Shared Worktree Dispatch Protocol

Standalone sub-workflow for configuring Agent/Task dispatch isolation when running in a worktree session. Consulted by orchestrators before dispatching sub-agents to determine whether to pass `isolation: "worktree"` to the Agent tool.

## Purpose

When an orchestrator is running inside a worktree, sub-agents dispatched via the Agent/Task tool may share the orchestrator's working directory (legacy default) or receive an isolated sandboxed working directory (`isolation: "worktree"`). This protocol determines which mode applies based on the `worktree.isolation_enabled` config key.

## Step 1 — Read the Config Key

Read the config key using `read-config.sh` before dispatching any sub-agents:

```bash
ISOLATION_ENABLED=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config worktree.isolation_enabled 2>/dev/null || true)
```

Alternatively, invoke `read-config.sh` directly if the shim is unavailable:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
ISOLATION_ENABLED=$(.claude/scripts/dso read-config.sh worktree.isolation_enabled 2>/dev/null || true)
```

## Step 2 — Set Dispatch Parameters

Based on the config value:

**When `ISOLATION_ENABLED` equals `true`:**

Before dispatching, write an auth marker file so the pre-agent isolation guard can verify this is an authorized dispatch. The marker contains the orchestrator's PID; the guard validates PID liveness to reject stale markers:

```bash
_AUTH_MARKER="/tmp/worktree-isolation-authorized-$(uuidgen 2>/dev/null || date +%s$$)"
echo "$$" > "$_AUTH_MARKER"
```

Remove the marker file after all sub-agents in the current batch have been dispatched (cleanup is optional but avoids stale marker accumulation):

```bash
rm -f "$_AUTH_MARKER" 2>/dev/null || true
```

Then add `isolation: "worktree"` to the Agent/Task dispatch parameters so each sub-agent receives a sandboxed working directory independent of the orchestrator's directory.

Example dispatch with isolation enabled:

```yaml
agent: dso:my-agent
isolation: "worktree"
prompt: |
  <task instructions>
```

**When `ISOLATION_ENABLED` is `false`, empty, or absent:**

Skip the `isolation` parameter entirely. Sub-agents will share the orchestrator's working directory (shared-directory fallback — pre-isolation default behavior).

Example dispatch without isolation:

```yaml
agent: dso:my-agent
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

If the sub-agent cannot determine the orchestrator root (not passed via dispatch prompt), it should log a warning and continue — do not block on an unverifiable condition.

When `worktree.isolation_enabled=false` (shared-directory mode), skip the git root verification check — both roots are expected to match.

## Orchestrator Responsibilities

When using this protocol, orchestrators must:

1. Read `worktree.isolation_enabled` before the first Agent dispatch (Step 1 above).
2. Pass `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` in each sub-agent's dispatch prompt so the sub-agent can verify isolation.
3. Apply the isolation parameter consistently — do not mix isolated and non-isolated dispatches within the same sprint or debug session.
4. Handle sub-agent isolation errors by logging and re-dispatching rather than falling through silently.

## Non-Interactive Fallback

In non-interactive mode, isolation errors should be recorded as `INTERACTIVITY_DEFERRED` ticket comments rather than blocking the session. The orchestrator continues with the next sub-agent and surfaces the isolation failure in the session summary.
