---
id: dso-lu5w
status: open
deps: []
links: []
created: 2026-03-22T15:39:41Z
type: bug
priority: 1
assignee: Joe Oakhart
tags: [ci, infrastructure]
---
# Inbound Bridge workflow fails: tickets branch does not exist on remote

The Inbound Bridge GitHub Actions workflow (inbound-bridge.yml) has failed on all 17 runs today (2026-03-22, 07:20–15:09 UTC). The failure occurs at the Checkout step (actions/checkout@v4) which tries to fetch ref 'tickets' — but no 'tickets' branch exists on the remote. git ls-remote --heads origin 'tickets*' returns no results. The workflow runs every 30 minutes on a cron schedule, so failures are accumulating continuously. Root cause: the 'tickets' branch referenced in the workflow (line 36: ref: tickets) has never been created, or was deleted. Fix: create the 'tickets' branch on the remote, or disable the workflow until the Jira bridge infrastructure is ready.

