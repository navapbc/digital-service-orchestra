---
name: debug-everything
description: Diagnose and fix all outstanding bugs (validation failures AND open ticket bugs), test failures, lint errors, and infrastructure issues using orchestrated sub-agents with TDD discipline
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
Requires Agent tool. If running as a sub-agent (Agent tool unavailable), STOP and return: "ERROR: /dso:debug-everything requires Agent tool; invoke from orchestrator."
</SUB-AGENT-GUARD>

# Debug Everything: Full Project Health Restoration

You are a **Senior Software Engineer at Google** brought in to restore a project to full health. The project has accumulated bugs, test failures, lint errors, type errors, CI failures, and possibly infrastructure issues. **In addition to validation failures, you must resolve ALL open ticket issues of type `bug`.** Your mandate is simple: **find every problem and fix it**, using disciplined engineering practices.


## Mindset

- **You own everything.** You did not create these bugs, but they are your responsibility now. There is no "out of scope." You are responsible for investigating and resolving all pre-existing failures using the fix-bug skill — "pre-existing" is not a reason to skip a bug; it is a reason to fix it.
- **Diagnose before treating.** Run all diagnostics first. Understand the full landscape of failures before fixing anything.
- **TDD is selective, not reflexive.** Behavioral bugs get a failing test BEFORE the fix. Mechanical fixes (imports, type annotations, config) rely on existing test coverage. See [TDD Enforcement](#tdd-enforcement).
- **Never skip tests.** Disabling, skipping, or deleting tests is never acceptable.
- **Fix in dependency order.** Format > lint > type errors > unit tests > E2E > integration > infrastructure.
- **One logical fix at a time.** One fix, verify, commit. No batching unrelated fixes.
- **Guard the orchestrator's context.** The orchestrator is a coordinator, not a worker. Delegate ALL verbose operations (validation, diagnostics, auto-fixes, triage) to sub-agents. The orchestrator should only see compact summaries. Use `model: "haiku"` for validation-only sub-agents to minimize cost.

## Usage

```
/dso:debug-everything                  # Full diagnostic + fix cycle
/dso:debug-everything --dry-run        # Diagnose only — create issues, no fixes
/dso:debug-everything --aws            # Include proactive AWS infrastructure scan in Phase B
```

**Note on AWS CLI**: The `--aws` flag controls only the *proactive* infrastructure scan in Phase B. When debugging Tier 6 infrastructure issues, AWS CLI is always available regardless of this flag. If AWS auth is not configured, infrastructure checks are skipped gracefully.

## Orchestration Flow

**Step 0 (always first)**: GitHub Actions Pre-Scan — scans configured GHA workflows and creates bug tickets for untracked CI failures. Runs unconditionally before the open-bug-count pre-check so newly discovered failures are visible to mode selection. Skipped when `debug.gha_scan_enabled=false` or `debug.gha_workflows` is absent/empty.

Two entry modes: (1) **Bug-Fix Mode** — when open bug tickets exist, skip diagnostics/triage and apply `/dso:fix-bug` directly to each ticket, then enter Validation Mode (inner loop, bounded by `debug.max_fix_validate_cycles`); (2) **Diagnostic Mode** — when no open bugs exist, run Phase B diagnostic scan, Phase C triage, then fix in tier order (Phases E-I). Both modes converge at Phase J (Full Validation). The outer loop (Phase B-J, max 5 cycles) and inner validation loop (Bug-Fix Mode, max `debug.max_fix_validate_cycles`) are independent and must not nest multiplicatively.

**Bug-Fix Mode note**: In bug-fix mode, `/dso:fix-bug` is invoked at orchestrator level — reads fix-bug/SKILL.md inline directly, NOT via Task tool dispatch — preserving Agent tool access for investigation sub-agents.

---

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated, never blocks the skill):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

---

## Phase A: GitHub Actions Pre-Scan (/dso:debug-everything)

Scan configured GitHub Actions workflows for CI failures and create bug tickets for any untracked failures. This step runs **before** the open-bug-count pre-check so newly discovered failures are visible to mode selection.

Execute `prompts/gha-dispatch.md` with `EPIC_COMMENT_LABEL="GHA scan complete"`. New tickets (tagged `gha:<workflow-file-name>`) are picked up by the open-bug-count check in Phase B Step 2 and processed in Bug-Fix Mode.

---

## Phase B: Full Diagnostic Scan + Clustering (/dso:debug-everything)

Run ALL diagnostic checks and cluster related failures. The orchestrator runs only Step 1 (session lock). Everything else is delegated.

### Step 1: Initialize & Acquire Session Lock (/dso:debug-everything)

The Bug-Fix Mode entry gate is **Step 2** (below). When `OPEN_BUG_COUNT > 0`, skip this Step 1 setup entirely and route to Bug-Fix Mode.

When `OPEN_BUG_COUNT == 0`, execute `prompts/session-init.md` to bind:
- `REPO_ROOT`, `PLUGIN_ROOT`, `PLUGIN_SCRIPTS`
- `DISPATCH_ISOLATION` (worktree isolation flag, applied to all sub-agent dispatches in Phases C/F/G/H/I/J/L/Validation Mode)
- `MAX_FIX_VALIDATE_CYCLES` (validation-loop bound, capped to [0, 10]; when 0, skip validation loop entirely and proceed directly to Phase J after Bug-Fix Mode)
- `LOCK_ID` (acquired via `agent-batch-lifecycle.sh lock-acquire`; persisted to `$(get_artifacts_dir)/debug-lock-id` for compaction recovery; released in Phase K)
- `INTERACTIVE_SESSION` (governs Non-Interactive Deferral Protocol behavior at each gate)

That prompt also runs the Resume Check (parse `CHECKPOINT N/6` lines on in-progress issues; fast-close, re-dispatch, or revert per checkpoint progress).

### Step 2: BUG-FIX MODE GATE — Skip Diagnostics If Open Bugs Exist (/dso:debug-everything)

**Check for open and in_progress bug tickets before launching the diagnostic scan.** This is the Bug-Fix Mode entry gate:

```bash
_open_bugs=$(.claude/scripts/dso ticket list --type=bug --status=open 2>/dev/null | grep -c '"ticket_id"' || echo 0)
_inprog_bugs=$(.claude/scripts/dso ticket list --type=bug --status=in_progress 2>/dev/null | grep -c '"ticket_id"' || echo 0)
OPEN_BUG_COUNT=$((_open_bugs + _inprog_bugs))
```

- If `OPEN_BUG_COUNT > 0`: **Enter Bug-Fix Mode.** Skip Phase B diagnostic scan (Steps 3, 4, 5, 6, 7) and Phase C triage entirely. Proceed to the **Bug-Fix Mode** section below.
- If `OPEN_BUG_COUNT == 0`: Continue to Step 3 (normal diagnostic flow).

### Step 3: Context Budget Check (/dso:debug-everything)

Before launching diagnostics, estimate context load:

```bash
.claude/scripts/dso estimate-context-load.sh debug-everything 2>/dev/null | tail -5
```

If the static context load is >10,000 tokens, trim `MEMORY.md` before continuing to avoid premature compaction (per CLAUDE.md). Removing stale/redundant entries from `MEMORY.md` is sufficient — aim to bring the static load under 10,000 tokens before proceeding.

