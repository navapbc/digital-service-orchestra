---
id: dso-zlih
status: closed
deps: []
links: []
created: 2026-03-20T05:22:09Z
type: task
priority: 3
assignee: Joe Oakhart
---
# Update pre-bash-functions.sh to remove CLAUDE_PLUGIN_ROOT/workflow-config.conf lookup


## Notes

**2026-03-20T05:22:16Z**

pre-bash-functions.sh lines 155-159 still use CLAUDE_PLUGIN_ROOT/workflow-config.conf for config file lookup — same anti-pattern fixed in config-paths.sh (dso-6trc). Should be migrated to use read-config.sh resolution (WORKFLOW_CONFIG_FILE or git root .claude/dso-config.conf) consistently. Parent epic: dso-uc2d.
