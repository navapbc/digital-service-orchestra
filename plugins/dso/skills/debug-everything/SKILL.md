---
name: debug-everything
description: Diagnose and fix all outstanding bugs (validation failures AND open ticket bugs), test failures, lint errors, and infrastructure issues using orchestrated sub-agents with TDD discipline
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

<SUB-AGENT-GUARD>
This skill requires the Agent tool to dispatch sub-agents. Before proceeding, check whether the Agent tool is available in your current context. If you cannot use the Agent tool (e.g., because you are running as a sub-agent dispatched via the Task tool), STOP IMMEDIATELY and return this error to your caller:

"ERROR: /dso:debug-everything cannot run in sub-agent context — it requires the Agent tool to dispatch its own sub-agents. Invoke this skill directly from the orchestrator instead."

Do NOT proceed with any skill logic if the Agent tool is unavailable.
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
/dso:debug-everything --aws            # Include proactive AWS infrastructure scan in Phase 1
```

**Note on AWS CLI**: The `--aws` flag controls only the *proactive* infrastructure scan in Phase 1. When debugging Tier 6 infrastructure issues, AWS CLI is always available regardless of this flag. If AWS auth is not configured, infrastructure checks are skipped gracefully.

## Orchestration Flow

**Step 0 (always first)**: GitHub Actions Pre-Scan — scans configured GHA workflows and creates bug tickets for untracked CI failures. Runs unconditionally before the open-bug-count pre-check so newly discovered failures are visible to mode selection. Skipped when `debug.gha_scan_enabled=false` or `debug.gha_workflows` is absent/empty.

Two entry modes: (1) **Bug-Fix Mode** — when open bug tickets exist, skip diagnostics/triage and apply `/dso:fix-bug` directly to each ticket, then enter Validation Mode (inner loop, bounded by `debug.max_fix_validate_cycles`); (2) **Diagnostic Mode** — when no open bugs exist, run Phase 1 diagnostic scan, Phase 2 triage, then fix in tier order (Phases 3-7). Both modes converge at Phase 8 (Full Validation). The outer loop (Phase 1-8, max 5 cycles) and inner validation loop (Bug-Fix Mode, max `debug.max_fix_validate_cycles`) are independent and must not nest multiplicatively.

**Bug-Fix Mode note**: In bug-fix mode, `/dso:fix-bug` is invoked at orchestrator level — reads fix-bug/SKILL.md inline directly, NOT via Task tool dispatch — preserving Agent tool access for investigation sub-agents.

---

## Migration Check

Idempotently apply plugin-shipped ticket migrations (marker-gated; no-op once migrated, never blocks the skill):

```bash
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
bash "$PLUGIN_SCRIPTS/ticket-migrate-brainstorm-tags.sh" 2>/dev/null || true  # shim-exempt: internal orchestration script
```

---

## Step 0: GitHub Actions Pre-Scan (/dso:debug-everything)

Scan configured GitHub Actions workflows for CI failures and create bug tickets for any untracked failures. This step runs **before** the open-bug-count pre-check so that any newly discovered CI failures are visible to the rest of the skill.

**Read config**:

```bash
GHA_SCAN_ENABLED=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config debug.gha_scan_enabled 2>/dev/null || echo "true")
GHA_WORKFLOWS=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config debug.gha_workflows 2>/dev/null || echo "")
```

**Gate checks (evaluate in order)**:

1. If `GHA_SCAN_ENABLED` is exactly `false`: log `GHA scan skipped: disabled via debug.gha_scan_enabled=false` and proceed to Phase 1. Do NOT dispatch any sub-agent.

2. If `GHA_WORKFLOWS` is absent or empty: log `GHA scan skipped: no workflows configured` and proceed to Phase 1. Do NOT dispatch any sub-agent.

**Dispatch GHA scanner sub-agent** (only when both gates pass):

```bash
# Resolve plugin root (available at session start via DSO shim; do not depend on $PLUGIN_ROOT which is set in Phase 1 Step 1)
_GHA_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
# Read worktree isolation config inline (DISPATCH_ISOLATION is set in Phase 1 Step 1, which runs after Step 0)
_GHA_ISOLATION_ENABLED=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config worktree.isolation_enabled 2>/dev/null || echo "false")
```

- Model: `haiku`
- Prompt: Read `${_GHA_PLUGIN_ROOT}/skills/debug-everything/prompts/gha-scanner.md` and use its contents as the sub-agent prompt. Inject `WORKFLOWS` (the value of `GHA_WORKFLOWS`) and `REPO_ROOT` (from `git rev-parse --show-toplevel`) into the prompt context.
- Isolation: apply `isolation: "worktree"` when `_GHA_ISOLATION_ENABLED` equals `true`.

**After sub-agent returns**:

- Parse the compact summary JSON from the sub-agent output: `{"workflows_checked": N, "tickets_created": N, "failures_already_tracked": N, "new_ticket_ids": [...]}`.
- Write the summary as a comment on the active epic ticket (if one is open):
  ```bash
  "$(git rev-parse --show-toplevel)/.claude/scripts/dso" ticket comment <epic-id> "GHA scan complete: <workflows_checked> workflows checked, <tickets_created> tickets created, <failures_already_tracked> already tracked. New tickets: <new_ticket_ids>"
  ```
- Log the single-line summary to session output.
- If `tickets_created > 0`: the new bug tickets (tagged `gha:<workflow-file-name>`) will be picked up by the open-bug-count pre-check in Step 1 and processed in Bug-Fix Mode.

---

## Phase 1: Full Diagnostic Scan + Clustering (/dso:debug-everything)

Run ALL diagnostic checks and cluster related failures. The orchestrator runs only Step 1 (session lock). Everything else is delegated.

### Step 1: Initialize & Acquire Session Lock (/dso:debug-everything)

**BEFORE RUNNING ANY STEP 1 SETUP: Check for open and in_progress bug tickets first.**

```bash
_open_bugs=$(.claude/scripts/dso ticket list --type=bug --status=open 2>/dev/null | grep -c '"ticket_id"' || echo 0)
_inprog_bugs=$(.claude/scripts/dso ticket list --type=bug --status=in_progress 2>/dev/null | grep -c '"ticket_id"' || echo 0)
OPEN_BUG_COUNT=$((_open_bugs + _inprog_bugs))
```

If `OPEN_BUG_COUNT > 0`: **STOP Step 1 setup. Skip the bash initialization, lock acquisition, cleanup, and interactivity question below. Proceed directly to Bug-Fix Mode.** (Step 1.5 is the formal gate; this pre-check ensures you reach it before executing any sub-steps.)

If `OPEN_BUG_COUNT == 0`: Continue with Step 1 setup below.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"
STAGING_URL="${STAGING_URL:-http://nava-lockpick-doc-to-logic-env-stage.eba-m8tugimv.us-east-2.elasticbeanstalk.com}"
EB_STAGING_ENV="${EB_STAGING_ENVIRONMENT:-nava-lockpick-doc-to-logic-env-stage}"
```

**Worktree isolation config** — read and apply `skills/shared/prompts/worktree-dispatch.md` for worktree isolation configuration. Read the config key before dispatching any sub-agents:

```bash
ISOLATION_ENABLED=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config worktree.isolation_enabled 2>/dev/null || true)
```

Set `DISPATCH_ISOLATION=true` when `ISOLATION_ENABLED` equals `true`; otherwise `DISPATCH_ISOLATION=false`. All sub-agent dispatches (Phase 2, Phase 4, Phase 5, Phase 6, Phase 7, Phase 8, Phase 10, Validation Mode) must pass `isolation: "worktree"` when `DISPATCH_ISOLATION=true`. Apply consistently — do not mix isolated and non-isolated dispatches within the same session.

**Read validation loop config** — load `debug.max_fix_validate_cycles` from project config:

```bash
_raw_max_cycles=$(bash "$PLUGIN_SCRIPTS/read-config.sh" debug.max_fix_validate_cycles 2>/dev/null || echo "")  # shim-exempt: internal orchestration script
```