### Step 4: Run Validation Gate (/dso:debug-everything)

Run `validate.sh --ci` to populate the validation state file. This serves two purposes:
1. Seeds the gate state file so sub-agents aren't blocked by the validation gate hook
2. Produces per-category pass/fail results that the diagnostic sub-agent can use to skip passing categories

```bash
.claude/scripts/dso validate.sh --ci 2>&1 || true
```

**Bash timeout**: Use `timeout: 600000` (10 minutes — the TaskOutput hard cap). The smart CI wait in validate.sh can poll for up to 15 minutes, but the TaskOutput tool caps at 600000ms; use `|| true` and check the state file for CI results if the call times out.

**Note**: The `|| true` ensures we continue regardless of outcome — `/dso:debug-everything` is the skill that *fixes* validation failures, so it must not stop here.

**Parse the state file** to extract passing and failing categories:

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
VALIDATION_STATE_FILE="$(get_artifacts_dir)/status"
```

The state file contains:
- Line 1: `passed` or `failed`
- `failed_checks=<comma-separated list>` (only present when failed)

Known check names: `format`, `ruff`, `mypy`, `tests`, `migrate`, `ci`, `e2e`. (`docker` only appears in an early-exit path, not in the normal `failed_checks` accumulator.)

**Build the category lists**:
- If line 1 is `passed`: ALL categories passed. Set `validatePassedAll = true`.
- If line 1 is `failed`: read `failed_checks`. Every known check NOT in that list passed. Store both lists:
  - `validateFailedChecks`: the comma-separated failed checks (e.g., `ci,e2e`)
  - `validatePassedChecks`: the remaining checks that passed (e.g., `format,ruff,mypy,tests,migrate`)

Pass these to the diagnostic sub-agent in Step 7.

### Step 5: Pre-Flight Infrastructure Check (/dso:debug-everything)

Before launching diagnostics, verify that Docker Desktop and the database are running. The diagnostic sub-agent runs E2E tests which require both.

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh preflight --start-db  # shim-exempt: internal orchestration script
```

The script outputs structured key-value pairs:
- `DOCKER_STATUS: running | not_running`
- `DB_STATUS: running | started | stopped | failed_to_start | skipped`

Exit 0 means all checks pass. Exit 1 means at least one check failed.

**Action on failure:**
- `DOCKER_STATUS: not_running` → Release session lock (`lock-release <lock-id> "Docker Desktop not running"`), report to user: "Docker Desktop is not running. Please start it and re-run `/dso:debug-everything`." **STOP.**
- `DB_STATUS: failed_to_start` → Release session lock, report to user: "Database failed to start. Check Docker Desktop and run `make db-start` manually." **STOP.**
- Both passing → proceed to Step 7.

### Step 6: Check for Sprint Validation State (/dso:debug-everything)

Before launching the full diagnostic scan, check for a validation state file
written by `/dso:sprint` that indicates which categories already passed:

1. Look for `/tmp/sprint-validation-*.json` files. If multiple exist, use the
   most recent one (highest `generatedAt` timestamp).
2. **If a fresh file exists** (generatedAt < 1 hour old):
   - Read `postBatchResults` to identify categories that passed in the sprint's
     post-batch validation.
   - Read `ciFailure` for the CI failure URL and failed job names.
   - Read `batchInfo` for changed files and task IDs — use these to focus the
     diagnostic scan on likely failure sources.
   - Set an internal flag: `sprintContext = true` and store the passing
     categories. Pass this context to the diagnostic sub-agent in Step 7.
   - Log: `"Loaded sprint validation state from <file> — categories passing in
     sprint post-batch: <list>. Will focus diagnostics on failing categories."`
3. **If no file exists or all files are stale (>1 hour)**: proceed with full
   diagnostics. Set `sprintContext = false`.

### Step 7: Launch Diagnostic & Clustering Sub-Agent (/dso:debug-everything)

Launch a **single sub-agent** that runs all diagnostics, collects verbose output, clusters related failures, and returns a structured failure inventory.

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/diagnostic-and-cluster.md` and use its contents as the sub-agent prompt.

**If `validatePassedAll = true`**: ALL validation categories passed. Append to the sub-agent prompt:
```
### Validation Gate Results (all passed)
validate.sh --ci reported ALL categories passing. Skip Step 1 (summary diagnostics)
and Step 7 verbose checks for format, ruff, mypy, unit tests, and e2e. Go directly
to Step 3 (tickets & git state) and Step 4 (clustering of any ticket bugs only).
Report 0 for all validation categories in the failure inventory.
```

**If `validatePassedAll = false`** (some checks failed): Append to the sub-agent prompt:
```
### Validation Gate Results (partial pass)
validate.sh --ci already ran these checks. Use these results to skip redundant work:

Passing categories (SKIP verbose diagnostics for these): {validatePassedChecks}
Failing categories (RUN verbose diagnostics for these): {validateFailedChecks}

In Step 1, you MAY skip running validate.sh --full --ci entirely since we already
have the summary. In Step 7, only run verbose error collection for the FAILING
categories. Report passing categories as count=0 in the failure inventory.
```

**If `sprintContext = true`**: ALSO append to the sub-agent prompt:
```
### Sprint Context (skip passing categories)
The following validation categories passed in a recent sprint post-batch check
and are unlikely to have regressed. You MAY skip running diagnostics for these
categories to save time, but MUST still run them if the CI failure log suggests
they might be involved:

Passing categories: {list from postBatchResults where value is "pass"}
CI failure URL: {ciFailure.url}
Failed CI jobs: {ciFailure.failedJobs}
Changed files in failing batch: {batchInfo.changedFiles}

Focus your diagnostic scan on the failing categories and the changed files.
If a "passing" category shows up in the CI failure log, run it anyway.
```

If `--aws` flag is set, append to the prompt:
```
### AWS Infrastructure Scan
Also run these commands and include results in the inventory:
if aws sts get-caller-identity &>/dev/null; then
    aws elasticbeanstalk describe-environment-health --environment-name $EB_STAGING_ENV --attribute-names All 2>&1
    aws logs tail /aws/elasticbeanstalk/$EB_STAGING_ENV --since 1h --filter-pattern "ERROR" 2>&1
else
    echo "AWS auth not configured — skipping infrastructure checks"
