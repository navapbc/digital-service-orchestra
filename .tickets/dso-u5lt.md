---
id: dso-u5lt
status: open
deps: []
links: []
created: 2026-03-21T00:15:26Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# COMMIT-WORKFLOW.md uses CLAUDE_PLUGIN_ROOT without fallback for unset env var

COMMIT-WORKFLOW.md Step 0 references ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh but CLAUDE_PLUGIN_ROOT is not always set (e.g., when running commit workflow manually or in environments where Claude Code hasn't set it). When unset, the path resolves to /hooks/lib/deps.sh which fails with exit 127. Should fall back to discovering the plugin root from dso-config.conf or git rev-parse.


## Notes

<!-- note-id: s6oxeiia -->
<!-- timestamp: 2026-03-21T00:17:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Also affects compute-diff-hash.sh (line 42: CLAUDE_PLUGIN_ROOT: unbound variable) and capture-review-diff.sh invocation. The issue is pervasive across all scripts that use CLAUDE_PLUGIN_ROOT without fallback — not just COMMIT-WORKFLOW.md.