Apply edge-case rules:
- Empty or missing → default `MAX_FIX_VALIDATE_CYCLES=3`
- Non-numeric → default `MAX_FIX_VALIDATE_CYCLES=3` with warning: `"WARNING: debug.max_fix_validate_cycles is not numeric ('$_raw_max_cycles') — defaulting to 3"`
- Value `<= 0` → `MAX_FIX_VALIDATE_CYCLES=0` (skip validation loop entirely — proceed directly to Phase 8 after Bug-Fix Mode)
- Value `> 10` → `MAX_FIX_VALIDATE_CYCLES=10` with warning: `"WARNING: debug.max_fix_validate_cycles ($raw_val) exceeds cap of 10 — capping at 10"`
- Otherwise → `MAX_FIX_VALIDATE_CYCLES=$_raw_max_cycles`

**Session lock** — prevents multiple `/dso:debug-everything` sessions from running concurrently:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-acquire "debug-everything"  # shim-exempt: internal orchestration script
```

The script outputs `LOCK_ID: <id>` on success, `LOCK_BLOCKED: <id>` with `LOCK_WORKTREE: <path>` if another session holds the lock, or `LOCK_STALE: <id>` if a stale lock was reclaimed before acquiring.

- **`LOCK_ID`**: Save for release in Phase 9. Also persist to artifact file for recovery after context compaction:
  ```bash
  source "${PLUGIN_ROOT}/hooks/lib/deps.sh"
  echo "$LOCK_ID" > "$(get_artifacts_dir)/debug-lock-id"
  ```
- **`LOCK_BLOCKED`**: **STOP.** Report to user: "Another `/dso:debug-everything` session is running from `<worktree>`. Wait for it to finish, or close `<lock-id>` to force-release."
- **`LOCK_STALE`**: Stale lock was auto-reclaimed. Proceed — the script acquired a new lock (printed on the next `LOCK_ID` line).

**Discovery cleanup** — remove stale discoveries from any previous session:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries  # shim-exempt: internal orchestration script
```

This ensures a fresh start — no stale discoveries from a previous session. Cleanup failure is non-fatal; log a warning and continue.

**Interactivity question** — ask whether the session can pause for user input:

```
AskUserQuestion: "Is this an interactive session? (yes/no — press Enter for yes)"
```

- **`yes` (or no answer / timeout / empty)**: `INTERACTIVE_SESSION=true` — default. Preserves current behavior where the skill pauses at gates for user approval.
- **`no`**: `INTERACTIVE_SESSION=false` — non-interactive mode. At any gate that would normally pause for user input, the skill defers instead of blocking:
  - Leave the bug open (do not attempt any fix requiring user input).
  - Add a machine-parseable comment: `INTERACTIVITY_DEFERRED: <gate_name> | <context_summary>` where `gate_name` is one of: `safeguard_approval`, `complex_escalation`, `file_overlap`, `oscillation_guard`, `bug_accountability`. `context_summary` includes enough state (ticket IDs, error summaries, conflicting agent IDs) for the next interactive session to resume.
  - Continue to the next bug or phase without blocking.

**Non-interactive deferral — all deferral decisions are made at the orchestrator level.** `fix-bug` sub-agents do NOT need to honor `INTERACTIVE_SESSION` themselves. The orchestrator intercepts `COMPLEX_ESCALATION` reports and any other escalation signals before they reach the user, and defers them per the rules below.

**Resume limitation (known)**: Phase 1 resume logic only scans `CHECKPOINT` lines in ticket comments — it does NOT scan `INTERACTIVITY_DEFERRED` lines. After a non-interactive session, you must manually run `.claude/scripts/dso ticket list --type=bug --status=open` and `.claude/scripts/dso ticket list --type=bug --status=in_progress` and check for `INTERACTIVITY_DEFERRED` comments on open or in_progress bugs to find items requiring follow-up in an interactive session.

**Resume check** — find and reuse previous work:

1. `.claude/scripts/dso ticket list` and grep for "Project Health Restoration"
2. If found: use that epic as the tracker (skip creating a new one in Phase 2)
3. Check in-progress issues: `.claude/scripts/dso ticket list` and grep for `in_progress`
4. For each in-progress issue: read notes via `.claude/scripts/dso ticket show <id>`, parse CHECKPOINT lines, and apply these rules:
   - **CHECKPOINT 6/6 ✓** — fast-close: verify files exist, close with `.claude/scripts/dso ticket transition <id> open closed`
   - **CHECKPOINT 5/6 ✓** — near-complete; fast-close without re-execution
   - **CHECKPOINT 3/6 ✓ or 4/6 ✓** — partial; re-dispatch with the checkpoint note as resume context
   - **CHECKPOINT 1/6 ✓ or 2/6 ✓** — early; revert to open: `.claude/scripts/dso ticket transition <id> open`
   - **No CHECKPOINT lines or malformed/ambiguous lines** — revert to open: `.claude/scripts/dso ticket transition <id> open`

### Step 1.5: BUG-FIX MODE GATE — Skip Diagnostics If Open Bugs Exist (/dso:debug-everything)

**Check for open and in_progress bug tickets before launching the diagnostic scan.** This is the Bug-Fix Mode entry gate:

```bash
_open_bugs=$(.claude/scripts/dso ticket list --type=bug --status=open 2>/dev/null | grep -c '"ticket_id"' || echo 0)
_inprog_bugs=$(.claude/scripts/dso ticket list --type=bug --status=in_progress 2>/dev/null | grep -c '"ticket_id"' || echo 0)
OPEN_BUG_COUNT=$((_open_bugs + _inprog_bugs))
```

- If `OPEN_BUG_COUNT > 0`: **Enter Bug-Fix Mode.** Skip Phase 1 diagnostic scan (Steps 0.5, 1a, 1b, 1c, 2) and Phase 2 triage entirely. Proceed to the **Bug-Fix Mode** section below.
- If `OPEN_BUG_COUNT == 0`: Continue to Step 0.5 (normal diagnostic flow).

### Step 0.5: Context Budget Check (/dso:debug-everything)

Before launching diagnostics, estimate context load:

```bash
.claude/scripts/dso estimate-context-load.sh debug-everything 2>/dev/null | tail -5
```

If the static context load is >10,000 tokens, trim `MEMORY.md` before continuing to avoid premature compaction (per CLAUDE.md). Removing stale/redundant entries from `MEMORY.md` is sufficient — aim to bring the static load under 10,000 tokens before proceeding.

### Step 1a: Run Validation Gate (/dso:debug-everything)

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

Pass these to the diagnostic sub-agent in Step 2.

### Step 1b: Pre-Flight Infrastructure Check (/dso:debug-everything)

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
- Both passing → proceed to Step 2.

### Step 1c: Check for Sprint Validation State (/dso:debug-everything)

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
     categories. Pass this context to the diagnostic sub-agent in Step 2.
   - Log: `"Loaded sprint validation state from <file> — categories passing in
     sprint post-batch: <list>. Will focus diagnostics on failing categories."`
3. **If no file exists or all files are stale (>1 hour)**: proceed with full
   diagnostics. Set `sprintContext = false`.

### Step 2: Launch Diagnostic & Clustering Sub-Agent (/dso:debug-everything)

Launch a **single sub-agent** that runs all diagnostics, collects verbose output, clusters related failures, and returns a structured failure inventory.

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/diagnostic-and-cluster.md` and use its contents as the sub-agent prompt.

**If `validatePassedAll = true`**: ALL validation categories passed. Append to the sub-agent prompt:
```
### Validation Gate Results (all passed)
validate.sh --ci reported ALL categories passing. Skip Step 1 (summary diagnostics)
and Step 2 verbose checks for format, ruff, mypy, unit tests, and e2e. Go directly
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
have the summary. In Step 2, only run verbose error collection for the FAILING
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

The sub-agent returns: the path to the diagnostic file + a ≤15-line summary (category counts + top-3 clusters + open bug count). The full report is saved to `$(get_artifacts_dir)/debug-diag.md` on disk; do NOT receive the full report inline. Store the `DIAGNOSTIC_FILE` path for Phase 2.

**Flow control**: If any inventory row has count > 0 OR open bugs exist, proceed to Phase 2. Only skip to Phase 9 if ALL validation categories pass AND zero open bugs.