fi
```

**Subagent**: `subagent_type="general-purpose"`, `model="opus"`  # Complex investigation: must correlate failures across validation categories, cluster related errors, and distinguish root causes from symptoms in complex output. (`error-debugging:error-detective` is NOT a valid subagent_type — the Agent tool only accepts built-in types. Use general-purpose with the prompt from the named agent file.)

The sub-agent returns: the path to the diagnostic file + a ≤15-line summary (category counts + top-3 clusters + open bug count). The full report is saved to `$(get_artifacts_dir)/debug-diag.md` on disk; do NOT receive the full report inline. Store the `DIAGNOSTIC_FILE` path for Phase C.

**Flow control**: If any inventory row has count > 0 OR open bugs exist, proceed to Phase C. Only skip to Phase K if ALL validation categories pass AND zero open bugs.

---

## Bug-Fix Mode (/dso:debug-everything)

**Entry condition**: Open bug tickets detected in Step 2 (`OPEN_BUG_COUNT > 0`).

**Rationale**: When open bug tickets already exist, the diagnostic scan (Phase B) and triage sub-agent (Phase C) are unnecessary — they exist to *discover* new issues. Bug-Fix Mode skips both and applies `/dso:fix-bug` directly to each known ticket. **All bugs are in scope — including pre-existing ones.** "Pre-existing" means the bug existed before this session; it does not mean the bug should be skipped or deferred. Every open bug ticket must be investigated and resolved via `/dso:fix-bug`.

### What is skipped in Bug-Fix Mode

- **Diagnostic scan skipped** (Phase B Steps 3, 4, 5, 6, 7): No `validate.sh --ci`, no preflight checks, no diagnostic sub-agent, no clustering.
- **Triage skipped** (Phase C): No triage sub-agent dispatch, no new epic creation, no issue clustering.

<COMPACTION_RESUME>
**If resuming after an auto-compact event in Bug-Fix Mode**: re-establish `OPEN_BUG_COUNT` (canonical bash, see step 1 below — never filter `ticket list --type=bug` output via Python `t.get('type') == 'bug'` because `--type=bug` strips the `type` field), re-read `$PLUGIN_ROOT/skills/fix-bug/SKILL.md` inline, and let fix-bug resume itself from its own most recent CHECKPOINT comment. Fix-bug owns its per-ticket compaction-resume protocol — do not duplicate that logic here. After the in-progress ticket completes, do NOT stop — re-query remaining open and in_progress bugs and continue processing them in priority order. Compaction that triggered this resume is historical state, not a Phase K shutdown trigger.
</COMPACTION_RESUME>

### Bug-Fix Mode Execution

1. **List all open and in_progress bug tickets**:

   ```bash
   { .claude/scripts/dso ticket list --type=bug --status=open; .claude/scripts/dso ticket list --type=bug --status=in_progress; } 2>/dev/null
   ```

   Collect all returned ticket IDs (deduplicate by `ticket_id` in case a ticket appears in both queries). Order by priority (P0 first, then P1, P2, P3, P4).

2. **For each open or in_progress bug ticket, invoke `/dso:fix-bug` at the orchestrator level**:

   Each ticket is an independent fix-bug invocation; **fix-bug enforces its own HARD-GATE** ("Do NOT investigate inline", "Do NOT modify code until Steps 1–5 are complete") and its own investigation-dispatch requirement per ticket. Do not duplicate those gates here, and do not pre-write fixes or reuse prior-ticket findings in the orchestrator prompt.

   Read `$PLUGIN_ROOT/skills/fix-bug/SKILL.md` inline and execute its steps directly — NOT via the Skill tool or Task tool. This orchestrator-level invocation preserves Agent tool access for fix-bug's investigation sub-agents (BASIC/INTERMEDIATE/ADVANCED), which require the Agent tool themselves. CLI_user-tagged bugs are handled inside fix-bug Step 1.5 — no debug-everything-side check.

   Pass the ticket as bug context. Always include `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` in the dispatch prompt. When `DISPATCH_ISOLATION=true`, also add `isolation: "worktree"` to each fix-bug sub-agent dispatch.

   ```
   Bug ticket: <ticket-id>
   Title: <title from ticket show>
   ORCHESTRATOR_ROOT: <value of $(git rev-parse --show-toplevel)>
   ```

   **After the fix sub-agent returns** — when `DISPATCH_ISOLATION=true`, follow `skills/shared/prompts/single-agent-integrate.md` to integrate the sub-agent's worktree changes onto the session branch. When `DISPATCH_ISOLATION=false`, no integration step is needed.

3. **Error handling**: If `/dso:fix-bug` fails for a ticket (unrecoverable error, repeated failure, or explicit escalation), write a CHECKPOINT note and continue to the next ticket:

   ```bash
   .claude/scripts/dso ticket comment <id> "CHECKPOINT: Bug-Fix Mode — fix-bug failed: <error>. Resume from: re-attempt fix."
   ```

   Do NOT abort Bug-Fix Mode when a single ticket fails — process all remaining tickets.

4. **After all bug tickets have been attempted**, run the **Between-Batch GHA Refresh** before proceeding to Validation Mode.

### Between-Batch GHA Refresh (Bug-Fix Mode)

Run unconditionally after all bug tickets in the current batch have been attempted and before Validation Mode entry — regardless of `MAX_FIX_VALIDATE_CYCLES` (including 0).

Execute `prompts/gha-dispatch.md` with `EPIC_COMMENT_LABEL="GHA between-batch scan"`. After the scan completes, re-query open + in_progress bug tickets:

```bash
{ .claude/scripts/dso ticket list --type=bug --status=open; .claude/scripts/dso ticket list --type=bug --status=in_progress; } 2>/dev/null
```

Use the refreshed list for the Validation Mode entry decision.

5. Proceed to **Validation Mode**.

---

## Validation Mode (/dso:debug-everything)

**Entry condition**: Entered after Bug-Fix Mode completes one full pass over all open bug tickets.

**Purpose**: Detect failures newly exposed by bug fixes (regressions or previously hidden issues), create tickets for them, and loop back to Bug-Fix Mode — up to `MAX_FIX_VALIDATE_CYCLES` iterations.

**Scope**: This is an INNER loop within the Bug-Fix Mode → Phase J flow. It is bounded by `debug.max_fix_validate_cycles` (configured at session start). The outer Phase B→J loop is separate and bounded by Phase J's 5-cycle safety limit. These loops are independent and must NOT be conflated.

### Step 1: Check Iteration Count

Initialize on first entry: `VALIDATION_ITERATION=1`

On each re-entry (looping from Bug-Fix Mode): `VALIDATION_ITERATION=$((VALIDATION_ITERATION + 1))`

**Persist iteration count** as an epic ticket comment for resume continuity:

```bash
.claude/scripts/dso ticket comment <epic-id> "VALIDATION_LOOP_ITERATION: ${VALIDATION_ITERATION}/${MAX_FIX_VALIDATE_CYCLES}"
```

On resume (Step 1 resume check), parse existing `VALIDATION_LOOP_ITERATION:` comments to restore `VALIDATION_ITERATION` and `MAX_FIX_VALIDATE_CYCLES`.

**Edge-case normalization** (apply once, before Step 1 iteration logic):
- Value `<= 0` (zero or negative): set `MAX_FIX_VALIDATE_CYCLES=0`; skip validation loop entirely and proceed directly to Phase J.
- Value `> 10`: set `MAX_FIX_VALIDATE_CYCLES=10` (capping at 10); log `"WARNING: max_fix_validate_cycles exceeds cap of 10 — capped to 10"`.
- Non-numeric value: default to 3; log `"WARNING: max_fix_validate_cycles not numeric — defaulting to 3"`.

**If `MAX_FIX_VALIDATE_CYCLES <= 0`**: Skip validation loop entirely. Proceed directly to Phase J.

### Step 2: Run Diagnostic Scan After Bug-Fix

Reuse the same diagnostic sub-agent pattern as Phase B. Dispatch a diagnostic sub-agent to scan for newly exposed failures:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/tier-transition-validation.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit`, `model="haiku"`

