---
name: validate-work
description: Use when verifying project health after completing work, before closing tasks, or when you need confidence that code, CI, staging deployment, and live environment are all passing. Does not fix issues — only detects and reports them.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:validate-work requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Validate Work

Comprehensive project health verification using parallel sub-agents. Detects issues across local checks, CI, staging deployment, and live environment — but does NOT fix them. Reports a pass/fail summary with actionable details for each failure.

## When to Use

- After completing implementation work, before closing tasks
- After merging branches or deploying to staging
- When CI or staging failures are suspected
- As a final gate before declaring work complete

## When NOT to Use

- To fix issues (use `/dso:debug-everything` instead)
- For initial project setup (use `/dso:onboarding`)
- For ongoing task execution (use `/dso:sprint`)

## Verification Architecture

Five sub-agents across two batches. Batch 1 (4 agents) runs in parallel. Batch 2 (1 agent) is gated on staging deployment health from Batch 1. No commits between batches because this skill is read-only (no files modified).

```
Batch 1 (parallel):  Local ─┐
                      CI ────┤
                      Issues ┼─→ Collect Results ─→ Gate Check
                      Deploy ┘                         │
                                                       ▼
Batch 2 (gated):                              Staging Test
                                              (only if Deploy passed)
```

## Execution

### Step 0: Read Config (/dso:validate-work)

Before launching sub-agents, read all project-specific values from `workflow-config.yaml` via `read-config.sh`.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# CLAUDE_PLUGIN_ROOT is set by the plugin loader; required for locating plugin scripts
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set by the plugin loader}"
PLUGIN_SCRIPTS_DIR="$PLUGIN_ROOT/scripts"
READ_CONFIG="$PLUGIN_SCRIPTS_DIR/read-config.sh"
CONFIG_FILE="$REPO_ROOT/workflow-config.yaml"

# Staging config
STAGING_URL=$("$READ_CONFIG" staging.url "$CONFIG_FILE" 2>/dev/null || true)
STAGING_DEPLOY_CHECK=$("$READ_CONFIG" staging.deploy_check "$CONFIG_FILE" 2>/dev/null || true)
STAGING_TEST=$("$READ_CONFIG" staging.test "$CONFIG_FILE" 2>/dev/null || true)
STAGING_ROUTES=$("$READ_CONFIG" staging.routes "$CONFIG_FILE" 2>/dev/null || echo "/")
STAGING_HEALTH_PATH=$("$READ_CONFIG" staging.health_path "$CONFIG_FILE" 2>/dev/null || echo "/health")

# Commands config
VALIDATE_CMD=$("$READ_CONFIG" commands.validate "$CONFIG_FILE" 2>/dev/null || true)
TEST_E2E_CMD=$("$READ_CONFIG" commands.test_e2e "$CONFIG_FILE" 2>/dev/null || true)
TEST_VISUAL_CMD=$("$READ_CONFIG" commands.test_visual "$CONFIG_FILE" 2>/dev/null || true)
DB_STATUS_CMD=$("$READ_CONFIG" database.status_cmd "$CONFIG_FILE" 2>/dev/null || true)

# CI config
INTEGRATION_WORKFLOW=$("$READ_CONFIG" ci.integration_workflow "$CONFIG_FILE" 2>/dev/null || true)

# Staging relevance classifier script (project-provided, optional)
STAGING_RELEVANCE_SCRIPT=$("$READ_CONFIG" staging.relevance_script "$CONFIG_FILE" 2>/dev/null || true)