---

## Bug-Fix Mode (/dso:debug-everything)

**Entry condition**: Open bug tickets detected in Step 1.5 (`OPEN_BUG_COUNT > 0`).

**Rationale**: When open bug tickets already exist, the diagnostic scan (Phase 1) and triage sub-agent (Phase 2) are unnecessary — they exist to *discover* new issues. Bug-Fix Mode skips both and applies `/dso:fix-bug` directly to each known ticket. **All bugs are in scope — including pre-existing ones.** "Pre-existing" means the bug existed before this session; it does not mean the bug should be skipped or deferred. Every open bug ticket must be investigated and resolved via `/dso:fix-bug`.

### What is skipped in Bug-Fix Mode

- **Diagnostic scan skipped** (Phase 1 Steps 0.5, 1a, 1b, 1c, 2): No `validate.sh --ci`, no preflight checks, no diagnostic sub-agent, no clustering.
- **Triage skipped** (Phase 2): No triage sub-agent dispatch, no new epic creation, no issue clustering.

<COMPACTION_RESUME>
**If resuming after an auto-compact event in Bug-Fix Mode**: First, re-establish OPEN_BUG_COUNT using the canonical bash approach — do NOT filter the output with Python-side type checking (`t.get('type') == 'bug'` always returns 0 because `ticket list --type=bug` strips the `type` field from returned objects):

```bash
_open_bugs=$(.claude/scripts/dso ticket list --type=bug --status=open 2>/dev/null | grep -c '"ticket_id"' || echo 0)
_inprog_bugs=$(.claude/scripts/dso ticket list --type=bug --status=in_progress 2>/dev/null | grep -c '"ticket_id"' || echo 0)
OPEN_BUG_COUNT=$((_open_bugs + _inprog_bugs))
```

Then re-read `$PLUGIN_ROOT/skills/fix-bug/SKILL.md` inline immediately — do NOT attempt to investigate from Step 0. Check the in-progress ticket's most recent CHECKPOINT comment to determine the last completed fix-bug step, then resume from the next step in fix-bug's pipeline:
- CHECKPOINT at Step 2 (investigation dispatched) → resume at Step 3 (analyze results)
- CHECKPOINT at Step 3 (hypothesis confirmed) → resume at Step 4 (fix approval) or Step 5 (RED test)
- CHECKPOINT at Step 5 (RED test written) → resume at Step 6 (implement fix)
- CHECKPOINT at Step 7 (fix verified) → resume at Step 8 (commit and close)
- No CHECKPOINT found → re-dispatch the investigation sub-agent from Step 2 (do NOT read test files, grep for root causes, or run tests without a specific hypothesis — that is unstructured investigation, not the fix-bug protocol)

**After the in-progress ticket completes**, do NOT stop — re-query remaining open and in_progress bugs and continue processing them in priority order (return to Bug-Fix Mode Execution step 1). The compaction event that triggered this resume does NOT signal Phase 9 shutdown. Phase 9 is only triggered by a compaction that occurs **during the current active session**. A compaction from a prior invocation that produced this resume context is historical state, not a live shutdown trigger.

**Re-assert delegation constraint after compaction**: The HARD-GATE from Bug-Fix Mode Execution step 2 applies with full force from this point forward — including to the first post-resume ticket. Do NOT investigate bugs inline. Do NOT modify code at the orchestrator level. EVERY bug ticket MUST be processed by reading `fix-bug/SKILL.md` inline and executing its steps — NOT by direct orchestrator investigation or editing. Emit the HARD-GATE token before any Edit/Write call: `HARD-GATE: CLEARED for ticket <id> — classification: <type>, investigation: <agent-id>, hypothesis: <confirmed/disproved>`. Compaction does not waive this gate — it strengthens the requirement to re-read fix-bug/SKILL.md before proceeding.
</COMPACTION_RESUME>

### Bug-Fix Mode Execution

1. **List all open and in_progress bug tickets**:

   ```bash
   { .claude/scripts/dso ticket list --type=bug --status=open; .claude/scripts/dso ticket list --type=bug --status=in_progress; } 2>/dev/null
   ```

   Collect all returned ticket IDs (deduplicate by `ticket_id` in case a ticket appears in both queries). Order by priority (P0 first, then P1, P2, P3, P4).

2. **For each open or in_progress bug ticket, invoke `/dso:fix-bug` at the orchestrator level**:

   **PER-TICKET GATE (enforce at the start of EVERY ticket iteration, not just the first):**
   Before processing each ticket, explicitly verify AND emit the verification token:
   - Has the investigation sub-agent (dso:bot-psychologist for llm-behavioral, or BASIC/INTERMEDIATE/ADVANCED for behavioral) been dispatched independently for THIS ticket? Reusing investigation findings from a prior ticket in this session is PROHIBITED — even when the bugs appear related. Each ticket requires its own independent sub-agent dispatch.
   - Have fix-bug Steps 1–5 been completed for THIS ticket specifically? Completion of Steps 1–5 for a previous ticket does NOT satisfy the requirement for the current ticket.
   - The fix-bug HARD-GATE ("Do NOT investigate inline", "Do NOT modify code until Steps 1–5 are complete") applies with full force on every iteration — ticket 1 and ticket 23 equally.

   **Emit this token before any Edit/Write call for this ticket** (ba41-8503):
   `HARD-GATE: CLEARED for ticket <id> — classification: <type>, investigation: <agent-id>, hypothesis: <confirmed/disproved>`
   If you cannot fill in all three fields, you have NOT completed Steps 1–5.

   Violation of this gate — including pre-writing fixes in sub-agent prompts, performing investigation at orchestrator level, or reusing prior ticket findings as a substitute for independent dispatch — must be treated as a process failure, not an efficiency optimization.

   > **Note on CLI_user tag**: If the ticket was tagged `CLI_user` (user-reported bug), fix-bug Step 1.5 will automatically skip Gate 1a intent-search. No special handling is needed here — the authoritative CLI_user check lives in fix-bug Step 1.5. Do NOT duplicate the check in debug-everything.

   Read `$PLUGIN_ROOT/skills/fix-bug/SKILL.md` inline and execute its steps directly — NOT via the Skill tool or Task tool. This orchestrator-level invocation (reads SKILL.md inline) preserves Agent tool access for fix-bug's investigation sub-agents (BASIC/INTERMEDIATE/ADVANCED) which require the Agent tool themselves.

   Pass the ticket ID as the bug context. When dispatching sub-agents in Bug-Fix Mode, always pass `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` in the sub-agent dispatch prompt so the sub-agent can locate host-project scripts and artifacts. When `DISPATCH_ISOLATION=true`, also add `isolation: "worktree"` to each fix-bug sub-agent dispatch.

   ```
   Bug ticket: <ticket-id>
   Title: <title from ticket show>
   ORCHESTRATOR_ROOT: <value of $(git rev-parse --show-toplevel)>
   ```

   **After the fix sub-agent returns** (per-ticket post-dispatch):
   - When `DISPATCH_ISOLATION=true`: follow `skills/shared/prompts/single-agent-integrate.md` to integrate the sub-agent's worktree changes back into the session branch.
   - When `DISPATCH_ISOLATION=false`: proceed with existing post-dispatch behavior unchanged.

3. **Error handling**: If `/dso:fix-bug` fails for a ticket (unrecoverable error, repeated failure, or explicit escalation), write a CHECKPOINT note and continue to the next ticket:

   ```bash
   .claude/scripts/dso ticket comment <id> "CHECKPOINT: Bug-Fix Mode — fix-bug failed: <error>. Resume from: re-attempt fix."
   ```

   Do NOT abort Bug-Fix Mode when a single ticket fails — process all remaining tickets.

4. **After all bug tickets have been attempted**, run the **Between-Batch GHA Refresh** before proceeding to Validation Mode.

### Between-Batch GHA Refresh (Bug-Fix Mode)

This step runs unconditionally after all bug tickets in the current batch have been attempted and before the Validation Mode entry — regardless of `MAX_FIX_VALIDATE_CYCLES` (including 0).

**Short-circuit checks** (check in order before dispatching sub-agent):

