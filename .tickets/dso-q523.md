---
id: dso-q523
status: open
deps: []
links: []
created: 2026-03-17T23:47:32Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# validate.sh hardcodes app/ directory — should pull project-specific paths from config


## Notes

**2026-03-17T23:47:39Z**

validate.sh line 611 does 'cd app/' which fails when run from the DSO plugin repo itself (no app/ dir). It should pull the app directory from workflow-config.conf (e.g., paths.app_dir) instead of hardcoding 'app/'. Similarly, commands like make format-check, make lint, make test-unit-only should use the config keys commands.test, commands.lint, commands.format_check from workflow-config.conf. Error: 'cd: /Users/joeoakhart/digital-service-orchestra/app: No such file or directory'
