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

**2026-03-23T04:39:18Z**

Design decision: The Inbound Bridge workflow checks out ref:tickets — not main. This means all code (including bridge scripts and workflow changes) must be present on the tickets branch. Currently achieved by pushing main → tickets to sync. Long-term, the workflow should be restructured to checkout main for code and only use the tickets branch for .tickets-tracker/ data — this avoids coupling code deployment to the tickets branch sync cycle.

## Decision Log — ACLI Migration to Go Binary (2026-03-23)

### Summary
Migrated bridge workflows from legacy Java ACLI (zip/jar from bobswift.atlassian.net) to Go ACLI v1.3+ (tar.gz binary from acli.atlassian.com). Required 6 iterative fix commits to resolve cascading issues.

### Changes Made

| Commit | Change | Root Cause |
|--------|--------|------------|
| 56a55e6 | Download URL → acli.atlassian.com tar.gz, extract via tar, direct binary symlink | ACLI migrated from Java to Go; old URLs return invalid files |
| bc822f0 | Add `--strip-components=1` to tar extraction | tar.gz contains version-prefixed directory wrapping the binary |
| 4c6ef71 | Add `AcliClient` class, migrate functions to Go CLI syntax | bridge-inbound.py expects class interface; old `--action` syntax replaced with `jira workitem` subcommands |
| 91044fb | Add `acli jira auth login` step to workflows | Go ACLI requires explicit auth (no env var auto-detection like Java ACLI) |
| 02fd8de | Remove `acli jira project list` from get_server_info | Redundant connectivity check failed because ACLI auth is per-process; Jira Cloud is always UTC |
| 07a7550 | Add stderr logging to `_run_acli` | CalledProcessError only showed exit code, not the actual ACLI error message |
| 772549a | Fix JQL date format: `%Y-%m-%dT%H:%M:%SZ` → `%Y-%m-%d %H:%M` | Jira JQL rejects ISO 8601 T-separator and Z-suffix |

### Key Architectural Decisions

1. **Auth via workflow step, not Python code**: ACLI Go stores auth in a config file after `acli auth login`. The workflow runs auth once; all subsequent ACLI calls in the same job inherit it. The Python `AcliClient` no longer injects credentials into subprocess env.

2. **search_issues pagination**: ACLI Go has no `--offset` flag. Uses `--paginate` to fetch all results in one call, then caches and slices by `start_at`/`max_results` to satisfy the bridge's pagination loop contract.

3. **get_server_info returns static UTC**: Jira Cloud timestamps are always UTC. The legacy Java ACLI needed a JVM timezone flag; the Go binary has no such issue. No API call needed.

4. **tickets branch must sync from main**: Bridge workflows run from `ref:tickets`. Code changes on main must be pushed to tickets (`git push origin main:tickets`) before they take effect.

### GitHub Variables Configured

| Variable | Value | Type |
|----------|-------|------|
| ACLI_VERSION | 1.3.14-stable | Repository variable |
| ACLI_SHA256 | 2c76293e9ba9ce6a233756b13e9c3eea1fc3fce992fc0ccefe8c32f6dbf36f29 | Repository variable |
| JIRA_API_TOKEN | (refreshed — was expired) | Repository secret |

### Remaining Work (this epic)
- SC2: Automate version/hash discovery via setup script (currently manual)
- SC4: Integrate ACLI configuration into /dso:project-setup
- Design: Restructure workflow to checkout main for code (decouple from tickets branch sync)
