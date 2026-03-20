---
id: dso-5p5i
status: open
deps: []
links: []
created: 2026-03-20T15:09:36Z
type: task
priority: 3
assignee: Joe Oakhart
---
# Update dso-setup.sh to write dso.plugin_root to .claude/dso-config.conf


## Notes

**2026-03-20T15:09:45Z**

Discovered during dso-tuz0. After shim migration to read from .claude/dso-config.conf, dso-setup.sh still writes to workflow-config.conf (root level). This causes test_setup_dso_tk_help_works in tests/scripts/test-dso-setup.sh to fail. dso-setup.sh is a safeguard file (plugins/dso/scripts/**) requiring user approval to edit. The CONFIG variable at line 131 of dso-setup.sh must change from workflow-config.conf to .claude/dso-config.conf. Also update test_setup_writes_plugin_root and test_setup_is_idempotent tests to check .claude/dso-config.conf instead of workflow-config.conf.