# Visual baseline path for pre-check
VISUAL_BASELINE_PATH=$("$READ_CONFIG" visual.baseline_directory "$CONFIG_FILE" 2>/dev/null || true)
```

If `STAGING_URL` is empty or absent, set `stagingConfigured = false`. All staging sub-agents (Sub-Agent 4 and Sub-Agent 5) will be SKIPPED with the message: "SKIPPED (staging not configured)".

### Step 0b: Check for Domain Scope File (/dso:validate-work)

Before launching sub-agents, check for a scope file that limits which domains
to verify. This is written by callers (e.g., `/dso:debug-everything`) that have
already verified some domains.

1. Look for `/tmp/validate-work-scope-*.json` files. If multiple exist, use the
   most recent one (highest timestamp in filename).
2. **If a fresh scope file exists** (check `generatedAt` < 1 hour old):
   - Read the `domains` array to determine which domains to check.
   - Valid domain values: `local`, `ci`, `issues`, `deploy`, `staging_test`.
   - Log: `"Loaded domain scope from <file> — checking only: <domain list>.
     Skipped domains (verified by caller): <skipped list>."`
   - **Important**: `staging_test` (Sub-Agent 5) always runs regardless of scope
     — it is the only validation that catches live environment regressions.
   - Set `scopedDomains` to the list from the file. For any domain NOT in the
     list, skip its sub-agent and mark it as `SKIPPED (verified by caller)` in
     the final report.
3. **If no scope file exists or all files are stale**: run all sub-agents as
   normal. Set `scopedDomains = all`. This is the backward-compatible path.

### Step 0c: Check Staging Relevance (/dso:validate-work)

Skip this step entirely if `stagingConfigured = false` (staging URL absent).

Before launching staging-related sub-agents, determine whether the current
changes affect the deployed application. Changes that only impact local
development tooling (skills, agent guidance, shell scripts, docs, tracker
metadata) do not need staging verification.

1. Compute the changed files for the current branch:
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   CHANGED_FILES=$(git diff --name-only main...HEAD 2>/dev/null || git diff --name-only HEAD~1...HEAD 2>/dev/null || echo "")
   ```

2. If `CHANGED_FILES` is empty, set `stagingRelevant = false` and skip to Step 1 (no staging test needed — nothing was deployed).

3. **If `STAGING_RELEVANCE_SCRIPT` is set** (from `staging.relevance_script` config key):
   ```bash
   echo "$CHANGED_FILES" | bash "$REPO_ROOT/$STAGING_RELEVANCE_SCRIPT"
   STAGING_RELEVANCE=$?
   ```
   Interpret exit codes:
   - **Exit 0**: at least one file affects the deployed application → `stagingRelevant = true`
   - **Exit 1**: all changed files are non-deployment → `stagingRelevant = false`
   - **Exit 2**: no files reached the classifier → treat as `stagingRelevant = false`

   **If `STAGING_RELEVANCE_SCRIPT` is absent**: set `stagingRelevant = true` and proceed with all staging sub-agents. (Conservative default: without a classifier, assume changes may affect staging.)

4. Set `stagingRelevant = true/false` based on the result. Pass this flag to
   Step 1 and Step 3 to control sub-agent dispatch.

### Step 1: Launch Batch 1 (4 parallel sub-agents) (/dso:validate-work)

**Note**: If `scopedDomains` was set in Step 0b, only launch sub-agents for
domains in the scoped list. Skip the others and record them as
`SKIPPED (verified by caller)` in the report.

**Note**: If `stagingConfigured = false`, skip Sub-Agent 4 and mark it as
`SKIPPED (staging not configured)` in the report.

**Note**: If `stagingRelevant = false` (from Step 0c), skip Sub-Agent 4
(Staging Deployment Check). Mark it as
`SKIPPED (non-deployment changes only)` in the report.

#### Sub-Agent 1: Local Validation (model: haiku)  # Tier 1: runs validate.sh and parses structured PASS/FAIL output; no ambiguous interpretation required

**Subagent**: `subagent_type="general-purpose"`, `model="haiku"`

Read prompt from: `$PLUGIN_ROOT/skills/validate-work/prompts/local-validation.md`

**Prepend a `### Config Values` block** to the prompt:
```
### Config Values
VALIDATE_CMD=<value from commands.validate, or ABSENT>
TEST_E2E_CMD=<value from commands.test_e2e, or ABSENT>
TEST_VISUAL_CMD=<value from commands.test_visual, or ABSENT>
DB_STATUS_CMD=<value from database.status_cmd, or ABSENT>
```

