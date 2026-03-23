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

NOTE: The cron was already re-enabled in dso-97xo and env vars configured in dso-141j. This story's remaining work is to verify end-to-end by triggering a manual workflow_dispatch run and confirming it succeeds. If the workflow has already been verified to work, this story can be closed.

## ACCEPTANCE CRITERIA

- [ ] `inbound-bridge.yml` has an active (uncommented) cron schedule
  Verify: grep -q '^\s*- cron:' .github/workflows/inbound-bridge.yml
- [ ] Manual workflow_dispatch trigger succeeds (or recent successful run exists)
  Verify: gh run list --workflow="Inbound Bridge" --limit=1 --json status,conclusion --jq '.[0].conclusion' 2>/dev/null || echo "no runs yet"
- [ ] `tickets` branch exists on remote
  Verify: git ls-remote --heads origin tickets | grep -q tickets

TDD Requirement: TDD exemption — Criterion #3 (verification/infrastructure only): this story verifies existing CI infrastructure configuration with no new code changes.

**2026-03-23T01:29:33Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T01:29:45Z**

CHECKPOINT 2/6: Code patterns understood ✓ — cron active at line 8 ('*/30 * * * *'), workflow_dispatch enabled, tickets branch confirmed on remote

**2026-03-23T01:31:57Z**

CHECKPOINT 3/6: Tests written (none required) ✓ — TDD exemption applies (verification/infrastructure only)

**2026-03-23T01:32:05Z**

CHECKPOINT 4/6: Implementation complete ✓ — Verification findings: (1) cron '*/30 * * * *' is active at line 8 of inbound-bridge.yml; (2) tickets branch exists on remote (SHA: 3358a05...); (3) triggered workflow_dispatch run 23417598754 — checkout succeeded but failed at ACLI_VERSION not set (env var from dso-141j). Previously all runs failed at git fetch (tickets branch was missing). Now that tickets branch exists, the workflow advances further. ACLI_VERSION env var must be configured to get a successful end-to-end run.

**2026-03-23T01:32:48Z**

CHECKPOINT 5/6: Validation passed ✓ — AC Results: AC1 PASS (cron active), AC2 FAIL (workflow_dispatch returns 'failure' — blocked by ACLI_VERSION env var not set, owned by dso-141j), AC3 PASS (tickets branch on remote). Note: workflow now advances past checkout step (tickets branch exists) but fails at ACLI validation. This is a dependency on dso-141j completing env var configuration.

**2026-03-23T01:33:06Z**

CHECKPOINT 6/6: Done ✓ — Story verification complete. Summary: (1) cron schedule active ✓, (2) tickets branch on remote ✓, (3) workflow_dispatch triggered — progresses past checkout but fails at ACLI_VERSION env var (dependency on dso-141j). Created dso-7nos to track ACLI_VERSION env var completion.

**2026-03-23T01:48:36Z**

CHECKPOINT 5/6: Partial — AC1 pass (cron active), AC3 pass (tickets branch exists). AC2 fail — workflow_dispatch runs but fails at ACLI_VERSION unset. Blocked by dso-7nos (ACLI env var config). Reverted to open.

**2026-03-23T03:45:41Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T03:45:50Z**

CHECKPOINT 2/6: Code patterns understood ✓ — cron active in inbound-bridge.yml, tickets branch confirmed on remote, AC2 still dependent on ACLI_VERSION env var config

**2026-03-23T03:45:57Z**

CHECKPOINT 3/6: Tests written (none required) ✓ — TDD exemption applies (verification/infrastructure only)

**2026-03-23T03:46:13Z**

CHECKPOINT 4/6: Re-verification complete ✓ — Status change since last attempt: dso-141j is now CLOSED. ACLI_VERSION is now set to '1.3.14-stable' (previously unset). However ACLI_SHA256 is still empty string. Most recent run (23420219253, 2026-03-23T03:31:20Z) fails at 'Verify ACLI checksum' step with: 'ACLI_VERSION is pinned to 1.3.14-stable but ACLI_SHA256 is not set.' Dependency on dso-7nos (ACLI SHA256 config) remains.

**2026-03-23T03:46:20Z**

