---
id: w21-tr4q
status: open
deps: []
links: []
created: 2026-03-19T02:09:25Z
type: bug
priority: 3
assignee: Joe Oakhart
jira_key: DIG-66
---
# validate.sh plugin check fails: make test-plugin target missing from Makefile

validate.sh --ci reports plugin: FAIL because it calls 'make test-plugin' but no such target exists in the Makefile.

Pre-existing issue (no code changes in worktree at time of discovery). All other validate.sh categories pass.

To fix: either add a test-plugin Makefile target (e.g., pointing to bash tests/run-plugin.sh) or update validate.sh plugin check to use an existing target.

