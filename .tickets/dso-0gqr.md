---
id: dso-0gqr
status: open
deps: []
links: []
created: 2026-03-18T16:25:29Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Fix: validate-phase.sh should skip or fail gracefully when commands.lint_fix is not configured


## Notes

**2026-03-18T16:25:35Z**

When commands.lint_fix is not configured in workflow-config.conf, validate-phase.sh post-batch exits 2 with 'ERROR: commands.lint_fix not configured'. It should either skip the lint_fix step gracefully or treat an unconfigured command as a pass (not an error), since many projects don't have a separate lint-fix command.
