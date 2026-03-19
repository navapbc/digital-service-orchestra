---
id: dso-p2d3
status: closed
deps: []
links: []
created: 2026-03-17T18:34:12Z
type: epic
priority: 0
assignee: Joe Oakhart
jira_key: DIG-27
---
# Remove plugin testing as a separate step

Plugin testing was incorporated as a separate step during plugin development. Now that the plugin has been migrated to a separate project, we need to remove that step. The dso plugin configures testing commands through a project level confirmation file. This project's configuration file should be configured to run this project's tests.


## Notes

<!-- note-id: kg0jafsd -->
<!-- timestamp: 2026-03-19T00:55:05Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Epic complete: all stories closed, all done definitions verified. Plugin test step removed from validate.sh, workflow-config.conf, COMMIT-WORKFLOW.md, and CI workflow files. All project tests now run via bash tests/run-all.sh through commands.test_unit.
