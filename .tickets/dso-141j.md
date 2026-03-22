---
id: dso-141j
status: open
deps: []
links: []
created: 2026-03-22T22:51:10Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-24kl
---
# As a developer, Jira bridge environment variables are configured with guided prompts


## Notes

<!-- note-id: pqf1ct6a -->
<!-- timestamp: 2026-03-22T22:51:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Configure all required GitHub repo variables and secrets for the Jira bridge: JIRA_URL, JIRA_USER, JIRA_API_TOKEN (secrets), ACLI_VERSION, ACLI_SHA256, BRIDGE_BOT_LOGIN, BRIDGE_BOT_NAME, BRIDGE_BOT_EMAIL, BRIDGE_ENV_ID (vars). Prompt the user for each value with explanation of what it is and where to find it. Validate inputs where possible (URL format, non-empty). AC: All required secrets/vars are set; gh secret list and gh variable list confirm; bridge workflow can authenticate to Jira.
