---
id: dso-mcq0
status: open
deps: [dso-97xo, dso-141j]
links: []
created: 2026-03-22T22:51:21Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a developer, the inbound bridge cron schedule is re-enabled after infrastructure is ready


## Notes

<!-- note-id: 4fphyfuj -->
<!-- timestamp: 2026-03-22T22:51:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Uncomment the cron schedule in inbound-bridge.yml after tickets branch exists and env vars are configured. Run a manual workflow_dispatch first to verify end-to-end. Then uncomment the cron. AC: inbound-bridge.yml has active cron schedule; scheduled run succeeds; no more recurring CI failures from missing tickets branch. Depends on dso-97xo (branch) and dso-141j (env vars).
