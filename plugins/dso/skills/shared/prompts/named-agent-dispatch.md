# Named-Agent Dispatch Pattern

When a skill needs to dispatch a named DSO agent (e.g., `dso:intent-search`, `dso:bot-psychologist`, `dso:scope-drift-reviewer`, the `dso:investigator-*` family), the dispatch follows a uniform pattern. This prompt defines that pattern once so the calling skills can reference it with a one-line link rather than restating it inline.

## Dispatch rules

1. **`dso:<name>` is an agent file identifier, NOT a valid `subagent_type` value.** The Agent tool only accepts built-in subagent types (most commonly `general-purpose`). The `dso:` prefix maps to a file at `${CLAUDE_PLUGIN_ROOT}/agents/<name>.md`.
2. **Read the agent file inline** with the Read tool, then dispatch with `subagent_type: "general-purpose"` and the agent's frontmatter `model:` value. Pass the agent file's content verbatim as the prompt body, followed by your skill-specific input.
3. **Generated agents** (composed from base + delta — `code-reviewer-*`, `investigator-*`) are equivalent to hand-written agents at the file level. Read them the same way.
4. **Inline fallback** when the Agent tool is unavailable (sub-agent context): read the agent file as a reference and execute its instructions directly, applying the calling skill's investigation/dispatch framework rather than nesting another sub-agent dispatch (which is prohibited per CLAUDE.md `rule:no-nested-task`). Defer steps that require Agent-tool capabilities and surface them as `INTERACTIVITY_DEFERRED` in the RESULT.
5. **Worktree-isolation preamble (MANDATORY when the orchestrator is in a session worktree).** When `IS_SESSION_WORKTREE=true` (`[ -f "$(git rev-parse --show-toplevel)/.git" ]`), every dispatch MUST include all three of the following:
   - `isolation: "worktree"` parameter on the Agent dispatch
   - `SESSION_BRANCH=<branch name>` as a prompt-body line — used by `worktree-session-head-sync.sh`
   - `SESSION_HEAD=<sha>` as a prompt-body line — used by `worktree-session-head-sync.sh`

   The sub-agent receives a separate working tree and CWD but **NOT a filesystem sandbox** (see `worktree-dispatch.md` Purpose). Per bug 9679-695c-6e11-4d95, the dispatch does NOT name the orchestrator's session-worktree absolute path — sub-agents derive their own `REPO_ROOT` from their own `git rev-parse --show-toplevel`. The agent-layer guard (every implementer agent derives writes exclusively from its own CWD) is tracked under epic b36c-3e66-c0f2-413d.

   **Reviewer-family exception**: `dso:code-reviewer-*` and `dso:huge-diff-*` agents are intentionally dispatched WITHOUT `isolation: "worktree"` (they must write `reviewer-findings.json` to the shared `$WORKTREE_ARTIFACTS`). For those agents, pass `WORKFLOW_PLUGIN_ARTIFACTS_DIR=$WORKTREE_ARTIFACTS` in the dispatch prompt and omit the `isolation` parameter. See `single-agent-integrate.md` Step 5 / `per-worktree-review-commit.md` for the canonical reviewer dispatch shape.

## Template

```
Read: ${CLAUDE_PLUGIN_ROOT}/agents/<name>.md
subagent_type: "general-purpose"
model: <value of model: from <name>.md frontmatter>
isolation: "worktree"           # required when IS_SESSION_WORKTREE=true; omit for reviewer-family agents
prompt: |
  SESSION_BRANCH=<session branch name>
  SESSION_HEAD=<session HEAD sha>

  {verbatim content of agents/<name>.md}

  Input: <skill-specific inputs as documented by the calling skill>
```

The three-parameter preamble (`isolation:` + `SESSION_BRANCH` + `SESSION_HEAD`) is the contract `worktree-session-head-sync.sh` relies on. If your calling skill does not need the agent to write code, you may omit `isolation: "worktree"` (read-only classifiers, reviewers); see Rule 5 above for the reviewer-family exception.

## Where applied

This pattern applies anywhere a skill dispatches a `dso:*` named agent. Calling skills should write a one-line reference (e.g., "Dispatch `dso:intent-search` per `skills/shared/prompts/named-agent-dispatch.md`") and supply the skill-specific inputs, not restate the dispatch rules.