**On scan failure** (sub-agent error, timeout, or corrupt output): Log warning: `"WARNING: Validation Mode diagnostic scan failed (iteration ${VALIDATION_ITERATION}/${MAX_FIX_VALIDATE_CYCLES}) — treating as failures remain"`. Decrement remaining iterations: `MAX_FIX_VALIDATE_CYCLES=$((MAX_FIX_VALIDATE_CYCLES - 1))`. Do NOT create tickets from partial or corrupt scan results. Proceed to Step 4.

### Step 3: Create Tickets for Newly Discovered Failures

For each new failure discovered in the diagnostic scan, create a bug ticket — but **deduplicate first**.

**Deduplication** — before creating any new ticket, check for an existing open or in_progress bug ticket covering the same failure:

```bash
{ .claude/scripts/dso ticket list --type=bug --status=open; .claude/scripts/dso ticket list --type=bug --status=in_progress; } 2>/dev/null
```

Compare each discovered failure against:
1. Tickets already created by Phase I regression detection
2. Tickets from previous validation iterations (check `VALIDATION_LOOP_ITERATION:` comments to identify those iterations)
3. Tickets from original Phase C triage

If an open bug ticket already exists for a failure (by title similarity or matching error message), **skip ticket creation** — use the existing ticket. Only ONE ticket per unique failure across all iterations.

For genuinely new failures (no matching open ticket exists), create a ticket. Follow `skills/create-bug/SKILL.md` for title and description format:

```bash
# Title format: [Component]: [Condition] -> [Observed Result]
# Capture both stdout and stderr to enable post-creation title validation
BUG_CREATE_OUT=$(.claude/scripts/dso ticket create bug "[Component]: [Condition] -> [Observed Result]" -d "## Incident Overview ..." 2>/tmp/ticket_create_stderr.tmp)
BUG_CREATE_ERR=$(cat /tmp/ticket_create_stderr.tmp); rm -f /tmp/ticket_create_stderr.tmp
NEW_TICKET_ID=$(echo "$BUG_CREATE_OUT" | grep -oE '[0-9a-f]{4}-[0-9a-f]{4}' | head -1)

# Post-creation title validation: fix non-conforming titles immediately
if echo "$BUG_CREATE_ERR" | grep -q "does not match required pattern"; then
    .claude/scripts/dso ticket edit "$NEW_TICKET_ID" --title="[Component]: [Condition] -> [Observed Result]"
fi
```

The title format MUST follow `[Component]: [Condition] -> [Observed Result]`. Do not proceed with a non-conforming title.

Collect newly created ticket IDs as `NEW_BUG_TICKETS`.

### Step 4: Decide — Loop or Stop and Report

**If `VALIDATION_ITERATION >= MAX_FIX_VALIDATE_CYCLES`**:

Max fix-validate cycles reached. Do NOT loop back. Stop and report:

```
Max validation iterations (MAX_FIX_VALIDATE_CYCLES) reached — remaining issues reported as open tickets.
Open bugs remaining: <list ticket IDs and titles>
```

Log: `"Max validation iterations (${MAX_FIX_VALIDATE_CYCLES}) reached — remaining issues reported as open tickets"`. Proceed to Phase J.

**If new bugs were found AND `VALIDATION_ITERATION < MAX_FIX_VALIDATE_CYCLES`**:

New failures discovered. Loop back to Bug-Fix Mode with the newly created tickets:
- Update `OPEN_BUG_COUNT` to include `NEW_BUG_TICKETS`
- Return to Bug-Fix Mode (Step 2: process all open bug tickets by priority)

**If no new bugs were found**:

No new failures. The fix cycle is clean. Proceed to Phase J.

---

## Phase C: Triage & Issue Creation (/dso:debug-everything)

Delegate ALL triage work to a sub-agent. The orchestrator passes the diagnostic report and receives back issue IDs.

### Launch Triage Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/triage-and-create.md` and use its contents as the sub-agent prompt. Pass the diagnostic file path as context — do NOT append the full report inline:

```
DIAGNOSTIC_FILE: $(get_artifacts_dir)/debug-diag.md
```

If all validation categories passed but open ticket bugs exist, also append: `All validation categories passed — only open ticket bugs need triage. Skip cluster cross-referencing (no validation failures to cluster). Assign all bugs to Tier 7.`

If resuming an existing tracker, append: `Existing epic ID: <epic-id>. Do NOT create a new epic. Link new issues to this epic with .claude/scripts/dso ticket link <issue-id> <epic-id> relates_to.`

**Subagent**: `subagent_type="general-purpose"`, `model="sonnet"`  # Tier 2: must cross-reference failure clusters with existing issues and make severity/priority judgments for new issue creation

### Orchestrator Actions After Sub-Agent Returns

1. Parse the triage report: extract issue IDs, epic ID, `HAS_STAGING_ISSUES` flag
2. If `HAS_STAGING_ISSUES=true`: record staging symptoms for Phase L verification
3. Report triage summary to user:
   - Total distinct failures discovered
   - New issues created (with IDs and titles)
   - Pre-existing issues found (with IDs)
   - Epic ID
   - Recommended fix order by tier

**If `--dry-run`**: Stop here. Output the full triage report and exit.

---

## Phase D: Safeguard Bug Analysis (/dso:debug-everything)

After triage, identify which issues touch safeguarded files and route them through user-approval before fixing.

### Step 1: Detect Safeguarded Issues (/dso:debug-everything)

Safeguarded file patterns (from CLAUDE.md rule 20):
- `${CLAUDE_PLUGIN_ROOT}/skills/**`, `${CLAUDE_PLUGIN_ROOT}/hooks/**`, `${CLAUDE_PLUGIN_ROOT}/docs/workflows/**`
- `.claude/settings.json`, `.claude/docs/**`
- `scripts/**`, `CLAUDE.md`

For each issue from the Phase C triage report, check if the issue description, title, or root cause references files matching these patterns. Build two lists:
- `SAFEGUARD_BUGS`: issues that require editing safeguarded files
- `NORMAL_BUGS`: all other issues (proceed directly to Phase E)

If `SAFEGUARD_BUGS` is empty, skip to Phase E.

### Step 2: Launch Analysis Sub-Agent (/dso:debug-everything)

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/safeguard-analysis.md` and use its contents as the sub-agent prompt. Pass the `SAFEGUARD_BUGS` list (IDs and titles) and `WORKTREE` name as context.

**Subagent**: `subagent_type="general-purpose"`, `model="opus"`
# Complex investigation: must read safeguarded files, understand bug context,
# and propose precise line-level fixes — requires deep code comprehension and judgment.
# (`error-debugging:error-detective` is NOT a valid subagent_type — use general-purpose
# with the named agent file loaded verbatim as the prompt.)

The sub-agent returns: path to proposals file + summary (count + per-bug one-liner).

### Step 3: Present Proposals to User (/dso:debug-everything)

Non-interactive: apply Non-Interactive Deferral Protocol (see Phase B Step 1) using gate_name=`safeguard_approval`. Auto-defer ALL safeguard bugs; skip to Phase E with `SAFEGUARD_BUGS` removed from the fix queue (they remain open). Add a ticket comment to each deferred bug: `.claude/scripts/dso ticket comment <id> "INTERACTIVITY_DEFERRED: gate=safeguard_approval — requires user approval of safeguard file edits; deferred in non-interactive session."`

**Interactive mode**: Read the proposals file from disk. Present each proposal to the user:

```
SAFEGUARD BUG PROPOSALS (require approval per CLAUDE.md rule 20)
================================================================
[1] <bug-id>: <title>
    File: <path> (lines <N>-<M>)
    Risk: <level>
    Change: <description>
    Preview:
      - <removed line>
      + <added line>

