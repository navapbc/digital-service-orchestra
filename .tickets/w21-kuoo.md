---
id: w21-kuoo
status: open
deps: []
links: []
created: 2026-03-19T03:27:02Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# fix: sprint-next-batch.sh fails with 'Could not load epic' when CLAUDE_PLUGIN_ROOT is not set in orchestrator Bash context


## Notes

**2026-03-19T03:27:10Z**

Observed during sprint of dso-ag1b: running `$REPO_ROOT/plugins/dso/scripts/sprint-next-batch.sh <epic-id>` from the orchestrator Bash tool failed with 'Error: Could not load epic'. Root cause: script uses TK="${TK:-${CLAUDE_PLUGIN_ROOT}/scripts/tk}" but CLAUDE_PLUGIN_ROOT was not set in the Bash tool environment. Fix was prefixing the command with CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso". CLAUDE_PLUGIN_ROOT should either be exported by the plugin loader into Bash tool calls, or sprint-next-batch.sh should self-detect its own location (e.g., via BASH_SOURCE).
