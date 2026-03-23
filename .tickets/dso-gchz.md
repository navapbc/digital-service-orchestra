---
id: dso-gchz
status: open
deps: []
links: []
created: 2026-03-23T04:17:09Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Planning gap: ACLI distribution format and user configuration burden not caught during brainstorm/preplanning

## Summary

Two critical requirements for the Jira bridge workflows were missed during the brainstorm, preplanning, and implementation-plan phases for epic w21-24kl (Ticket system v3 — migration from tk and cutover). These gaps were only discovered during implementation (sprint batch execution), causing multiple failed CI runs and requiring a mid-sprint fix-bug cycle.

## Gap 1: No verified ACLI install command for CI

**What was missed**: The bridge workflows download and install ACLI (Atlassian CLI) in the GitHub Actions runner. The download URLs, artifact format, and installation steps were never validated against the current ACLI distribution. The workflow was written assuming ACLI is a Java zip/jar (legacy format), but ACLI v1.3+ is a Go binary distributed as tar.gz from a different URL (`acli.atlassian.com` instead of `bobswift.atlassian.net`).

**Where it should have been caught**:
- **Epic w21-24kl** (SC5): "validate.sh --ci passes" and "workflows complete using only the new system" — these criteria assume bridge workflows work, but no spec required verifying the ACLI download path.
- **Story dso-141j** (Jira bridge env vars): Focused on GitHub secrets/variables configuration but did not include a requirement to verify the download URL or artifact format.
- **Story dso-97xo** (tickets branch): Created the branch and re-enabled cron but the AC did not require a successful end-to-end workflow run — only "workflow_dispatch passes checkout", which is a partial verification.
- **Story dso-mcq0** (bridge cron verification): AC2 required "scheduled run succeeds" but this was the first story to actually trigger a full workflow run — by which point the download was already broken. The AC was correct but was the first point of discovery rather than a planned validation gate.

**Impact**: 3 failed CI runs (23420219253, 23420947283, 23421020100) before the root cause was identified. Required a /dso:fix-bug cycle mid-sprint to diagnose and fix.

## Gap 2: High user burden for ACLI_VERSION and ACLI_SHA256 configuration

**What was missed**: The workflow requires the user to determine and set two GitHub repository variables: `ACLI_VERSION` (a specific release string) and `ACLI_SHA256` (the SHA256 hash of the downloaded artifact). There is no automated way to discover either value. The user must:
1. Know which ACLI version to pin (not obvious — brew installs a Go binary, CI downloads a tar.gz, and the version string format differs)
2. Obtain the SHA256 of the CI artifact (not the local binary — the tar.gz downloaded by the workflow), which requires either running the workflow once without verification or manually downloading the tar.gz

**Where it should have been caught**:
- **Brainstorm session** (2026-03-19): The Jira bridge stories were created during the brainstorm for w21-24kl. The brainstorm did not include a user experience walkthrough for bridge setup — the focus was on migration correctness and cutover safety.
- **Preplanning** (w21-24kl children): Stories dso-141j and dso-97xo were scoped as configuration tasks, but the done definitions did not require the configuration to be self-service or guided. "Prompt the user for each value" (dso-141j) was specified but "help the user determine the correct value" was not.
- **Implementation-plan**: dso-141j was classified as TRIVIAL by the complexity evaluator, which skipped /dso:implementation-plan entirely. A TRIVIAL classification was reasonable for the file edits, but the user-facing configuration workflow was more complex than the code changes suggested.

**Impact**: Required manual investigation to determine the correct version string, download URL format, and SHA256 hash. The hash logging bootstrap code (added in batch 6) was a mid-sprint workaround. Epic dso-7nos was created to track automating this.

## Root Cause Category

**Planning process gap** — not a code bug. The brainstorm/preplanning/implementation-plan pipeline did not:
1. Require end-to-end validation of external dependency installation paths
2. Assess user configuration burden as a complexity dimension
3. Verify that download URLs and artifact formats match the current version of external tools

## Relevant Specs

- Epic w21-24kl: SC5 (validation), SC9 (commit ticket gate)
- Story dso-141j: "Configure all required GitHub repo variables and secrets... Validate inputs where possible"
- Story dso-97xo: "AC: git ls-remote shows tickets branch; inbound-bridge.yml cron re-enabled; workflow_dispatch passes checkout"
- Story dso-mcq0: "AC: inbound-bridge.yml has active cron schedule; scheduled run succeeds"
- Epic dso-7nos: "Automate ACLI configuration" (created mid-sprint as remediation)

## Fix Applied

Commit 56a55e6: Migrated bridge workflows from Java zip/jar to Go binary tar.gz distribution. Updated download URL to `acli.atlassian.com`, replaced zip extraction with tar, replaced Java wrapper with direct binary symlink. ACLI_SHA256 updated to linux/amd64 tar.gz hash from brew formula.

## Action Items (for retrospective analysis)

1. Analyze whether brainstorm/preplanning should include an "external dependency verification" checklist
2. Analyze whether TRIVIAL complexity classification should consider user-facing configuration burden
3. Analyze whether AC for infrastructure stories should require end-to-end success (not just partial verification like "passes checkout")