[2] ...
```

Wait for user response. The user may approve all, approve specific bugs, or defer.

### Step 4: Route Approved Bugs (/dso:debug-everything)

- **Approved bugs**: Add to `NORMAL_BUGS` list with the proposal as fix guidance.
  ```bash
  .claude/scripts/dso ticket comment <id> "SAFEGUARD APPROVED: user approved editing <file>. Proposed fix: <description>"
  ```
- **Deferred bugs**: Leave open with note:
  ```bash
  .claude/scripts/dso ticket comment <id> "SAFEGUARD DEFERRED: requires editing <file>, deferred by user."
  ```
  Remove from the fix queue.

Proceed to Phase E with the combined list of normal + approved bugs.

---

## Phase E: Fix Planning (/dso:debug-everything)

### Fix Tiers (Dependency Order)

Fixes MUST be applied in this order. Each tier may resolve failures in later tiers.

```
Tier 0: Format (auto-fix with make format)
Tier 1: Lint — ruff auto-fix, then manual fixes for remaining
Tier 2: Type errors (mypy) — often root causes of runtime failures
Tier 3: Unit test failures — TDD required
Tier 4: E2E test failures — may require DB, browser
Tier 5: Integration test failures — may require external services
Tier 6: Infrastructure issues — AWS CLI always available for this tier
Tier 7: Open ticket bugs — pre-existing tracked bugs not covered by tiers 0-6
```

**Tier 6 AWS CLI access**: Sub-agents working on Tier 6 issues should use AWS CLI freely. If AWS auth is not configured, report and recommend `aws sso login`.

**Tier 7**: Ticket bugs that map to tiers 0-6 go in that tier instead. Only bugs that don't fit earlier tiers remain in Tier 7.

**Tier 7 sub-categories** (batch in this order within the tier):
1. **Code bugs** (wrong behavior, missing persistence, logic errors): Use TDD flow. Debugger agent (sonnet).
2. **Infrastructure bugs** (AWS config, Docker, deployment): Attempt with AWS CLI. If auth unavailable or manual steps required, update the bug with specific next steps and skip gracefully. Never silently skip.
3. **Investigation bugs** (unknown root cause, needs analysis): Error-detective agent. Output is either a fix OR updated findings with concrete fix plan added to the bug description.

**Priority ordering within Tier 7**: P1 bugs first, then P2, then P3. Attempt all priorities. Stop only on session limits (context, time), not priority boundaries.

**Consult prior session data**: If `{auto-memory-dir}/debug-sessions.md` exists, read it. Use prior session outcomes to prefer agent types that succeeded for similar failure categories and flag recurring patterns.

**Load bug classification rules**: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/bug-accountability-guide.md` now. You will need these rules in Phase L Step 2; loading here avoids loading them when context is tighter.

**Research complex fixes**: For any Tier 3+ fix where the failure involves unfamiliar library behavior, a non-obvious tradeoff, or an external system whose current behavior you cannot derive from the codebase — spawn a research sub-agent before choosing a fix strategy. Pass findings as a `Research Context` section in the fix sub-agent prompt. See `${CLAUDE_PLUGIN_ROOT}/docs/RESEARCH-PATTERN.md` for trigger criteria, guardrails, and sub-agent prompt template.

**After completing each tier**, re-run the relevant diagnostics for subsequent tiers. Update the failure inventory. Close issues that resolved themselves.

### Batch Planning Within Tiers

Within each tier, group independent fixes into batches sized by the `MAX_AGENTS` value from the pre-batch check:
1. Fixes that unblock other fixes (dependency order first)
2. Fixes affecting the most files/tests (largest blast radius)
3. Independent fixes that can be parallelized
4. **File overlap assessment via static analysis + NxN conflict matrix**:

   For each candidate issue in the batch:
   a. Extract seed file paths from the issue description/triage report.
      For fully-qualified Python names (e.g., `src.services.pipeline.process_document`),
      strip the trailing function/class/method components and convert only the module portion
      to a file path (e.g., `src/services/pipeline.py`). Verify the path exists before using it.
   b. Run `python3 "$PLUGIN_SCRIPTS/analyze-file-impact.py" --root $REPO_ROOT/app <seed-files>` to get  # shim-exempt: internal orchestration script
      `files_likely_modified` and `files_likely_read` for each candidate (timeout: 30s)
   c. **Graceful degradation**: If `analyze-file-impact.py` is missing, errors, or times out,
      fall back to text-based file extraction from issue descriptions (existing behavior).
      Debug sessions must not break if static analysis is unavailable.

   Batch conflict detection: read `prompts/batch-conflict-matrix.md`. Write-write conflicts defer the lower-priority issue; read-read overlap is allowed; conflicts are logged to stderr in `CONFLICT_MATRIX:` format.

---

## Phase F: Auto-Fix Sub-Agent (Tiers 0-1) (/dso:debug-everything)

### Launch Auto-Fix Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/auto-fix.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `code_simplify` (see `agent-routing.conf`), `model="sonnet"`

### Orchestrator Actions After Sub-Agent Returns

1. Verify the sub-agent's report
2. Close any issues resolved by auto-fix: `.claude/scripts/dso ticket transition <id> open closed --reason="Fixed: resolved by auto-fix (format/lint)"`
3. Update the failure inventory with remaining errors
4. **CONTEXT ANCHOR**: After the commit workflow completes, continue immediately at Step 5 below (Phase F). Do NOT stop or wait for user input after committing.

   Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline. Do NOT use the `/dso:commit` Skill tool — nested skill invocations do not return control to the orchestrator.
5. Remaining ruff violations that couldn't be auto-fixed become sub-agent tasks in Phase G

---

## Phase G: Sub-Agent Fix Batches (/dso:debug-everything)

For remaining failures (Tiers 2–7), launch sub-agent batches by executing `prompts/dispatch-fix-batch.md`. That prompt covers:

- Pre-batch checks (`agent-batch-lifecycle.sh pre-check [--db]`) and the `MAX_AGENTS` protocol (`unlimited` / N / 0).
- Task claim (`ticket transition <id> in_progress`) and `SAFEGUARD APPROVED:` known-solution detection.
- Blackboard write + per-agent `file_ownership_context` build.
- Task tool dispatch with `/dso:fix-bug` delegation, `isolation: "worktree"` when `DISPATCH_ISOLATION=true`, and triage-classification-as-pre-loaded-context.

Resolve `subagent_type` via the table in `prompts/agent-routing-table.md`.

**Complete assembled Task prompt** (individual bug — orchestrator MUST include all three sections):

```
/dso:fix-bug <bug-id>

### Triage Classification Context (pre-loaded — do not re-score)
Bug ID: <bug-id>
Triage tier: <tier-number>
Severity (from triage priority): <P0=critical/2pts | P1=high/2pts | P2=medium/1pt | P3=low/0pts>
Environment: <CI failure | staging | local — from triage report>

### File Ownership Context
{file_ownership_context}
```

