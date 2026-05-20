# Named-Agent Dispatch Pattern

When a skill needs to dispatch a named DSO agent (e.g., `dso:intent-search`, `dso:bot-psychologist`, `dso:scope-drift-reviewer`, the `dso:investigator-*` family), the dispatch follows a uniform pattern. This prompt defines that pattern once so the calling skills can reference it with a one-line link rather than restating it inline.

## Dispatch rules

1. **`dso:<name>` is an agent file identifier, NOT a valid `subagent_type` value.** The Agent tool only accepts built-in subagent types (most commonly `general-purpose`). The `dso:` prefix maps to a file at `${CLAUDE_PLUGIN_ROOT}/agents/<name>.md`.
2. **Read the agent file inline** with the Read tool, then dispatch with `subagent_type: "general-purpose"` and the agent's frontmatter `model:` value. Pass the agent file's content verbatim as the prompt body, followed by your skill-specific input.
3. **Generated agents** (composed from base + delta — `code-reviewer-*`, `investigator-*`) are equivalent to hand-written agents at the file level. Read them the same way.
4. **Inline fallback** when the Agent tool is unavailable (sub-agent context): read the agent file as a reference and execute its instructions directly, applying the calling skill's investigation/dispatch framework rather than nesting another sub-agent dispatch (which is prohibited per CLAUDE.md `rule:no-nested-task`). Defer steps that require Agent-tool capabilities and surface them as `INTERACTIVITY_DEFERRED` in the RESULT.
5. **Worktree-isolation preamble (MANDATORY when the orchestrator is in a session worktree).** When `IS_SESSION_WORKTREE=true` (`[ -f "$(git rev-parse --show-toplevel)/.git" ]`), every dispatch MUST include all four of the following — omitting any one of them is the documented intermittent-breach mode of bug c9df-0538:
   - `isolation: "worktree"` parameter on the Agent dispatch
   - `ORCHESTRATOR_ROOT=<absolute path>` as a prompt-body line — used by the sub-agent's Git Root Verification snippet (`worktree-dispatch.md` Step 2)
   - `SESSION_BRANCH=<branch name>` as a prompt-body line — used by `worktree-session-head-sync.sh`
   - `SESSION_HEAD=<sha>` as a prompt-body line — used by `worktree-session-head-sync.sh`

   The sub-agent receives a separate working tree and CWD but **NOT a filesystem sandbox** (see `worktree-dispatch.md` Purpose). Path-safety is the agent's responsibility — verify isolation before any write.

   **Reviewer-family exception**: `dso:code-reviewer-*` and `dso:huge-diff-*` agents are intentionally dispatched WITHOUT `isolation: "worktree"` (they must write `reviewer-findings.json` to the shared `$WORKTREE_ARTIFACTS`). For those agents, pass `WORKFLOW_PLUGIN_ARTIFACTS_DIR=$WORKTREE_ARTIFACTS` in the dispatch prompt and omit the `isolation` parameter. See `single-agent-integrate.md` Step 5 / `per-worktree-review-commit.md` for the canonical reviewer dispatch shape.

## Template

```
Read: ${CLAUDE_PLUGIN_ROOT}/agents/<name>.md
subagent_type: "general-purpose"
model: <value of model: from <name>.md frontmatter>
isolation: "worktree"           # required when IS_SESSION_WORKTREE=true; omit for reviewer-family agents
prompt: |
  ORCHESTRATOR_ROOT=<absolute path of session worktree root>
  SESSION_BRANCH=<session branch name>
  SESSION_HEAD=<session HEAD sha>

  {verbatim content of agents/<name>.md}

  Input: <skill-specific inputs as documented by the calling skill>
```

The four-parameter preamble (`isolation:` + `ORCHESTRATOR_ROOT` + `SESSION_BRANCH` + `SESSION_HEAD`) is the contract the sub-agent's Git Root Verification snippet and `worktree-session-head-sync.sh` rely on. If your calling skill does not need the agent to write code, you may omit `isolation: "worktree"` (read-only classifiers, reviewers); see Rule 5 above for the reviewer-family exception.

## Where applied

This pattern applies anywhere a skill dispatches a `dso:*` named agent. Calling skills should write a one-line reference (e.g., "Dispatch `dso:intent-search` per `skills/shared/prompts/named-agent-dispatch.md`") and supply the skill-specific inputs, not restate the dispatch rules.
