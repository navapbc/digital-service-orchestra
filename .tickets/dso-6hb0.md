---
id: dso-6hb0
status: open
deps: [dso-97xo, dso-141j, dso-mcq0]
links: []
created: 2026-03-22T22:51:31Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a new user, the project setup skill guides me through Jira bridge configuration


## Notes

<!-- note-id: rmcf2tgl -->
<!-- timestamp: 2026-03-22T22:51:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Extend /dso:project-setup to include a Jira bridge setup phase that: (1) asks if the user wants to configure Jira integration, (2) guides through creating the tickets branch, (3) prompts for each required secret/variable with descriptions, (4) validates connectivity (test Jira API auth), (5) enables the inbound bridge cron, (6) runs a test sync. This should be skippable — projects without Jira still work. AC: /dso:project-setup on a fresh project offers Jira bridge setup; completing it results in a working bridge; skipping it leaves workflows disabled.