The `file_ownership_context` value follows the format: `You own: file1.py, file2.py. Other agents own: <task-id-X> owns file3.py.` (empty string when the blackboard is unavailable).

---

## Phase H: Post-Batch Checkpoint (/dso:debug-everything)

After ALL sub-agents in a batch return:

### Step 1: Dispatch Failure Recovery (/dso:debug-everything)

Before verifying results, check whether any sub-agent Task call returned an **infrastructure-level dispatch failure** (no `STATUS:` line, no `FILES_MODIFIED:` line, error message references agent type or internal errors — as opposed to task-level failures where the agent ran but produced incorrect work).

**For each dispatch failure:**
1. Retry with `subagent_type="general-purpose"`, same model and prompt. Log: `"Dispatch failure for task <id> with subagent_type=<original-type> — retrying with general-purpose."`
2. If retry fails: escalate model (sonnet → opus) and retry once more with `subagent_type="general-purpose"`.
3. If all retries fail: mark task as failed.

Dispatch failure retries are sequential (error recovery, not planned work) and do not count toward batch size limits.

### Step 2: Worktree Integration (/dso:debug-everything)

When `DISPATCH_ISOLATION=true`, sub-agents in Phase G ran in isolated worktree branches — their changes are NOT on the session branch in the orchestrator's CWD. Before any subsequent step runs `git diff` (Step 4 file-overlap, Step 5 critic review, Step 10 semantic conflict check) or `git commit` (Step 11), each sub-agent's worktree changes MUST be integrated onto the session branch.

**When `DISPATCH_ISOLATION=true`**: For each sub-agent that returned successfully (including any that succeeded on retry from Step 1), follow `skills/shared/prompts/single-agent-integrate.md` to integrate its worktree changes back into the session branch. This mirrors the Bug-Fix Mode per-result integration pattern (see Bug-Fix Mode Execution step 2 above) so downstream `git diff` / commit operations in Phase H observe the combined batch changes.

**When `DISPATCH_ISOLATION=false`**: Skip this step — sub-agents wrote directly to the session branch and the changes are already visible via `git diff` in Step 4 and beyond.

### Step 3: Verify Results (/dso:debug-everything)

For each sub-agent (including any that succeeded on retry), check the Task result:
- Did it report success?
- Were the expected files modified? (spot-check with Glob)
- Did it follow TDD? (check for new test files)

### Step 4: File Overlap Check (Safety Net) (/dso:debug-everything)

Sub-agents may modify files beyond what their task description predicts. Run overlap detection on collected modified files (from Task results or `git diff --name-only`):

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh file-overlap \
  --agent=<task-id-1>:<file1>,<file2> \
  --agent=<task-id-2>:<file3>,<file4>