1. If `GHA_SCAN_ENABLED` is exactly `false`: log `GHA scan skipped: disabled via debug.gha_scan_enabled=false` and proceed to Validation Mode.
2. If `GHA_WORKFLOWS` is absent or empty: log `GHA scan skipped: no workflows configured` and proceed to Validation Mode.

**Dispatch GHA scanner sub-agent** (only when both checks pass):

- Sub-agent type: `general-purpose`
- Prompt: Read `${_GHA_PLUGIN_ROOT}/skills/debug-everything/prompts/gha-scanner.md` and use its contents as the sub-agent prompt. Inject `WORKFLOWS` (the value of `GHA_WORKFLOWS`) and `REPO_ROOT` (from `git rev-parse --show-toplevel`) into the prompt context.
- Isolation: apply `isolation: "worktree"` when `_GHA_ISOLATION_ENABLED` equals `true`.

**After sub-agent returns**:
- Parse the compact summary JSON: `{"workflows_checked": N, "tickets_created": N, "failures_already_tracked": N, "new_ticket_ids": [...]}`
- Write epic comment:
  ```bash
  "$(git rev-parse --show-toplevel)/.claude/scripts/dso" ticket comment <epic-id> "GHA between-batch scan: <workflows_checked> workflows checked, <tickets_created> tickets created, <failures_already_tracked> already tracked. New tickets: <new_ticket_ids>"
  ```