#### Sub-Agent 2: CI Status (model: haiku)  # Tier 1: executes ci-status.sh and extracts fixed JSON fields from gh run list; purely mechanical output parsing

**Subagent**: `subagent_type="general-purpose"`, `model="haiku"`

Read prompt from: `$PLUGIN_ROOT/skills/validate-work/prompts/ci-status.md`

**Prepend a `### Config Values` block** to the prompt:
```
### Config Values
PLUGIN_SCRIPTS_DIR=<absolute path to plugin scripts directory>
INTEGRATION_WORKFLOW=<value from ci.integration_workflow, or ABSENT>
```

#### Sub-Agent 3: Issue Health (model: haiku)  # Tier 1: runs validate-issues.sh and ticket CLI commands that emit structured counts; no judgment or synthesis needed

**Subagent**: `subagent_type="general-purpose"`, `model="haiku"`

Read prompt from: `$PLUGIN_ROOT/skills/validate-work/prompts/tickets-health.md`

**Prepend a `### Config Values` block** to the prompt:
```
### Config Values
PLUGIN_SCRIPTS_DIR=<absolute path to plugin scripts directory>
```

#### Sub-Agent 4: Staging Deployment Check (model: sonnet)  # Tier 2: must execute conditional retry polling (up to 10 polls), parse deploy script output, pattern-match log lines for errors, and correctly follow the "run curl even if script fails" branch — haiku reliably drops these conditional paths

**Subagent**: `subagent_type="general-purpose"`, `model="sonnet"`

**Skip if `stagingConfigured = false` or `stagingRelevant = false`** (see above).

Read prompt from: `$PLUGIN_ROOT/skills/validate-work/prompts/staging-deployment-check.md`

**Replace config placeholders** in the prompt before dispatching:
- `{STAGING_URL}` → value of `STAGING_URL`
- `{STAGING_DEPLOY_CHECK}` → value of `STAGING_DEPLOY_CHECK` (or `ABSENT` if not set)
- `{STAGING_HEALTH_PATH}` → value of `STAGING_HEALTH_PATH` (default: `/health`)

When `STAGING_DEPLOY_CHECK` is absent, Sub-Agent 4 uses Mode D (generic HTTP health check) as described in the prompt.

### Step 2: Collect Results and Gate (/dso:validate-work)

After all Batch 1 sub-agents complete:

- **If Sub-Agent 4 reports**: environment Ready AND health endpoint PASS → proceed to Step 2b
- **If Sub-Agent 4 reports**: DEPLOY=NOT_READY after polling → skip staging test, mark as SKIPPED with reason: "Staging deployment not ready after 10 polls (5 min). Verify environment health manually."
- **If Sub-Agent 4 was SKIPPED** (staging not configured or non-deployment changes) → skip Sub-Agent 5 as well; mark both as SKIPPED with the same reason
- **If Sub-Agent 4 reports**: health endpoint UNREACHABLE → skip staging test, mark as SKIPPED with reason: "Staging site unreachable. Check environment health manually."

### Step 2b: Visual Regression Pre-Check (/dso:validate-work)

Before launching the browser-based staging test, check the visual regression
baseline state. Skip this step if `TEST_VISUAL_CMD` is absent.

Visual tests only run on CI (Linux) — they always skip on macOS
because font rendering differs ~11%, causing false pixel-diff failures.

```bash
bash ".claude/scripts/dso check-visual-baseline.sh"
```

**If on macOS** (the common local case): Report `VISUAL_REGRESSION=skipped_macos`.
This is expected, not a bug. Baselines are generated and compared on CI (Linux).

**If on Linux and visual command passes**: Visual regression baselines confirm
the UI matches expectations. Pass `VISUAL_REGRESSION=pass` as context.

