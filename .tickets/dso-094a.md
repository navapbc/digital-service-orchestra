---
id: dso-094a
status: closed
deps: []
links: []
created: 2026-03-19T18:21:58Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-65
parent: dso-9xnr
---
# fix: agent-batch-lifecycle.sh cleanup-discoveries crashes — get_artifacts_dir not found when CLAUDE_PLUGIN_ROOT points to main repo instead of plugin dir


## Notes

<!-- note-id: nq3xsv04 -->
<!-- timestamp: 2026-03-20T23:50:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: applied defensive plugin.json validation guard to cmd_cleanup_discoveries in plugins/dso/scripts/agent-batch-lifecycle.sh; added regression test in tests/scripts/test-lifecycle-portability.sh
