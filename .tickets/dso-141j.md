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

Configure all required GitHub repo variables and secrets for the Jira bridge. Prompt the user for each value with explanation of what it is and where to find it. Validate inputs where possible (URL format, non-empty). AC: All required secrets/vars are set; gh secret list and gh variable list confirm; bridge workflow can authenticate to Jira.

**GitHub Repository Variables** (set via `gh variable set`):
- JIRA_URL — Base URL of the Jira instance
- JIRA_USER — Jira account email address
- ACLI_VERSION, ACLI_SHA256, BRIDGE_BOT_LOGIN, BRIDGE_BOT_NAME, BRIDGE_BOT_EMAIL, BRIDGE_ENV_ID

**GitHub Repository Secrets** (set via `gh secret set`):
- JIRA_API_TOKEN — Only this value is a secret; ACLI expects it as an environment variable at runtime

**Workflow fix required**: Both `inbound-bridge.yml` and `outbound-bridge.yml` currently reference `secrets.JIRA_URL` and `secrets.JIRA_USER` — these must be changed to `vars.JIRA_URL` and `vars.JIRA_USER` since the user has configured them as repository variables, not secrets. `secrets.JIRA_API_TOKEN` remains correct.

**Setup/template alignment**: After fixing the workflows, verify that any CI templates or examples used during `/dso:project-setup` reflect the correct vars vs secrets distinction.

---
## Clarifications (from sprint orchestrator)

Q1: How are JIRA_URL, JIRA_USER, and JIRA_API_TOKEN configured in GitHub?
A1: JIRA_URL and JIRA_USER are Repository Variables. JIRA_API_TOKEN is a Repository Secret. The bridge workflows must use `vars.JIRA_URL`, `vars.JIRA_USER`, and `secrets.JIRA_API_TOKEN` respectively.

Q2: Should changes be reflected in CI templates/examples?
A2: Yes — verify that any CI templates or examples used during setup (dso-setup.sh, project-setup skill) reflect the correct vars vs secrets distinction for the workflows.

**2026-03-23T01:05:53Z**

CHECKPOINT 6/6: Done ✓ — Files: .github/workflows/inbound-bridge.yml, .github/workflows/outbound-bridge.yml, plugins/dso/scripts/dso-setup.sh. Tests: TDD exempt (CI config). AC: all pass.