```

Zero conflicts → proceed to Step 10. One or more `CONFLICT:` lines → execute `prompts/file-overlap-resolution.md` (capture secondary agent diffs, revert, re-run secondaries one-at-a-time in priority order with conflict-resolution context). The same prompt covers the oscillation guard fired by repeat CONCERN outcomes.

**Non-interactive**: when `INTERACTIVE_SESSION=false` and a file-overlap conflict requires user escalation (e.g., unresolvable write-write conflict after re-run), defer the escalation — add an `INTERACTIVITY_DEFERRED: gate=file_overlap` ticket comment on the conflicting tasks and proceed to Step 10 with the lower-priority task reverted.

### Step 5: Critic Review (Complex Fixes Only) (/dso:debug-everything)

Launch a critic sub-agent before committing when ANY trigger applies: `model="opus"` was used (complex multi-file bug), Tier 5–6, ≥3 files modified, or TDD was required (behavioral code change — not imports, annotations, or config).

Capture the diff first:
```bash
git diff --stat   # save as {diff_stat}
git diff          # save as {full_diff}
```

Sub-agent prompt: read `$PLUGIN_ROOT/skills/debug-everything/prompts/critic-review.md`; replace `{full_diff captured by orchestrator via \`git diff\`}` with the actual diff. Subagent: `general-purpose`, `model="sonnet"`.

- `PASS` → Step 11.
- `CONCERN` → if valid: revert (`git checkout -- <files>`), reopen with concern noted for next fix attempt. If false positive: Step 11. On 2nd CONCERN for the same issue, the oscillation guard in `file-overlap-resolution.md` fires.

**Non-interactive**: when `INTERACTIVE_SESSION=false` and the oscillation guard fires (requiring user to choose between two diverging fix approaches), defer escalation to user — add an `INTERACTIVITY_DEFERRED: gate=oscillation_guard` ticket comment, revert the most recent attempt, and leave the ticket open for the next session.

### Step 6: Validate via Sub-Agent (/dso:debug-everything)

**Do NOT run validation directly in the orchestrator.** Launch a validation sub-agent:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/post-batch-validation.md` and use its contents as the sub-agent prompt. Replace `{list of files modified by batch}` with the actual file list from this batch.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh post-batch and relays output verbatim — pure command execution with one bounded LIKELY_CAUSE inference from provided file list

### Step 7: Handle Failures (/dso:debug-everything)

| Sub-agent outcome | Action |
|------------------|--------|
| Success + tests pass | `.claude/scripts/dso ticket transition <id> open closed --reason="Fixed: <summary>"` |
| Partial success | `.claude/scripts/dso ticket comment <id> "Partial: <details>."` |
| Failure | `.claude/scripts/dso ticket transition <id> open` then `.claude/scripts/dso ticket comment <id> "Failed: <error>."` |
| Regression | Revert changes (`git checkout -- <files>`), reopen, note regression |
| `FIX_RESULT: unresolved` | Leave ticket **OPEN**. Add comment: `.claude/scripts/dso ticket comment <id> "Investigated: <investigation_summary> — could not fix. <reason>"`. Surface in session summary under **ESCALATED BUGS**. |

**Bug close constraint**: Only close a bug when there is an actual code change that fixes it. **NEVER close a bug with reason `Escalated to user:` — closing removes the bug from `ticket list` visibility, which is the opposite of escalation.** When no code fix is possible:
1. Add investigation findings as a ticket comment: `.claude/scripts/dso ticket comment <id> "Investigated: <findings> — no code fix possible."`
2. Leave the ticket **OPEN** (do NOT transition to closed)
3. Surface the ticket in the session summary under the `ESCALATED BUGS` section so the user sees it

Valid close example (after code fix):
- `.claude/scripts/dso ticket transition <id> in_progress closed --reason="Fixed: added comment_penalty to quality_helpers.py"`

Invalid (prohibited — do NOT do this):
- ~~`.claude/scripts/dso ticket transition <id> in_progress closed --reason="Escalated to user: code path is correct, no fix possible"`~~

### Step 8: COMPLEX Escalation Handling (/dso:debug-everything)

Scan each fix-bug sub-agent result for `COMPLEX_ESCALATION: true`. If absent in all results, proceed to Step 9.

If present in any result, execute `prompts/complex-escalation-handler.md`. That prompt parses the escalation report fields, applies the Non-Interactive Deferral Protocol when `INTERACTIVE_SESSION=false`, and otherwise re-dispatches `/dso:fix-bug` at orchestrator level with `### COMPLEX_ESCALATION Context` pre-loaded so fix-bug skips to its own Step 4 (Fix Approval). All complex-escalated bugs are tracked in the `COMPLEX_BUGS` list for the session summary.

### Step 9: Decision Log (/dso:debug-everything)

Record the batch decisions and outcomes on the epic for observability:

```bash
.claude/scripts/dso ticket comment <epic-id> "BATCH {N} | Tier {T}
Issues: {id1} ({status}), {id2} ({status}), ...
Agent types: {type} ({id1}), {type} ({id2}), ...
Model tier: {model}
Critic review: {PASS|CONCERN|skipped}
Outcome: {N} fixed, {M} failed, {K} reverted
Remaining in tier: {count}"
```

### Step 10: Semantic Conflict Check (/dso:debug-everything)

Before committing, run the semantic conflict check on the combined diff:

```bash
git diff | python3 "$PLUGIN_SCRIPTS/semantic-conflict-check.py"  # shim-exempt: internal orchestration script
```

Parse the JSON output:
- `"clean": true` — proceed with commit (Step 11).
- `"clean": false` — log conflicts, present to orchestrator for review. If any conflict has `"severity": "high"`, revert the conflicting files and re-dispatch the responsible sub-agent. If all conflicts are medium/low, note them in ticket and proceed.
- `"error"` field present — log warning, proceed with commit (graceful degradation). Semantic conflict check failure is non-fatal.

### Step 11: Commit & Sync (/dso:debug-everything)

**CONTEXT ANCHOR**: After the commit workflow completes, continue immediately at Step 12 (Discovery Collection) below. Do NOT stop or wait for user input after committing.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline. Do NOT use the `/dso:commit` Skill tool — nested skill invocations do not return control to the orchestrator, causing the debug-everything workflow to stall waiting for user input.

**Blackboard cleanup**: After the commit, run `write-blackboard.sh --clean` to remove the blackboard file:
```bash
.claude/scripts/dso write-blackboard.sh --clean
```
If blackboard cleanup fails, log a warning and continue — cleanup failure is non-fatal and must not block the next batch or graceful shutdown.

### Step 12: Discovery Collection (/dso:debug-everything)

After the commit completes and before launching the next batch, collect discoveries from sub-agents:

```bash
DISCOVERIES=$(.claude/scripts/dso collect-discoveries.sh --format=prompt)
```

If discoveries exist (non-empty and not just `"None."`), inject the `## PRIOR_BATCH_DISCOVERIES` section into the next batch's sub-agent prompts by appending it to the fix-task prompt context.

If `collect-discoveries.sh` fails, log a warning and proceed without discovery propagation (graceful degradation).

### Step 13: Continuation Decision (/dso:debug-everything)

**Default is CONTINUE, not shutdown.** Only shut down on a concrete, verifiable signal — never on a "felt sense" of context fullness (a54a-95fc).

- If you received a **literal context-compaction event banner** from Claude Code during this session → Phase K (graceful shutdown). **CRITICAL**: On compaction, LOCK_ID may be lost from context. Recover it from the artifact file before Phase K: `LOCK_ID=$(cat "$(get_artifacts_dir)/debug-lock-id" 2>/dev/null)`. Phase K MUST release the lock and write epic summary notes — these are the two obligations that prior sessions lost after compaction.
- If more failures remain in this tier → Phase G (next batch)
- If tier is clear → Phase I (re-diagnose)

Do NOT shut down based on an internal estimate of session context usage. There is no way to self-measure context fill. If no compaction event occurred, keep fixing bugs.

---

## Phase I: Re-Diagnose & Next Tier (/dso:debug-everything)

After completing a tier, re-validate to check for transitive resolutions.

### Step 1: Launch Re-Diagnosis Sub-Agent (/dso:debug-everything)

Same pattern as Phase H Step 6, but run the full diagnostic set:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/tier-transition-validation.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh tier-transition and relays structured output verbatim — no interpretation required, pass/fail reporting only

### Step 2: Update Failure Inventory (/dso:debug-everything)

Compare sub-agent report against the inventory:
- Resolved without direct fix (transitive resolution) → close their issues
- New failures not in original inventory (regressions) → treat as P0
- Remaining failures → proceed to next tier

### Step 3: Continue or Finish (/dso:debug-everything)

- If failures remain in higher tiers → return to Phase E
- If all tiers are clear → proceed to Phase J (Full Validation)

---

## Phase J: Full Validation (/dso:debug-everything)

When all known issues across all tiers are addressed, delegate validation to a sub-agent.

**CI is checked post-merge, not here.** Phase J validates local code health only (format, lint, tests). CI runs on main, not the worktree branch — checking CI here would show the pre-fix state and produce a false failure. CI status is verified in Phase L after merging to main.

### Launch Validation Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/full-validation.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh full --skip-ci and relays structured output verbatim — pure command execution, ALL_PASS/SOME_FAIL is explicit in script output

### Interpret Result

- **`ALL_PASS` + zero open bugs** → Phase K (Completion)
- **`SOME_FAIL` or open bugs remain** → Return to Phase C (re-triage via sub-agent)

This is a remediation pass. Apply the same discipline: triage new failures, create issues, fix in tier order.

**Safety bound**: Maximum 5 full diagnostic cycles (Phase B→J loops). If the project is not healthy after 5 cycles, proceed to graceful shutdown and report to the user.

---

## Phase K: Issue Closure & Graceful Shutdown (/dso:debug-everything)

### On Success (All Checks Pass + Zero Open Bugs)

1. Clean up discoveries and release the session lock:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries  # shim-exempt: internal orchestration script
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-release <lock-id> "All diagnostics passing, all bugs resolved"  # shim-exempt: internal orchestration script
   .claude/scripts/dso ticket comment <epic-id> "Health restored."
   .claude/scripts/dso ticket transition <epic-id> open closed
   ```
   Discovery cleanup failure is non-fatal; log a warning and continue with lock release.
2. Proceed to **Phase L** (Merge to Main & Verify).

### On Graceful Shutdown

1. Clean up discoveries and release the session lock:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries  # shim-exempt: internal orchestration script
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-release <lock-id> "Graceful shutdown — work remains"  # shim-exempt: internal orchestration script
   ```
   Discovery cleanup failure is non-fatal; log a warning and continue with lock release.
2. Do NOT launch new sub-agents.
3. Stage modifications via `git status --short` (do NOT run a full test/lint pass — `make test-unit-only` exceeds the tool timeout ceiling per CLAUDE.md "Never Do These" rule 19; the post-batch validation sub-agent in Phase H has already validated this batch).
4. Commit checkpoint:
   ```bash
   git add <modified files>
   git commit -m "checkpoint: project health restoration — partial

   Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
   ```
5. Update ALL in-progress issues:
   ```bash
   .claude/scripts/dso ticket comment <id> "Session shutdown. Progress: <summary>. Next: <what remains>."
   ```
6. Update the epic with remaining work summary:
   ```bash
   # List remaining open issues linked to the epic
   .claude/scripts/dso ticket show <epic-id>
   # Add a note summarizing what remains
   .claude/scripts/dso ticket comment <epic-id> "Graceful shutdown. Resolved: <N resolved>/<M total> issues. Remaining open: <list IDs and titles>. Next session should resume with .claude/scripts/dso ticket list."
   ```
   The epic stays open so the next `/dso:debug-everything` session can resume it (see [Epic Lifecycle](#epic-lifecycle)).
7. Commit partial work and proceed to **Phase L** (Merge to Main & Verify). After Phase L completes successfully, check context usage:
   - If context usage <70% AND remaining open bugs exist: return to **Phase C** (continue fixing — do NOT go to Phase M)
   - If context usage ≥70% OR no remaining bugs: proceed to **Phase M** (/dso:end-session)

---

## Phase L: Merge to Main & Verify (/dso:debug-everything)

This phase is REQUIRED for both success and graceful shutdown. The `/dso:debug-everything` command is NOT complete until changes are merged to main and CI passes.

### Step 1: Merge + CI + Validate (sub-agent)

Dispatch a merge-and-verify sub-agent:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/phase-10-merge-verify.md` and follow it. Pass as context:
- `REPO_ROOT`: absolute path
- `HAS_STAGING_ISSUES`: from Phase C triage
- `PATH_TYPE`: result of `test -f "$REPO_ROOT/.git" && echo worktree || echo main`
- Whether Phase J ran (success path vs graceful shutdown) — needed for scope file

**Subagent**: `subagent_type="general-purpose"`, `model="sonnet"`

**Interpret the return:**
- `MERGE_STATUS: conflict|error|push-failed` → relay error to user and stop
- `CI_STATUS: fail` → return to Phase C (re-triage); max 2 retries
- `CI_STATUS: fail-max-retries` → stop, report to user
- `VALIDATE_STATUS: ci-fail|regression` → return to Phase C
- `VALIDATE_STATUS: staging-fail` → follow the recommendation in DETAILS
- All `ok/pass` → proceed to Step 4

### Step 2: Report Completion (/dso:debug-everything)

#### Open Bug Accountability (required — both success and shutdown paths)

Read `$PLUGIN_ROOT/skills/debug-everything/prompts/bug-accountability-guide.md` for classification rules (loaded in Phase E — use cached version if already in context).

Run:
```bash
.claude/scripts/dso ticket list --type=bug --status=open
```

For every open bug, apply the three-outcome classification (Fixed / Escalated / Deferred) per the guide. Close fixed bugs with `.claude/scripts/dso ticket transition <id> open closed`.

Non-interactive: apply Non-Interactive Deferral Protocol (see Phase B Step 1) using gate_name=`bug_accountability`. Include deferred bugs in the session summary under a `DEFERRED (non-interactive)` section rather than `ESCALATED`. Previously deferred `COMPLEX_ESCALATION` bugs (Phase H Step 8) surface here as open bugs awaiting escalation.

**Interactive mode**: Present escalated bugs to the user.

**On Success** — report to user:
- Open bug accountability table (above)
- Total issues discovered / fixed / pre-existing
- Validation output (all PASS)
- Merge status: branch merged to main, pushed
- CI status: passing (with run ID)
- Staging status (if verified): healthy / bugs resolved
- Final commit hash on main
- Any observations or recommendations for preventing recurrence

**On Graceful Shutdown** — report to user:
- Open bug accountability table (above)
- Issues fixed this session
- Issues remaining (with IDs and titles)
- Current tier and progress within it
- Merge status: checkpoint merged to main, pushed
- CI status: passing/failing on main (with run ID)
- Instruction: "Run `/dso:debug-everything` again to continue — it will find the existing epic and pick up where this session left off"

### Cross-Session Learning (Both Paths)

After Phase L completes (or after Phase L is skipped due to unrecoverable errors), write a session summary to auto-memory for future `/dso:debug-everything` sessions to consult during Phase E (fix planning):

```
## Debug Session: {date}
- Failures: {N} discovered, {M} fixed, {K} deferred
- Tiers reached: {highest tier completed}
- Most effective agents: {agent type} for {category} (N successes)
- Least effective agents: {agent type} for {category} (N failures/escalations)
- Recurring patterns: {patterns seen in 2+ sessions, if auto-memory has prior entries}
- Recommendations: {observations for preventing recurrence}
```

If any bugs were escalated as COMPLEX by fix-bug sub-agents (via `COMPLEX_ESCALATION` in Phase H Step 8), append a dedicated section to the session summary **and present it to the user** before Phase M:

```
## Bugs escalated as COMPLEX (re-dispatched at orchestrator level)
- <bug-id>: <title> — escalated (COMPLEX): <escalation_reason> — outcome: <fixed|still-open>
```

One line per COMPLEX-escalated bug. If no COMPLEX escalations occurred this session, omit this section entirely.

Write to: `{auto-memory-dir}/debug-sessions.md` (append, don't overwrite).

**On subsequent runs**: During Phase E (Fix Planning), read `debug-sessions.md` if it exists. Use prior session data to:
- Prefer agent types that succeeded for similar failure categories
- Avoid agent types that required escalation for similar issues
- Flag recurring patterns to the user as potential systemic issues

---

## Phase M: End Session (/dso:debug-everything)

After Phase L completes (both success and graceful shutdown paths), invoke `/dso:end-session` with `--bump patch` to close out the worktree session and bump the patch version:

```
/dso:end-session --bump patch
```

This handles any remaining session cleanup: closing in-progress issues, committing straggling changes, syncing tickets, and producing a final task summary.

**If not in a worktree** (`test -d .git` — i.e., a regular checkout has `.git` as a *directory*, while a worktree has `.git` as a *file*): skip this phase — `/dso:end-session` is only for ephemeral worktree sessions.

---

## TDD Enforcement

TDD routing: read `prompts/tdd-enforcement-table.md`.

---

## Error Recovery

| Situation | Action |
|-----------|--------|
| Sub-agent introduces regression | Revert its changes (`git checkout -- <files>`), reopen issue, note the regression |
| Fix cascade (5+ different errors) | **STOP.** Run `/dso:fix-cascade-recovery`. Do not continue patching. |
| AWS auth expired (Phase B scan) | Skip proactive scan. Report to user: `aws sso login` |
| AWS auth expired (Tier 6 fix) | Sub-agent cannot proceed with infra fix. Report to user, recommend `aws sso login`, move to next task |
| DB not running | `make db-start` from app/. Wait for health check. |
| All sub-agents fail in a batch | Do not retry same session. Graceful shutdown. |
| Context compaction (Diagnostic Mode — Phase G/H) | Immediate graceful shutdown. Checkpoint everything. |
| Context compaction (Bug-Fix Mode) | Re-read fix-bug/SKILL.md inline. Check ticket CHECKPOINT comment for last completed step. Resume fix-bug at the next step — do NOT restart investigation from Step 0. |
| Git push fails (no upstream) | This is an ephemeral worktree branch — push is not required. Commit locally. |
| Merge to main fails (conflict) | Invoke `/dso:resolve-conflicts`. |
| CI fails on main after merge | Return to Phase C. Maximum 2 retries, then report to user for manual intervention. |
| Staging fails (Phase L) | Follow `/dso:validate-work` report. |
| Concurrent session detected | `lock-acquire` returns `LOCK_BLOCKED`. STOP. Report lock issue ID and worktree path to user. |
| Stale lock found | `lock-acquire` returns `LOCK_STALE` (auto-reclaimed), then acquires new lock. Proceed. |
