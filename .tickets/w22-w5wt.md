---
id: w22-w5wt
status: open
deps: []
links: []
created: 2026-03-22T15:28:16Z
type: task
priority: 2
assignee: Joe Oakhart
---
# REVIEW-WORKFLOW.md uses CLAUDE_PLUGIN_ROOT without fallback


## Notes

**2026-03-22T15:28:24Z**

REVIEW-WORKFLOW.md has 4 occurrences of 'source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"' (lines 30, 48, 173, 230) without fallback resolution when CLAUDE_PLUGIN_ROOT is unset. Same anti-pattern as dso-u5lt (fixed in COMMIT-WORKFLOW.md). Should add CLAUDE_PLUGIN_ROOT fallback resolution matching the pattern added to COMMIT-WORKFLOW.md: (1) dso.plugin_root from .claude/dso-config.conf, (2) REPO_ROOT/plugins/dso. SAFEGUARD required before editing — REVIEW-WORKFLOW.md is a protected workflow file.