**If on Linux and visual command fails**: Pass the diff output as context.
Pass `VISUAL_REGRESSION=fail` with the diff details.

**If baselines don't exist**: Pass `VISUAL_REGRESSION=no_baselines`. Recommend
running the visual baseline workflow to generate them.

> **Note**: The staging-environment-test.md prompt uses a tiered approach
> (deterministic pre-checks, `@playwright/cli run-code` batching, API-driven checks where
> possible). See `/dso:playwright-debug` for the 3-tier process it follows.

### Step 3: Launch Batch 2 (1 sub-agent, gated) (/dso:validate-work)

**Pre-check**: If `stagingConfigured = false` or `stagingRelevant = false` (from
Step 0 or 0c), skip this entire step. Mark Sub-Agent 5 as
`SKIPPED (staging not configured)` or `SKIPPED (non-deployment changes only)`
in the report and proceed directly to Step 4 (Final Report).

#### Sub-Agent 5: Staging Environment Test (model: sonnet)  # Tier 2: multi-phase validation with tiered fallbacks, conditional phase skipping based on Tier 0 results, and judgment for inconclusive vs. fail determination

**Subagent**: `subagent_type="general-purpose"`, `model="sonnet"`

This sub-agent performs validation of the live staging environment.

Read prompt from: `$PLUGIN_ROOT/skills/validate-work/prompts/staging-environment-test.md`

**Replace config placeholders** in the prompt before dispatching:
- `{STAGING_URL}` → value of `STAGING_URL`
- `{STAGING_TEST}` → value of `STAGING_TEST` (or `ABSENT` if not set)
- `{STAGING_ROUTES}` → value of `STAGING_ROUTES` (default: `/`)
- `{STAGING_HEALTH_PATH}` → value of `STAGING_HEALTH_PATH` (default: `/health`)

When `STAGING_TEST` is absent, Sub-Agent 5 uses Mode D (generic tiered validation)
as described in the prompt.

**Append visual regression context** to the sub-agent prompt based on Step 2b results:
```
### Visual Regression Context
VISUAL_REGRESSION={pass|fail|skipped_macos|no_baselines|skipped}
{if fail: include diff output identifying changed elements}
{if pass: "Visual regression baselines pass — skip full-page screenshots, focus on staging-specific behavior."}
{if skipped_macos: "Visual tests skip on macOS (font rendering differs ~11%). Baselines are generated and compared on CI (Linux). This is expected — not a bug."}
{if no_baselines: "No visual baselines exist. Run the visual baseline workflow to generate them."}
{if skipped: "Visual regression test command not configured — skipped."}
```

**Append change scope context** to the sub-agent prompt when called from `/dso:sprint` (or any caller that provides a `CHANGED_FILES` list):

Check if the current invocation context contains a `### Sprint Change Scope` block (written by `/dso:sprint` Phase 7 Step 1). If present, append it verbatim to the sub-agent prompt:
```
### Change Scope
CHANGED_FILES:
<list of files from the Sprint Change Scope block, one per line>
```

If no `CHANGED_FILES` context was provided by the caller, omit the `### Change Scope` block entirely — the sub-agent will then default to full browser automation (safe fallback).

### Step 4: Compile Final Report (/dso:validate-work)

Aggregate all sub-agent results into a single report:

```
## Validation Report

### Summary
| Domain          | Status            | Details                          |
|-----------------|-------------------|----------------------------------|
| Local checks    | PASS/WARN/FAIL    | format, lint, types, tests, DB   |
| CI workflow     | PASS/FAIL         | workflow URL, duration            |
| Issue health    | PASS/FAIL         | issue count, blocked count       |
| Staging deploy  | PASS/FAIL/SKIPPED | env health, endpoint status      |
| Staging test    | PASS/FAIL/SKIPPED | phase results                    |

### Overall: PASS / WARN / FAIL (X of N domains passing)

**WARN** means static checks pass but E2E tests were skipped locally — regressions
may only be caught by CI (adds ~15-30 min latency to regression discovery).

### Failures / Warnings (if any)
[Details for each failing or warning domain, including evidence from sub-agents]

If Local checks = WARN:
  - Include the full WARNING block from the local-validation sub-agent
  - Include the port conflict pre-check result
  - Explicitly call out: "E2E was silently skipped. Run the project's E2E command
    to verify locally, or push and wait for CI to run the full E2E suite."

### Recommended Actions
[For each failure or warning, suggest which skill or command to run — do NOT run them]
```