- If `tickets_created > 0`: re-query open bug ticket list and add new tickets to the queue for the next iteration (they will be picked up by Validation Mode's re-entry into Bug-Fix Mode on the next cycle).
- If sub-agent returns `GHA scan unavailable: workflow run tools not registered`: log the signal and proceed to Validation Mode without writing the epic comment.

**Re-query open and in_progress ticket list**:

After the scan completes (regardless of `tickets_created`), re-run:
```bash
{ .claude/scripts/dso ticket list --type=bug --status=open; .claude/scripts/dso ticket list --type=bug --status=in_progress; } 2>/dev/null
```
Use this refreshed list for the Validation Mode entry decision.

5. Proceed to **Validation Mode**.

---

## Validation Mode (/dso:debug-everything)

**Entry condition**: Entered after Bug-Fix Mode completes one full pass over all open bug tickets.

**Purpose**: Detect failures newly exposed by bug fixes (regressions or previously hidden issues), create tickets for them, and loop back to Bug-Fix Mode — up to `MAX_FIX_VALIDATE_CYCLES` iterations.

**Scope**: This is an INNER loop within the Bug-Fix Mode → Phase 8 flow. It is bounded by `debug.max_fix_validate_cycles` (configured at session start). The outer Phase 1→8 loop is separate and bounded by Phase 8's 5-cycle safety limit. These loops are independent and must NOT be conflated.

### Step 1: Check Iteration Count

Initialize on first entry: `VALIDATION_ITERATION=1`

On each re-entry (looping from Bug-Fix Mode): `VALIDATION_ITERATION=$((VALIDATION_ITERATION + 1))`

**Persist iteration count** as an epic ticket comment for resume continuity:

```bash
.claude/scripts/dso ticket comment <epic-id> "VALIDATION_LOOP_ITERATION: ${VALIDATION_ITERATION}/${MAX_FIX_VALIDATE_CYCLES}"
```

On resume (Step 1 resume check), parse existing `VALIDATION_LOOP_ITERATION:` comments to restore `VALIDATION_ITERATION` and `MAX_FIX_VALIDATE_CYCLES`.

**If `MAX_FIX_VALIDATE_CYCLES <= 0`**: Skip validation loop entirely. Proceed directly to Phase 8.

### Step 2: Run Diagnostic Scan After Bug-Fix

Reuse the same diagnostic sub-agent pattern as Phase 1. Dispatch a diagnostic sub-agent to scan for newly exposed failures:

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
1. Tickets already created by Phase 7 regression detection
2. Tickets from previous validation iterations (check `VALIDATION_LOOP_ITERATION:` comments to identify those iterations)
3. Tickets from original Phase 2 triage

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

Log: `"Max validation iterations (${MAX_FIX_VALIDATE_CYCLES}) reached — remaining issues reported as open tickets"`. Proceed to Phase 8.

**If new bugs were found AND `VALIDATION_ITERATION < MAX_FIX_VALIDATE_CYCLES`**:

New failures discovered. Loop back to Bug-Fix Mode with the newly created tickets:
- Update `OPEN_BUG_COUNT` to include `NEW_BUG_TICKETS`
- Return to Bug-Fix Mode (Step 2: process all open bug tickets by priority)

**If no new bugs were found**:

No new failures. The fix cycle is clean. Proceed to Phase 8.

---

## Phase 2: Triage & Issue Creation (/dso:debug-everything)

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
2. If `HAS_STAGING_ISSUES=true`: record staging symptoms for Phase 10 verification
3. Report triage summary to user:
   - Total distinct failures discovered
   - New issues created (with IDs and titles)
   - Pre-existing issues found (with IDs)
   - Epic ID
   - Recommended fix order by tier

**If `--dry-run`**: Stop here. Output the full triage report and exit.

---

## Phase 2.6: Safeguard Bug Analysis (/dso:debug-everything)

After triage, identify which issues touch safeguarded files and route them through user-approval before fixing.

### Step 1: Detect Safeguarded Issues (/dso:debug-everything)

Safeguarded file patterns (from CLAUDE.md rule 20):
- `${CLAUDE_PLUGIN_ROOT}/skills/**`, `${CLAUDE_PLUGIN_ROOT}/hooks/**`, `${CLAUDE_PLUGIN_ROOT}/docs/workflows/**`
- `.claude/settings.json`, `.claude/docs/**`
- `scripts/**`, `CLAUDE.md`

For each issue from the Phase 2 triage report, check if the issue description, title, or root cause references files matching these patterns. Build two lists:
- `SAFEGUARD_BUGS`: issues that require editing safeguarded files
- `NORMAL_BUGS`: all other issues (proceed directly to Phase 3)

If `SAFEGUARD_BUGS` is empty, skip to Phase 3.

### Step 2: Launch Analysis Sub-Agent (/dso:debug-everything)

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/safeguard-analysis.md` and use its contents as the sub-agent prompt. Pass the `SAFEGUARD_BUGS` list (IDs and titles) and `WORKTREE` name as context.

**Subagent**: `subagent_type="general-purpose"`, `model="opus"`
# Complex investigation: must read safeguarded files, understand bug context,
# and propose precise line-level fixes — requires deep code comprehension and judgment.
# (`error-debugging:error-detective` is NOT a valid subagent_type — use general-purpose
# with the named agent file loaded verbatim as the prompt.)

The sub-agent returns: path to proposals file + summary (count + per-bug one-liner).

### Step 3: Present Proposals to User (/dso:debug-everything)

Non-interactive: apply Non-Interactive Deferral Protocol (see Phase 1 Step 1) using gate_name=`safeguard_approval`. Auto-defer ALL safeguard bugs; skip to Phase 3 with `SAFEGUARD_BUGS` removed from the fix queue (they remain open).

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

Proceed to Phase 3 with the combined list of normal + approved bugs.

---

## Phase 3: Fix Planning (/dso:debug-everything)

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

**Load bug classification rules**: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/bug-accountability-guide.md` now. You will need these rules in Phase 10 Step 4; loading here avoids loading them when context is tighter.

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

## Phase 4: Auto-Fix Sub-Agent (Tiers 0-1) (/dso:debug-everything)

### Launch Auto-Fix Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/auto-fix.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `code_simplify` (see `agent-routing.conf`), `model="sonnet"`

### Orchestrator Actions After Sub-Agent Returns

1. Verify the sub-agent's report
2. Close any issues resolved by auto-fix: `.claude/scripts/dso ticket transition <id> open closed --reason="Fixed: resolved by auto-fix (format/lint)"`
3. Update the failure inventory with remaining errors
4. **CONTEXT ANCHOR**: After the commit workflow completes, continue immediately at Step 5 below (Phase 4). Do NOT stop or wait for user input after committing.

   Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline. Do NOT use the `/dso:commit` Skill tool — nested skill invocations do not return control to the orchestrator.
5. Remaining ruff violations that couldn't be auto-fixed become sub-agent tasks in Phase 5

---

## Phase 5: Sub-Agent Fix Batches (/dso:debug-everything)

For remaining failures (Tiers 2-7), launch sub-agent batches.

### Pre-Batch Checks

Before EVERY batch, run the shared pre-batch check script:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check --db  # --db for tiers 4-5  # shim-exempt: internal orchestration script
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check       # no --db for tiers 0-3, 6-7  # shim-exempt: internal orchestration script
```

The script outputs structured key-value pairs:
- `MAX_AGENTS: unlimited | N | 0` — dynamic batch size cap (see **MAX_AGENTS protocol** below)
- `SESSION_USAGE: normal | high | critical`
- `GIT_CLEAN: true | false` — if false, commit previous batch first
- `DB_STATUS: running | stopped | skipped` — if stopped, run `make db-start`

Exit 0 means all checks pass. Exit 1 means at least one check requires action (details in output).

**MAX_AGENTS protocol** — the `MAX_AGENTS` value from `agent-batch-lifecycle.sh pre-check` determines batch sizing dynamically. Three cases:

- **`MAX_AGENTS: unlimited`** — dispatch ALL candidates in a single batch with no artificial ceiling. Do NOT split into sub-batches or cap at any fixed number. Launch all Task calls in one message, each with `run_in_background: true`.
- **`MAX_AGENTS: N`** (a positive integer, e.g., `1`, `3`, `5`) — cap each batch at N sub-agents. If the candidate count exceeds N, split into sequential batches of at most N. Launch all Task calls in the batch within a single message, each with `run_in_background: true`.
- **`MAX_AGENTS: 0`** — skip sub-agent dispatch entirely. Do NOT launch any Task calls. Write a ticket comment on the epic noting dispatch was skipped due to resource constraints: `.claude/scripts/dso ticket comment <epic-id> "DISPATCH_SKIPPED: MAX_AGENTS=0 — resource constraints prevent sub-agent dispatch. Queued fixes: <list ticket IDs>"`. Proceed to Phase 9 (graceful shutdown).

**Context-check integration rationale**: Unlike `/dso:sprint` (which runs `agent-batch-lifecycle.sh context-check` proactively between batches), `/dso:debug-everything` does NOT invoke `context-check` as a separate step. Instead, it relies on two mechanisms: (1) `_compute_max_agents()` inside `pre-check` already reads `CLAUDE_CONTEXT_WINDOW_USAGE` and throttles `MAX_AGENTS` to `1` when context >= 90%, and (2) Phase 6 Step 8 detects literal context-compaction event banners for graceful shutdown. Proactive context-check adds overhead per batch without benefit because the pre-check signal already covers the throttling case, and debug-everything's shutdown trigger is the compaction event itself (not a pre-emptive estimate).

### Claim Tasks

```bash
.claude/scripts/dso ticket transition <id> in_progress
```

**Known-solution detection**: Before selecting `subagent_type` for a Tier 7 bug, check if its notes contain `SAFEGUARD APPROVED:` (written by Phase 2.6 Step 4). If present, classify as "known fix" — resolve via `discover-agents.sh` routing category `code_simplify` (see `agent-routing.conf`) and pass the approval note as `fix_guidance` in the prompt context.

### Blackboard Write and File Ownership Context

Before dispatching sub-agents, create the blackboard file and build per-agent file ownership context from the NxN conflict matrix computed in Phase 3:

1. **Write the blackboard**: Build a JSON object with a top-level `batch` array (matching `ticket next-batch --json` output format) from Phase 3's file impact analysis, then pipe it to `write-blackboard.sh`:
   ```json
   {
     "batch": [
       {"id": "lockpick-doc-to-logic-XXXX", "files": ["path/to/file1.py", "path/to/file2.py"]},
       {"id": "lockpick-doc-to-logic-YYYY", "files": []}
     ]
   }
   ```
   ```bash
   REPO_ROOT=$(git rev-parse --show-toplevel)
   echo "$BATCH_JSON" | .claude/scripts/dso write-blackboard.sh
   ```
   The top-level key must be `batch`. Each entry must use `id` (the ticket ID) and `files` (list of files_likely_modified). Do not use `tasks`, `agents`, `task_id`, or `files_owned` — those are internal blackboard schema keys, not input keys.
   If `write-blackboard.sh` fails, log a warning and continue without blackboard — sub-agents will receive empty `{file_ownership_context}`. Blackboard failure must not block sub-agent dispatch.

2. **Read the blackboard and build file ownership context**: Read the blackboard and construct a per-agent ownership string for each sub-agent:
   ```bash
   BLACKBOARD="${TMPDIR:-/tmp}/dso-blackboard-$(basename "$REPO_ROOT")/blackboard.json"
   ```
   For each agent (task), build a `file_ownership_context` string with the format:
   ```
   You own: file1.py, file2.py. Other agents own: <task-id-X> owns file3.py, file4.py; <task-id-Y> owns file5.py.
   ```
   If the blackboard file does not exist (due to earlier failure or degradation), use an empty string for `file_ownership_context`.

3. **Populate the placeholder**: Replace `{file_ownership_context}` with the per-agent ownership string built above. Each sub-agent receives its own tailored context showing which files it owns and which files other agents in the batch own.

### Sub-Agent Prompt Template

For each fix task, launch via the Task tool. **Launch all sub-agents in the batch within a single message**, each with `run_in_background: true` (without it, foreground calls execute serially).

**Agent description**: Derive from the ticket title — a 3-5 word human-readable summary (e.g., Fix review gate hash, not dso-abc1).

**Delegate to `/dso:fix-bug`**: Instead of selecting fix-task-tdd.md or fix-task-mechanical.md directly, delegate all bug resolution to `/dso:fix-bug`. The `dso:fix-bug` skill encapsulates the TDD vs. mechanical routing decision internally — it handles its own TDD enforcement and investigation routing.

**Complete assembled Task prompt** (individual bug — combine all three sections in order):

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

Add `isolation: "worktree"` to each Task dispatch when `DISPATCH_ISOLATION=true` (set during Step 1 per `skills/shared/prompts/worktree-dispatch.md`). Also pass `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` in the dispatch prompt so sub-agents can verify isolation.

**Cluster invocation** (for multiple related bugs in a cluster, resolved together):
```
/dso:fix-bug <id1> <id2> ...

### Triage Classification Context (pre-loaded — do not re-score)
Bug IDs: <id1>, <id2>
...

### File Ownership Context
{file_ownership_context}
```

**Pass triage classification as pre-loaded context** so dso:fix-bug's scoring rubric does not need to re-classify from scratch. Include in the sub-agent prompt:

```
### Triage Classification Context (pre-loaded — do not re-score)
Bug ID: <bug-id>
Triage tier: <tier-number>
Severity (from triage priority): <P0=critical/2pts | P1=high/2pts | P2=medium/1pt | P3=low/0pts>
Environment: <CI failure | staging | local — from triage report>
```

**Triage-to-scoring-rubric mapping** (how triage tier maps to dso:fix-bug scoring dimensions):
- **Tier 0-1 (mechanical)**: fix-bug classifies as mechanical, bypasses scoring rubric entirely
- **Tier 2+ (behavioral bugs)**: provide severity from triage priority (P0=critical/2pts, P1=high/2pts, P2=medium/1pt, P3=low/0pts), environment from triage report (CI failure/staging notes). This allows fix-bug to inherit the triage classification rather than re-score. Note: fix-bug performs its own post-investigation complexity evaluation (Step 4.5) by reading the `complexity-evaluator` named agent definition inline — it does not dispatch a sub-agent to avoid nested dispatch within a sub-agent context. Fix-bug will return a `COMPLEX_ESCALATION` report if the bug requires multi-agent planning.

**File ownership context**: Pass `{file_ownership_context}` from the blackboard step above in the sub-agent prompt. Each sub-agent receives its own tailored context showing which files it owns and which files other agents in the batch own.

### Subagent Type Selection

Resolve `subagent_type` via `discover-agents.sh` using the routing category from `agent-routing.conf`. Run `$PLUGIN_SCRIPTS/discover-agents.sh` and use the resolved agent for each category.  # shim-exempt: internal orchestration script

| Fix Category | Routing Category | `model` | Why This Routing |
|-------------|-----------------|---------|------------------|
| Type errors (mypy) | `mechanical_fix` | `sonnet` | Debugging specialist for errors and unexpected behavior |
| Unit test failures | `test_fix_unit` | `sonnet` | Test-specific debugging with testing framework knowledge |
| E2E test failures | `test_fix_e_to_e` | `sonnet` | General debugger for cross-cutting E2E issues |
| Lint violations (manual) | `code_simplify` | `sonnet` | Code quality specialist for clarity and consistency |
| Complex multi-file bugs | `complex_debug` | `opus` | Correlates errors across systems, identifies root causes |
| Migration/DB issues | `database-design:database-architect` | `sonnet` | Schema modeling, migration planning, DB architecture |
| Infrastructure issues (Tier 6) | `complex_debug` | `opus` | Complex debugging with AWS CLI access |
| Ticket bugs — known fix (SAFEGUARD APPROVED) | `code_simplify` | `sonnet` | Fix proposal already written; apply without investigation |
| Ticket bugs — code fixes (Tier 7) | `mechanical_fix` | `sonnet` | General debugging for tracked code bugs |
| Ticket bugs — tooling/scripts (Tier 7) | `code_simplify` | `sonnet` | Script and tooling fixes |
| Ticket bugs — investigation (Tier 7) | `complex_debug` | `opus` | Root cause analysis for investigation-type bugs |
| TDD test writing (for non-test bugs) | `test_write` | `sonnet` | Test automation specialist for writing new tests |
| Post-fix critic review | `feature-dev:code-reviewer` | `sonnet` | Code reviewer for root-cause-vs-symptom analysis |

**Note**: `error-debugging:error-detective` and `database-design:database-architect` are referenced directly because they are core agents that do not require optional plugin routing. `feature-dev:code-reviewer` is similarly a direct reference. All other agent types are resolved dynamically via `discover-agents.sh` and `agent-routing.conf` preference chains, falling back to `general-purpose` when the preferred plugin is not installed.

**Infrastructure sub-agents (Tier 6)** get additional instructions in their prompt:
```
### AWS CLI Access
You have full access to AWS CLI for diagnosing and resolving infrastructure issues.
Useful commands:
- `aws elasticbeanstalk describe-environment-health --environment-name $EB_STAGING_ENV --attribute-names All`
- `aws logs tail /aws/elasticbeanstalk/$EB_STAGING_ENV --since 1h`
- `aws sts get-caller-identity` (verify auth first)
If AWS auth is not configured, report this and recommend: `aws sso login`
```

**Escalation**: If a sub-agent fails, retry with `model: "opus"` before investigating manually.

---

## Phase 6: Post-Batch Checkpoint (/dso:debug-everything)

After ALL sub-agents in a batch return:

### Step 0: Dispatch Failure Recovery (/dso:debug-everything)

Before verifying results, check whether any sub-agent Task call returned an **infrastructure-level dispatch failure** (no `STATUS:` line, no `FILES_MODIFIED:` line, error message references agent type or internal errors — as opposed to task-level failures where the agent ran but produced incorrect work).

**For each dispatch failure:**
1. Retry with `subagent_type="general-purpose"`, same model and prompt. Log: `"Dispatch failure for task <id> with subagent_type=<original-type> — retrying with general-purpose."`
2. If retry fails: escalate model (sonnet → opus) and retry once more with `subagent_type="general-purpose"`.
3. If all retries fail: mark task as failed.

Dispatch failure retries are sequential (error recovery, not planned work) and do not count toward batch size limits.

### Step 0.5: Worktree Integration (/dso:debug-everything)

When `DISPATCH_ISOLATION=true`, sub-agents in Phase 5 ran in isolated worktree branches — their changes are NOT on the session branch in the orchestrator's CWD. Before any subsequent step runs `git diff` (Step 1a file-overlap, Step 1b critic review, Step 5 semantic conflict check) or `git commit` (Step 6), each sub-agent's worktree changes MUST be integrated onto the session branch.

**When `DISPATCH_ISOLATION=true`**: For each sub-agent that returned successfully (including any that succeeded on retry from Step 0), follow `skills/shared/prompts/single-agent-integrate.md` to integrate its worktree changes back into the session branch. This mirrors the Bug-Fix Mode per-result integration pattern (see Bug-Fix Mode Execution step 2 above) so downstream `git diff` / commit operations in Phase 6 observe the combined batch changes.

**When `DISPATCH_ISOLATION=false`**: Skip this step — sub-agents wrote directly to the session branch and the changes are already visible via `git diff` in Step 1a and beyond.

### Step 1: Verify Results (/dso:debug-everything)

For each sub-agent (including any that succeeded on retry), check the Task result:
- Did it report success?
- Were the expected files modified? (spot-check with Glob)
- Did it follow TDD? (check for new test files)

### Step 1a: File Overlap Check (Safety Net) (/dso:debug-everything)

Sub-agents may modify files beyond what their task description predicts. Check for actual file-level conflicts:

1. Collect modified files for each sub-agent (from Task result or `git diff --name-only`)
2. Run overlap detection:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh file-overlap \  # shim-exempt: internal orchestration script
     --agent=<task-id-1>:<file1>,<file2> \
     --agent=<task-id-2>:<file3>,<file4>
   ```
   Outputs `CONFLICTS: <N>` + one `CONFLICT:` line per overlap with `PRIMARY=<agent>` and `SECONDARY=<agent1>,<agent2>`. Exit 0 = no conflicts, exit 1 = conflicts.
3. If conflicts detected, for each conflicting file:
   - **Primary agent**: the one whose ticket issue is most directly about that file (highest priority or most file-specific)
   - **Secondary agents**: all others. Before reverting, capture each secondary agent's diff for the conflicting files. Then revert all at once: `git checkout -- <conflicting-files>`
   - Re-run secondary agents **one at a time in priority order** (not in parallel), each with original prompt plus a `### Conflict Resolution Context` block containing the captured diff and instruction to not overwrite the primary agent's changes. Commit each re-run before launching the next.
   - After each re-run: if agent only touched non-conflicting files → success. If it overwrote the same files again:
     - Non-interactive: apply Non-Interactive Deferral Protocol (see Phase 1 Step 1) using gate_name=`file_overlap`. Revert secondary agent's changes: `git checkout -- <conflicting-files>`. Proceed to Step 1b.
     - **Interactive mode**: Escalate to user, do not retry.
4. No conflicts → proceed to Step 1b

### Step 1b: Critic Review (Complex Fixes Only) (/dso:debug-everything)

For fixes that meet ANY of these criteria, launch a critic sub-agent before committing:
- Required `model: "opus"` (complex multi-file bugs)
- Tier 5-6 (integration / infrastructure)
- Modified 3+ files
- TDD was required (behavioral code change — not imports, annotations, or config)

**Before launching**, capture the current diff in the orchestrator:
```bash
git diff --stat   # save as {diff_stat}
git diff          # save as {full_diff}
```

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/critic-review.md` and use its contents as the sub-agent prompt. Replace the `{full_diff captured by orchestrator via \`git diff\`}` placeholder with the actual diff output.

**Subagent**: `subagent_type="general-purpose"`, `model="sonnet"`  # Tier 2: must evaluate root-cause-vs-symptom, regression risk, and convention violations from a raw diff — requires judgment across codebase context, not just output parsing. (`feature-dev:code-reviewer` is NOT a valid subagent_type — the Agent tool only accepts built-in types. Use general-purpose with the critic-review.md prompt loaded verbatim.)

**Orchestrator action**:
- `PASS` → proceed to Step 2
- `CONCERN` → evaluate. If valid: revert changes (`git checkout -- <files>`), reopen the issue with the concern noted in description for the next fix attempt. If false positive: proceed to Step 2.

**Oscillation guard**: Track critic outcomes per issue ID. On the 2nd CONCERN for
the same issue, invoke `/dso:oscillation-check` (sub-agent, model="sonnet"  # Tier 2: must compare structural diffs across fix iterations to detect oscillation patterns) with
context=critic. If it returns OSCILLATION:
- Non-interactive: apply Non-Interactive Deferral Protocol (see Phase 1 Step 1) using gate_name=`oscillation_guard`. Record both fix approaches and both critic concerns in the deferral comment. Leave the bug open. Do NOT retry.
- **Interactive mode**: Escalate to user with both fix approaches and both critic concerns. Do NOT retry.

### Step 2: Validate via Sub-Agent (/dso:debug-everything)

**Do NOT run validation directly in the orchestrator.** Launch a validation sub-agent:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/post-batch-validation.md` and use its contents as the sub-agent prompt. Replace `{list of files modified by batch}` with the actual file list from this batch.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh post-batch and relays output verbatim — pure command execution with one bounded LIKELY_CAUSE inference from provided file list

### Step 3: Handle Failures (/dso:debug-everything)

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

### Step 3a: COMPLEX Escalation Handling (/dso:debug-everything)


After fix-bug sub-agents return, parse each result for a `COMPLEX_ESCALATION` report. Fix-bug sub-agents emit this structured report when post-investigation complexity evaluation classifies a bug as requiring multi-agent planning (i.e., the bug is too complex for a solo fix sub-agent to resolve autonomously).

**Detection**: Scan each sub-agent result for the escalation signal:
```
COMPLEX_ESCALATION: true
```

**If a `COMPLEX_ESCALATION` signal is found**, parse the full escalation report fields from the sub-agent result (these fields match the COMPLEX_ESCALATION report format defined in `/dso:fix-bug` Step 4.5):
- `escalation_type`: `COMPLEX` (the fix scope is too large for a single bug fix track)
- `bug_id`: the bug ticket ID being escalated
- `investigation_tier_needed`: `orchestrator-level re-dispatch` (the fix requires orchestrator-level authority)
- `investigation_findings`: summary of root cause candidates, confidence, and evidence from investigation
- `escalation_reason`: why the fix is COMPLEX (e.g., cross-system refactor, multiple subsystems affected)

Non-interactive: apply Non-Interactive Deferral Protocol (see Phase 1 Step 1) using gate_name=`complex_escalation`. Do not invoke `/dso:fix-bug` at orchestrator level — defer the bug. Add to `COMPLEX_BUGS` list for session summary. Continue to next bug.

**Interactive mode (re-dispatch at orchestrator level)** — do NOT use a sub-agent for the re-dispatch — invoke `/dso:fix-bug` directly from the orchestrator:

1. Add a note to the bug ticket with the investigation findings:
   ```bash
   .claude/scripts/dso ticket comment <bug-id> "fix-bug escalation: COMPLEX — <escalation_reason>. Investigation found: <investigation_findings>. Requires <investigation_tier_needed> orchestrator-level re-dispatch."
   ```

2. Invoke `/dso:fix-bug` directly at orchestrator level (not as a Task sub-agent), passing the investigation findings as pre-loaded context so the orchestrator-level fix-bug can skip re-investigation:
   ```
   /dso:fix-bug <bug-id>
   ```
   Include the following escalation context block in the invocation prompt so `/dso:fix-bug` detects it via Sub-Agent Context Detection and populates the discovery file without re-running investigation:
   ```
   ### COMPLEX_ESCALATION Context (pre-loaded — skip to Step 4)
   escalation_type: COMPLEX
   bug_id: <bug-id>
   investigation_findings: <investigation_findings from sub-agent report>
   escalation_reason: <escalation_reason from sub-agent report>
   ```
   When `/dso:fix-bug` detects `COMPLEX_ESCALATION Context` in its invocation prompt, it writes the `investigation_findings` to the discovery file (`/tmp/fix-bug-discovery-<bug-id>.json`) and skips directly to Step 4 (Fix Approval) with the prior investigation as pre-loaded context.

3. Track all complex-escalated bugs in `COMPLEX_BUGS` list (entries: `{bug_id, escalation_reason, investigation_findings}`) for inclusion in the session summary.

**If no escalation signals are present**, proceed normally to Step 4.

### Step 4: Decision Log (/dso:debug-everything)

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

### Step 5: Semantic Conflict Check (/dso:debug-everything)

Before committing, run the semantic conflict check on the combined diff:

```bash
git diff | python3 "$PLUGIN_SCRIPTS/semantic-conflict-check.py"  # shim-exempt: internal orchestration script
```

Parse the JSON output:
- `"clean": true` — proceed with commit (Step 6).
- `"clean": false` — log conflicts, present to orchestrator for review. If any conflict has `"severity": "high"`, revert the conflicting files and re-dispatch the responsible sub-agent. If all conflicts are medium/low, note them in ticket and proceed.
- `"error"` field present — log warning, proceed with commit (graceful degradation). Semantic conflict check failure is non-fatal.

### Step 6: Commit & Sync (/dso:debug-everything)

**CONTEXT ANCHOR**: After the commit workflow completes, continue immediately at Step 7 (Discovery Collection) below. Do NOT stop or wait for user input after committing.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline. Do NOT use the `/dso:commit` Skill tool — nested skill invocations do not return control to the orchestrator, causing the debug-everything workflow to stall waiting for user input.

**Blackboard cleanup**: After the commit, run `write-blackboard.sh --clean` to remove the blackboard file:
```bash
.claude/scripts/dso write-blackboard.sh --clean
```
If blackboard cleanup fails, log a warning and continue — cleanup failure is non-fatal and must not block the next batch or graceful shutdown.

### Step 7: Discovery Collection (/dso:debug-everything)

After the commit completes and before launching the next batch, collect discoveries from sub-agents:

```bash
DISCOVERIES=$(.claude/scripts/dso collect-discoveries.sh --format=prompt)
```

If discoveries exist (non-empty and not just `"None."`), inject the `## PRIOR_BATCH_DISCOVERIES` section into the next batch's sub-agent prompts by appending it to the fix-task prompt context.

If `collect-discoveries.sh` fails, log a warning and proceed without discovery propagation (graceful degradation).

### Step 8: Continuation Decision (/dso:debug-everything)

**Default is CONTINUE, not shutdown.** Only shut down on a concrete, verifiable signal — never on a "felt sense" of context fullness (a54a-95fc).

- If you received a **literal context-compaction event banner** from Claude Code during this session → Phase 9 (graceful shutdown). **CRITICAL**: On compaction, LOCK_ID may be lost from context. Recover it from the artifact file before Phase 9: `LOCK_ID=$(cat "$(get_artifacts_dir)/debug-lock-id" 2>/dev/null)`. Phase 9 MUST release the lock and write epic summary notes — these are the two obligations that prior sessions lost after compaction.
- If more failures remain in this tier → Phase 5 (next batch)
- If tier is clear → Phase 7 (re-diagnose)

Do NOT shut down based on an internal estimate of session context usage. There is no way to self-measure context fill. If no compaction event occurred, keep fixing bugs.

---

## Phase 7: Re-Diagnose & Next Tier (/dso:debug-everything)

After completing a tier, re-validate to check for transitive resolutions.

### Step 1: Launch Re-Diagnosis Sub-Agent (/dso:debug-everything)

Same pattern as Phase 6 Step 2, but run the full diagnostic set:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/tier-transition-validation.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh tier-transition and relays structured output verbatim — no interpretation required, pass/fail reporting only

### Step 2: Update Failure Inventory (/dso:debug-everything)

Compare sub-agent report against the inventory:
- Resolved without direct fix (transitive resolution) → close their issues
- New failures not in original inventory (regressions) → treat as P0
- Remaining failures → proceed to next tier

### Step 3: Continue or Finish (/dso:debug-everything)

- If failures remain in higher tiers → return to Phase 3
- If all tiers are clear → proceed to Phase 8 (Full Validation)

---

## Phase 8: Full Validation (/dso:debug-everything)

When all known issues across all tiers are addressed, delegate validation to a sub-agent.

**CI is checked post-merge, not here.** Phase 8 validates local code health only (format, lint, tests). CI runs on main, not the worktree branch — checking CI here would show the pre-fix state and produce a false failure. CI status is verified in Phase 10 after merging to main.

### Launch Validation Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/full-validation.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh full --skip-ci and relays structured output verbatim — pure command execution, ALL_PASS/SOME_FAIL is explicit in script output

### Interpret Result

- **`ALL_PASS` + zero open bugs** → Phase 9 (Completion)
- **`SOME_FAIL` or open bugs remain** → Return to Phase 2 (re-triage via sub-agent)

This is a remediation pass. Apply the same discipline: triage new failures, create issues, fix in tier order.

**Safety bound**: Maximum 5 full diagnostic cycles (Phase 1→8 loops). If the project is not healthy after 5 cycles, proceed to graceful shutdown and report to the user.

---

## Phase 9: Issue Closure & Graceful Shutdown (/dso:debug-everything)

### On Success (All Checks Pass + Zero Open Bugs)

1. Clean up discoveries and release the session lock:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries  # shim-exempt: internal orchestration script
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-release <lock-id> "All diagnostics passing, all bugs resolved"  # shim-exempt: internal orchestration script
   .claude/scripts/dso ticket comment <epic-id> "Health restored."
   .claude/scripts/dso ticket transition <epic-id> open closed
   ```
   Discovery cleanup failure is non-fatal; log a warning and continue with lock release.
2. Proceed to **Phase 10** (Merge to Main & Verify).

### On Graceful Shutdown

1. Clean up discoveries and release the session lock:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries  # shim-exempt: internal orchestration script
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-release <lock-id> "Graceful shutdown — work remains"  # shim-exempt: internal orchestration script
   ```
   Discovery cleanup failure is non-fatal; log a warning and continue with lock release.
2. Do NOT launch new sub-agents
3. Run final format + test:
   ```bash
   cd $REPO_ROOT/app && make test-unit-only
   ```
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
7. Commit partial work and proceed to **Phase 10** (Merge to Main & Verify). After Phase 10 completes successfully, check context usage:
   - If context usage <70% AND remaining open bugs exist: return to **Phase 2** (continue fixing — do NOT go to Phase 11)
   - If context usage ≥70% OR no remaining bugs: proceed to **Phase 11** (/dso:end-session)

---

## Phase 10: Merge to Main & Verify (/dso:debug-everything)

This phase is REQUIRED for both success and graceful shutdown. The `/dso:debug-everything` command is NOT complete until changes are merged to main and CI passes.

### Steps 1, 1b, 2: Merge + CI + Validate (sub-agent)

Dispatch a merge-and-verify sub-agent:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/phase-10-merge-verify.md` and follow it. Pass as context:
- `REPO_ROOT`: absolute path
- `HAS_STAGING_ISSUES`: from Phase 2 triage
- `PATH_TYPE`: result of `test -f "$REPO_ROOT/.git" && echo worktree || echo main`
- Whether Phase 8 ran (success path vs graceful shutdown) — needed for scope file

**Subagent**: `subagent_type="general-purpose"`, `model="sonnet"`

**Interpret the return:**
- `MERGE_STATUS: conflict|error|push-failed` → relay error to user and stop
- `CI_STATUS: fail` → return to Phase 2 (re-triage); max 2 retries
- `CI_STATUS: fail-max-retries` → stop, report to user
- `VALIDATE_STATUS: ci-fail|regression` → return to Phase 2
- `VALIDATE_STATUS: staging-fail` → follow the recommendation in DETAILS
- All `ok/pass` → proceed to Step 4

### Step 4: Report Completion (/dso:debug-everything)

#### Open Bug Accountability (required — both success and shutdown paths)

Read `$PLUGIN_ROOT/skills/debug-everything/prompts/bug-accountability-guide.md` for classification rules (loaded in Phase 3 — use cached version if already in context).

Run:
```bash
.claude/scripts/dso ticket list
```

For every open bug, apply the three-outcome classification (Fixed / Escalated / Deferred) per the guide. Close fixed bugs with `.claude/scripts/dso ticket transition <id> open closed`.

Non-interactive: apply Non-Interactive Deferral Protocol (see Phase 1 Step 1) using gate_name=`bug_accountability`. Include deferred bugs in the session summary under a `DEFERRED (non-interactive)` section rather than `ESCALATED`. Previously deferred `COMPLEX_ESCALATION` bugs (Phase 6 Step 3a) surface here as open bugs awaiting escalation.

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

After Phase 10 completes (or after Phase 10 is skipped due to unrecoverable errors), write a session summary to auto-memory for future `/dso:debug-everything` sessions to consult during Phase 3 (fix planning):

```
## Debug Session: {date}
- Failures: {N} discovered, {M} fixed, {K} deferred
- Tiers reached: {highest tier completed}
- Most effective agents: {agent type} for {category} (N successes)
- Least effective agents: {agent type} for {category} (N failures/escalations)
- Recurring patterns: {patterns seen in 2+ sessions, if auto-memory has prior entries}
- Recommendations: {observations for preventing recurrence}
```

If any bugs were escalated as COMPLEX by fix-bug sub-agents (via `COMPLEX_ESCALATION` in Phase 6 Step 3a), append a dedicated section to the session summary **and present it to the user** before Phase 11:

```
## Bugs escalated as COMPLEX (re-dispatched at orchestrator level)
- <bug-id>: <title> — escalated (COMPLEX): <escalation_reason> — outcome: <fixed|still-open>
```

One line per COMPLEX-escalated bug. If no COMPLEX escalations occurred this session, omit this section entirely.

Write to: `{auto-memory-dir}/debug-sessions.md` (append, don't overwrite).

**On subsequent runs**: During Phase 3 (Fix Planning), read `debug-sessions.md` if it exists. Use prior session data to:
- Prefer agent types that succeeded for similar failure categories
- Avoid agent types that required escalation for similar issues
- Flag recurring patterns to the user as potential systemic issues

---

## Phase 11: End Session (/dso:debug-everything)

After Phase 10 completes (both success and graceful shutdown paths), invoke `/dso:end-session` with `--bump patch` to close out the worktree session and bump the patch version:

```
/dso:end-session --bump patch
```

This handles any remaining session cleanup: closing in-progress issues, committing straggling changes, syncing tickets, and producing a final task summary.

**If not in a worktree** (`test -d .git`): skip this phase — `/dso:end-session` is only for ephemeral worktree sessions.

---

## TDD Enforcement

TDD routing: read `prompts/tdd-enforcement-table.md`.

---

## Error Recovery

| Situation | Action |
|-----------|--------|
| Sub-agent introduces regression | Revert its changes (`git checkout -- <files>`), reopen issue, note the regression |
| Fix cascade (5+ different errors) | **STOP.** Run `/dso:fix-cascade-recovery`. Do not continue patching. |
| AWS auth expired (Phase 1 scan) | Skip proactive scan. Report to user: `aws sso login` |
| AWS auth expired (Tier 6 fix) | Sub-agent cannot proceed with infra fix. Report to user, recommend `aws sso login`, move to next task |
| DB not running | `make db-start` from app/. Wait for health check. |
| All sub-agents fail in a batch | Do not retry same session. Graceful shutdown. |
| Context compaction (Diagnostic Mode — Phase 5/6) | Immediate graceful shutdown. Checkpoint everything. |
| Context compaction (Bug-Fix Mode) | Re-read fix-bug/SKILL.md inline. Check ticket CHECKPOINT comment for last completed step. Resume fix-bug at the next step — do NOT restart investigation from Step 0. |
| Git push fails (no upstream) | This is an ephemeral worktree branch — push is not required. Commit locally. |
| Merge to main fails (conflict) | Invoke `/dso:resolve-conflicts`. |
| CI fails on main after merge | Return to Phase 2. Maximum 2 retries, then report to user for manual intervention. |
| Staging fails (Phase 10) | Follow `/dso:validate-work` report. |
| Concurrent session detected | `lock-acquire` returns `LOCK_BLOCKED`. STOP. Report lock issue ID and worktree path to user. |
| Stale lock found | `lock-acquire` returns `LOCK_STALE` (auto-reclaimed), then acquires new lock. Proceed. |
