---
id: dso-6hb0
status: in_progress
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

### Context from ACLI migration (2026-03-23)
- ACLI v1.3+ is a Go binary, auth via `acli jira auth login --site --email --token`
- Required GitHub vars: JIRA_URL, JIRA_USER, ACLI_VERSION, ACLI_SHA256, BRIDGE_BOT_LOGIN, BRIDGE_BOT_NAME, BRIDGE_BOT_EMAIL, BRIDGE_ENV_ID
- Required GitHub secret: JIRA_API_TOKEN
- ACLI_SHA256 for linux/amd64 tar.gz can be sourced from brew formula or computed on first CI run
- tickets branch must exist on remote before bridge can run

## ACCEPTANCE CRITERIA

- [ ] /dso:project-setup skill file contains a Jira bridge configuration phase
  Verify: grep -q 'jira\|bridge' plugins/dso/skills/project-setup/SKILL.md
- [ ] Bridge setup phase is skippable (user can decline)
  Verify: grep -qi 'skip\|optional\|decline' plugins/dso/skills/project-setup/SKILL.md
- [ ] Setup prompts for required GitHub variables and secrets
  Verify: grep -q 'JIRA_URL\|JIRA_API_TOKEN\|ACLI_VERSION' plugins/dso/skills/project-setup/SKILL.md
- [ ] Setup includes ACLI auth validation step
  Verify: grep -q 'auth\|login\|connectivity' plugins/dso/skills/project-setup/SKILL.md

TDD Requirement: TDD exemption — Criterion #3 (skill file modification only): this task modifies a skill definition Markdown file with no conditional logic requiring unit tests.

**2026-03-23T05:05:12Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T05:05:16Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T05:05:19Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-23T05:06:44Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T05:06:44Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-23T05:06:44Z**

CHECKPOINT 6/6: Done ✓