**Overall status rules:**
- PASS: all domains PASS (local checks must be PASS, not just WARN). Domains
  skipped due to non-deployment changes (Step 0c) or staging not configured
  (Step 0) count as PASS — they are correctly excluded, not missing.
- WARN: no domain FAIL, but at least one domain is WARN (typically Local checks with E2E skip)
- FAIL: any domain FAIL

## Recommended Actions Reference

| Failure / Warning Domain | Recommended Action |
|--------------------------|-------------------|
| Local checks FAIL | Run `/dso:debug-everything` |
| Local checks WARN (E2E skipped) | Run the project's E2E command manually to close the gap, or push and wait for CI E2E results |
| Local checks WARN (port conflict) | Identify and stop the conflicting process on the E2E port, then re-run the E2E command |
| CI workflow fails | Check failed job logs via `gh run view`, fix locally, re-push |
| Issue health fails | Run `/dso:tickets-health` |
| Staging deploy not ready | Deployment still in progress. Wait and re-run `/dso:validate-work`, or check environment console manually |
| Staging deploy unhealthy | Check environment health, review deployment logs |
| Staging test fails | Run `/staging-test` to create bugs with TDD criteria and screenshot evidence |
| Staging test inconclusive | Wait 5 minutes and re-run `/dso:validate-work`, or run `/staging-test` for targeted investigation |
| Playwright cannot reach staging | Site unreachable despite health endpoint passing. Check environment health manually |
| Database not running | Run the project's database start command (see `database.ensure_cmd` in config) |
| Unpushed commits | Push with `git push` before expecting CI/staging updates |

## Read-Only Enforcement

All sub-agents dispatched by this skill are read-only. The orchestrator MUST NOT instruct sub-agents to fix any issue it discovers, and sub-agents MUST NOT use modifying tools or commands regardless of how the situation is framed.

**Sub-agents must STOP and report — never fix. Prohibited tools and commands for all sub-agents:**
- **Edit** — forbidden. Sub-agents must not edit any file.
- **Write** — forbidden. Sub-agents must not write any file.
- **Bash with modifying commands** — forbidden:
  - `git commit`, `git push`, `git add`, `git checkout`, `git reset`
  - `.claude/scripts/dso ticket transition`, `.claude/scripts/dso ticket create`
  - `make`, `pip install`, `npm install`, `poetry install`
  - Any command that changes system state

Each prompt file in `prompts/` contains a `## READ-ONLY ENFORCEMENT` section with this hard-stop language. If a sub-agent rationalizes fixing a problem ("it's a quick fix", "it will save time"), that is a violation — it must TERMINATE its turn and report the finding instead.

## Important Constraints

- **Never fix issues** — this skill is verification-only
- **Never create issues** — only report findings for the user to act on
- **Never modify code** — read-only operations only
- **Max sub-agents bounded by `orchestration.max_agents`** — respects the project's concurrency limit (see `dso-config.conf`; 4 in Batch 1, 1 in Batch 2)
- **No commits between batches** — read-only skill, nothing to commit (Orchestrator Checkpoint Protocol acknowledged but N/A)
- **Gate staging test on deploy health** — skip browser tests if staging is down
- **Sub-agent model selection** — haiku for script-running sub-agents, sonnet for staging-test which requires judgment
- **All sub-agents run `pwd` first** — per CLAUDE.md requirement
- **Config-driven** — all project-specific values come from `workflow-config.yaml` via `read-config.sh`