CHECKPOINT 5/6: AC Verification Results — AC1 PASS: cron '*/30 * * * *' active in inbound-bridge.yml; AC2 FAIL: most recent run (23420219253) conclusion=failure — ACLI_SHA256 not set (ACLI_VERSION now set to 1.3.14-stable, progress since last check, but SHA256 still missing, tracked by dso-7nos); AC3 PASS: tickets branch exists on remote. No change in overall pass/fail status from previous attempt; dependency on dso-7nos still blocks AC2.

**2026-03-23T03:46:25Z**

CHECKPOINT 6/6: Done ✓ — Re-verification complete. Summary: AC1 PASS (cron active), AC3 PASS (tickets branch on remote), AC2 FAIL (workflow runs but fails at ACLI_SHA256 not set). Progress since last attempt: dso-141j closed, ACLI_VERSION now pinned to 1.3.14-stable — workflow now fails at SHA256 verification rather than ACLI_VERSION unset. Remaining blocker: dso-7nos (Automate ACLI configuration — set ACLI_SHA256). Story remains open pending dso-7nos completion.

**2026-03-23T04:04:37Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T04:05:11Z**

CHECKPOINT 2/6: Code patterns understood ✓ — batch 6 (31d7ddb) added ACLI hash logging to inbound-bridge.yml lines 85-100. When ACLI_SHA256 is unset, it computes SHA256 of the downloaded artifact, logs it, and proceeds without blocking. Most recent CI run (23420219253) used headSha e113f2a (batch 4 — before this code). No run yet on the new code (31d7ddb or faac49a). Will trigger workflow_dispatch to test.

**2026-03-23T04:06:26Z**

CHECKPOINT 3/6: Tests written (none required) ✓ — TDD exemption applies (verification/infrastructure only)

**2026-03-23T04:06:36Z**

CHECKPOINT 4/6: Re-verification complete ✓ — Triggered workflow_dispatch run 23420947283 on headSha faac49a (latest main, includes batch 6 ACLI hash logging). Key findings: (1) 'Validate ACLI version before download' PASS — ACLI_VERSION=1.3.14-stable is set; (2) 'Verify ACLI checksum' PASS — ACLI_SHA256 was empty, so new logging code ran successfully, computed and logged hash: ACLI_SHA256=2927eb361034ce4684895e9987d39cc4e6ab33682e631113e1860c165d60f74f; (3) New failure at 'Extract ACLI zip' — downloaded file is not a valid zip ('End-of-central-directory signature not found'). The ACLI download URL format may be returning a JAR directly (or an error page) rather than a zip. This is a new downstream issue, separate from the ACLI_SHA256 blocker.

**2026-03-23T04:06:43Z**

CHECKPOINT 5/6: AC Verification Results — AC1 PASS: cron '*/30 * * * *' active in inbound-bridge.yml; AC2 FAIL: run 23420947283 conclusion=failure — new failure point at 'Extract ACLI zip' (not a valid zip), but progress since last check: 'Verify ACLI checksum' now PASSES (ACLI_SHA256 hash logged: 2927eb361034ce4684895e9987d39cc4e6ab33682e631113e1860c165d60f74f, workflow proceeds without blocking on missing SHA256); AC3 PASS: tickets branch exists on remote. The ACLI_SHA256 blocker from dso-7nos is resolved by the hash logging code — operator can now capture and set the hash. New downstream blocker: invalid zip from ACLI download URL.

**2026-03-23T04:06:49Z**

CHECKPOINT 6/6: Done ✓ — 3rd verification attempt complete. Summary: AC1 PASS (cron active), AC3 PASS (tickets branch on remote), AC2 FAIL (workflow fails at 'Extract ACLI zip' — downloaded file not a valid zip). Progress since 2nd attempt: ACLI hash logging code (batch 6) is live and working — 'Verify ACLI checksum' step now succeeds, logged ACLI_SHA256=2927eb361034ce4684895e9987d39cc4e6ab33682e631113e1860c165d60f74f. The ACLI_SHA256 blocker from dso-7nos is unblocked by this run's output. New blocker: ACLI download returns invalid zip artifact. Story remains open pending resolution of ACLI zip download issue.
