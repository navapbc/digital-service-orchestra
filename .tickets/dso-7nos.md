---
id: dso-7nos
status: open
deps: []
links: []
created: 2026-03-23T01:33:00Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Automate ACLI configuration

## Context
The Jira bridge workflows (inbound-bridge.yml, outbound-bridge.yml) require ACLI_VERSION and ACLI_SHA256 GitHub repository variables to be set. Currently there is no automated way to determine the correct version and SHA256 hash — the process requires manual lookup and configuration. The inbound bridge cron fails at the "Validate ACLI version before download" step because these values are not configured.

## Success Criteria
1. The bridge workflow automatically computes and logs the SHA256 hash of the downloaded ACLI artifact on first download, so the operator can capture it from CI output and set ACLI_SHA256.
2. A setup script or guided prompt determines the correct ACLI version from the local brew installation or a known release channel and configures ACLI_VERSION and ACLI_SHA256 as GitHub repository variables.
3. After configuration, the inbound bridge workflow runs end-to-end successfully (checkout tickets branch, download ACLI, verify checksum, run bridge).
4. The ACLI configuration process is documented and integrated into /dso:project-setup.

## Approach
Phase 1: Modify the bridge workflow's checksum verification step to compute and log the SHA256 when ACLI_SHA256 is not set (warn instead of fail). This allows the operator to run the workflow once, capture the hash from logs, and set it.
Phase 2: Add ACLI version/hash configuration to the project setup guided prompts.

## Notes
Originally tracked as bug dso-7nos (ACLI_VERSION unset). Upgraded to epic per user request to automate the full configuration lifecycle.
