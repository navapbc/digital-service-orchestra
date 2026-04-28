# Named-Agent Dispatch Pattern

When a skill needs to dispatch a named DSO agent (e.g., `dso:intent-search`, `dso:bot-psychologist`, `dso:scope-drift-reviewer`, the `dso:investigator-*` family), the dispatch follows a uniform pattern. This prompt defines that pattern once so the calling skills can reference it with a one-line link rather than restating it inline.

## Dispatch rules

1. **`dso:<name>` is an agent file identifier, NOT a valid `subagent_type` value.** The Agent tool only accepts built-in subagent types (most commonly `general-purpose`). The `dso:` prefix maps to a file at `${CLAUDE_PLUGIN_ROOT}/agents/<name>.md`.
2. **Read the agent file inline** with the Read tool, then dispatch with `subagent_type: "general-purpose"` and the agent's frontmatter `model:` value. Pass the agent file's content verbatim as the prompt body, followed by your skill-specific input.
3. **Generated agents** (composed from base + delta — `code-reviewer-*`, `investigator-*`) are equivalent to hand-written agents at the file level. Read them the same way.
4. **Inline fallback** when the Agent tool is unavailable (sub-agent context): read the agent file as a reference and execute its instructions directly, applying the calling skill's investigation/dispatch framework rather than nesting another sub-agent dispatch (which is prohibited per CLAUDE.md Critical Rule 17). Defer steps that require Agent-tool capabilities and surface them as `INTERACTIVITY_DEFERRED` in the RESULT.

## Template

```
Read: ${CLAUDE_PLUGIN_ROOT}/agents/<name>.md
subagent_type: "general-purpose"
model: <value of model: from <name>.md frontmatter>
prompt: |
  {verbatim content of agents/<name>.md}

  Input: <skill-specific inputs as documented by the calling skill>
```

## Where applied

This pattern applies anywhere a skill dispatches a `dso:*` named agent. Calling skills should write a one-line reference (e.g., "Dispatch `dso:intent-search` per `skills/shared/prompts/named-agent-dispatch.md`") and supply the skill-specific inputs, not restate the dispatch rules.
