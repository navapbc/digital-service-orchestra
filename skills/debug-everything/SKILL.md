---
name: debug-everything
description: Diagnose and fix all outstanding bugs (validation failures AND open ticket bugs), test failures, lint errors, and infrastructure issues using orchestrated sub-agents with TDD discipline
user-invocable: true
---

# Debug Everything: Full Project Health Restoration

You are a **Senior Software Engineer at Google** brought in to restore a project to full health. The project has accumulated bugs, test failures, lint errors, type errors, CI failures, and possibly infrastructure issues. **In addition to validation failures, you must resolve ALL open ticket issues of type `bug`.** Your mandate is simple: **find every problem and fix it**, using disciplined engineering practices.


## Mindset

- **You own everything.** You did not create these bugs, but they are your responsibility now. There is no "out of scope."
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

```
Phase 1 (Diagnostic + Clustering sub-agent) → Phase 2 (Triage sub-agent)
  → [dry-run: stop] or [execute: Phase 2.5 (Complexity Gate)]
Phase 2.5 → [all Tier 0-1: skip gate] or [above Tier 1: haiku evaluator per bug → TRIVIAL/MODERATE pass-through, COMPLEX → epic]
Phase 2.5 → Phase 2.6 (Safeguard Analysis)
Phase 2.6 → [no safeguard bugs: Phase 3] [safeguard bugs: present proposals → user approval → Phase 3]
Phase 3 → Phase 4 (Auto-Fix, Tiers 0-1) → Phase 5 (Sub-Agent Batches)
  → Phase 6 (Checkpoint) → [more in tier: Phase 5] [tier clear: Phase 7]
Phase 7 (Re-Diagnose) → [more tiers: Phase 3] [all done: Phase 8]
Phase 8 (Full Validation sub-agent) → [ALL PASS: Phase 9 → Phase 10 (Merge/CI/Staging) → Phase 11 (/dso:end-session)] [FAIL: Phase 2]
Graceful shutdown: Phase 5/6 session limit or compaction → Phase 9 → Phase 10 (Merge Checkpoint) → [context <70% AND open bugs: Phase 2] [context ≥70% OR no bugs: Phase 11 (/dso:end-session)]
```

---

## Epic Lifecycle

`/dso:debug-everything` creates a "Project Health Restoration" epic to track all discovered bugs for a session. The epic follows this lifecycle:

1. **Creation** (Phase 2): The triage sub-agent creates the epic via `/dso:brainstorm` and sets all discovered issues as children via `tk parent <issue-id> <epic-id>`.
2. **Resume** (Phase 1, on re-entry): If a "Project Health Restoration" epic already exists from a previous session, it is reused — no new epic is created. New issues are added as children of the existing epic.
3. **Closure on success** (Phase 9, "On Success"): When all checks pass and zero open bugs remain, the epic is closed with `tk close <epic-id>` after adding a "Health restored." note.
4. **Left open on graceful shutdown** (Phase 9, "On Graceful Shutdown"): When the session shuts down with work remaining, the epic is left open with a summary note listing resolved vs. remaining issues. The next session resumes it.

---

## Phase 1: Full Diagnostic Scan + Clustering (/dso:debug-everything)

Run ALL diagnostic checks and cluster related failures. The orchestrator runs only Step 1 (session lock). Everything else is delegated.

### Step 1: Initialize & Acquire Session Lock (/dso:debug-everything)

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"
STAGING_URL="${STAGING_URL:-http://nava-lockpick-doc-to-logic-env-stage.eba-m8tugimv.us-east-2.elasticbeanstalk.com}"
EB_STAGING_ENV="${EB_STAGING_ENVIRONMENT:-nava-lockpick-doc-to-logic-env-stage}"
```

**Session lock** — prevents multiple `/dso:debug-everything` sessions from running concurrently:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-acquire "debug-everything"
```

The script outputs `LOCK_ID: <id>` on success, `LOCK_BLOCKED: <id>` with `LOCK_WORKTREE: <path>` if another session holds the lock, or `LOCK_STALE: <id>` if a stale lock was reclaimed before acquiring.

- **`LOCK_ID`**: Save for release in Phase 9.
- **`LOCK_BLOCKED`**: **STOP.** Report to user: "Another `/dso:debug-everything` session is running from `<worktree>`. Wait for it to finish, or close `<lock-id>` to force-release."
- **`LOCK_STALE`**: Stale lock was auto-reclaimed. Proceed — the script acquired a new lock (printed on the next `LOCK_ID` line).

**Discovery cleanup** — remove stale discoveries from any previous session:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries
```

This ensures a fresh start — no stale discoveries from a previous session. Cleanup failure is non-fatal; log a warning and continue.

**Resume check** — find and reuse previous work:

1. `tk ready` and grep for "Project Health Restoration"
2. If found: use that epic as the tracker (skip creating a new one in Phase 2)
3. Check in-progress issues: `tk ready` and grep for `in_progress`
4. For each in-progress issue: read notes via `tk show <id>`, parse CHECKPOINT lines, and apply these rules:
   - **CHECKPOINT 6/6 ✓** — fast-close: verify files exist, close with `tk close <id>`
   - **CHECKPOINT 5/6 ✓** — near-complete; fast-close without re-execution
   - **CHECKPOINT 3/6 ✓ or 4/6 ✓** — partial; re-dispatch with the checkpoint note as resume context
   - **CHECKPOINT 1/6 ✓ or 2/6 ✓** — early; revert to open: `tk status <id> open`
   - **No CHECKPOINT lines or malformed/ambiguous lines** — revert to open: `tk status <id> open`

### Step 0.5: Context Budget Check (/dso:debug-everything)

Before launching diagnostics, estimate context load:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
$REPO_ROOT/scripts/estimate-context-load.sh debug-everything 2>/dev/null | tail -5
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
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh preflight --start-db
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

**Subagent**: `subagent_type="error-debugging:error-detective"`, `model="opus"`  # Complex investigation: must correlate failures across validation categories, cluster related errors, and distinguish root causes from symptoms in complex output

The sub-agent returns: the path to the diagnostic file + a ≤15-line summary (category counts + top-3 clusters + open bug count). The full report is saved to `$(get_artifacts_dir)/debug-diag.md` on disk; do NOT receive the full report inline. Store the `DIAGNOSTIC_FILE` path for Phase 2.

**Flow control**: If any inventory row has count > 0 OR open bugs exist, proceed to Phase 2. Only skip to Phase 9 if ALL validation categories pass AND zero open bugs.

---

## Phase 2: Triage & Issue Creation (/dso:debug-everything)

Delegate ALL triage work to a sub-agent. The orchestrator passes the diagnostic report and receives back issue IDs.

### Launch Triage Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/triage-and-create.md` and use its contents as the sub-agent prompt. Pass the diagnostic file path as context — do NOT append the full report inline:

```
DIAGNOSTIC_FILE: $(get_artifacts_dir)/debug-diag.md
```

If all validation categories passed but open ticket bugs exist, also append: `All validation categories passed — only open ticket bugs need triage. Skip cluster cross-referencing (no validation failures to cluster). Assign all bugs to Tier 7.`

If resuming an existing tracker, append: `Existing epic ID: <epic-id>. Do NOT create a new epic. Set new issues as children of this epic with tk parent <issue-id> <epic-id>.`

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

## Phase 2.5: Complexity Gate (/dso:debug-everything)

After triage, classify each bug's complexity before dispatching fix sub-agents. This gate prevents solo fix sub-agents from attempting repairs that require multi-agent planning.

### Step 1: Tier 0-1 Bypass (/dso:debug-everything)

Bugs classified at **Tier 0 or Tier 1** (format errors, lint violations, import errors, mechanical type fixes) skip Phase 2.5 entirely and proceed directly to fix dispatch. Do NOT dispatch a complexity evaluator for these bugs — mechanical fixes are always autonomous.

Partition the triage list:
- `BYPASS_BUGS`: bugs at Tier 0 or Tier 1 → skip evaluator, pass straight through to fix dispatch
- `GATE_BUGS`: bugs above Tier 1 → proceed to Step 2

If `GATE_BUGS` is empty, skip to Phase 2.6.

### Step 2: Haiku Evaluator Dispatch (/dso:debug-everything)

For each bug in `GATE_BUGS`, dispatch a haiku sub-agent to classify its complexity using the shared evaluator prompt.

**Sub-agent prompt template** (one sub-agent per bug, dispatched in parallel, max 5 at a time):

```
Read the shared complexity evaluator prompt at:
  ${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/complexity-evaluator.md

Use its rubric to evaluate the following bug ticket: <bug-id>

Load the ticket via: tk show <bug-id>

Return the JSON output defined by the evaluator's Output Schema section.
```

**Subagent**: `subagent_type="general-purpose"`, `model="haiku"`

**Graceful degradation**: If a sub-agent fails, times out, or returns output with no valid `classification` field (TRIVIAL, MODERATE, or COMPLEX), log a warning:
```
WARNING: Complexity evaluator failed for <bug-id> — falling through to fix dispatch
```
Treat the bug as TRIVIAL and add it to the fix-dispatch queue. Do NOT block the session.

### Step 3: Apply /dso:debug-everything Routing Rules (/dso:debug-everything)

For each evaluated bug, apply the `/dso:debug-everything` routing rule (user-confirmed):

| Classification | Routing |
|---|---|
| TRIVIAL | Pass through to fix dispatch unchanged |
| MODERATE | **De-escalate → TRIVIAL** — pass through to fix dispatch (MODERATE bugs are well-understood enough for a solo fix sub-agent in /dso:debug-everything) |
| COMPLEX | Route to epic (see Step 4) |

### Step 4: COMPLEX Routing (/dso:debug-everything)

For each bug classified as COMPLEX, create an epic using `/dso:brainstorm`:

1. Invoke `/dso:brainstorm` to create the epic:
   ```
   /dso:brainstorm
   ```
   Provide the following context when brainstorm asks "What feature or capability are you trying to build?":
   > Fix (complex): <bug title>. This is a complex bug fix that requires multi-agent planning. Bug ID: <bug-id>. Complexity classification: COMPLEX. The evaluator found: <reasoning from complexity evaluator>. Priority: P2.

   Follow the `/dso:brainstorm` phases (Socratic dialogue, approach design, spec validation) to create a well-defined epic.

2. After `/dso:brainstorm` Phase 3 creates the epic, set a dependency from the bug to the new epic:
   ```bash
   tk dep <bug-id> <new-epic-id>
   ```
3. Add a routing note on the bug:
   ```bash
   tk add-note <bug-id> "Routed to epic <epic-id> — scope or fix complexity requires multi-agent planning before implementation"
   ```
4. Remove the bug from the fix-dispatch queue. Continue processing remaining bugs.

Track all COMPLEX-routed bugs in `COMPLEX_BUGS` list (entries: `{bug_id, epic_id, title}`) for inclusion in the session summary.

### Step 5: Build Final Fix Queue (/dso:debug-everything)

Merge the remaining bugs into a single fix-dispatch list:
- `BYPASS_BUGS` (Tier 0-1, no evaluation needed)
- `GATE_BUGS` classified TRIVIAL or MODERATE (de-escalated to TRIVIAL)

COMPLEX-routed bugs are excluded — they have been handed off to epics.

Proceed to Phase 2.6 with the final fix queue.

---

## Phase 2.6: Safeguard Bug Analysis (/dso:debug-everything)

After the complexity gate, identify which issues touch safeguarded files and route them through user-approval before fixing.

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

**Subagent**: `subagent_type="error-debugging:error-detective"`, `model="opus"`
# Complex investigation: must read safeguarded files, understand bug context,
# and propose precise line-level fixes — requires deep code comprehension and judgment

The sub-agent returns: path to proposals file + summary (count + per-bug one-liner).

### Step 3: Present Proposals to User (/dso:debug-everything)

Read the proposals file from disk. Present each proposal to the user:

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
  tk add-note <id> "SAFEGUARD APPROVED: user approved editing <file>. Proposed fix: <description>"
  ```
- **Deferred bugs**: Leave open with note:
  ```bash
  tk add-note <id> "SAFEGUARD DEFERRED: requires editing <file>, deferred by user."
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

Within each tier, group independent fixes into batches of up to 5 sub-agents:
1. Fixes that unblock other fixes (dependency order first)
2. Fixes affecting the most files/tests (largest blast radius)
3. Independent fixes that can be parallelized
4. **File overlap assessment via static analysis + NxN conflict matrix**:

   For each candidate issue in the batch:
   a. Extract seed file paths from the issue description/triage report
   b. Run `$REPO_ROOT/scripts/analyze-file-impact.py --root $REPO_ROOT/app <seed-files>` to get
      `files_likely_modified` and `files_likely_read` for each candidate (timeout: 30s)
   c. **Graceful degradation**: If `analyze-file-impact.py` is missing, errors, or times out,
      fall back to text-based file extraction from issue descriptions (existing behavior).
      Debug sessions must not break if static analysis is unavailable.

   After computing file impact for all candidates, build an **NxN pairwise overlap matrix**:
   - For each pair of issues (i, j), check whether their `files_likely_modified` sets intersect
   - **Write-write conflicts** (both issues modify the same file): defer the lower-priority
     issue to the next batch. The higher-priority issue (lower priority number, or earlier
     in dependency order) keeps its slot.
   - **Read-read overlap** (`files_likely_read` intersections) is allowed — only write-write
     conflicts trigger deferral
   - Log the conflict matrix to stderr for observability, using the same format as
     `$REPO_ROOT/scripts/sprint-next-batch.sh`:
     ```
     CONFLICT_MATRIX: <issue-A> x <issue-B> -> overlap on <file> (deferred: <issue-B>)
     ```

   This deterministic, zero-LLM-cost approach replaces the previous sub-agent dispatch for
   overlap checking. See `$REPO_ROOT/scripts/sprint-next-batch.sh` lines 545-583 for the
   reference greedy selection algorithm with file-overlap detection.

---

## Phase 4: Auto-Fix Sub-Agent (Tiers 0-1) (/dso:debug-everything)

### Launch Auto-Fix Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/auto-fix.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `code_simplify` (see `agent-routing.conf`), `model="sonnet"`

### Orchestrator Actions After Sub-Agent Returns

1. Verify the sub-agent's report
2. Close any issues resolved by auto-fix: `tk add-note <id> "Resolved by auto-fix (format/lint)"` then `tk close <id>`
3. Update the failure inventory with remaining errors
4. **CONTEXT ANCHOR**: After the commit workflow completes, continue immediately at Step 5 below (Phase 4). Do NOT stop or wait for user input after committing.

   Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline. Do NOT use the `/commit` Skill tool — nested skill invocations do not return control to the orchestrator.
5. Remaining ruff violations that couldn't be auto-fixed become sub-agent tasks in Phase 5

---

## Phase 5: Sub-Agent Fix Batches (/dso:debug-everything)

For remaining failures (Tiers 2-7), launch sub-agent batches.

### Pre-Batch Checks

Before EVERY batch, run the shared pre-batch check script:

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check --db  # --db for tiers 4-5
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check       # no --db for tiers 0-3, 6-7
```

The script outputs structured key-value pairs:
- `MAX_AGENTS: 1 | 5` — use as `max_agents`
- `SESSION_USAGE: normal | high`
- `GIT_CLEAN: true | false` — if false, commit previous batch first
- `DB_STATUS: running | stopped | skipped` — if stopped, run `make db-start`

Exit 0 means all checks pass. Exit 1 means at least one check requires action (details in output).

**Batch size limit**: Launch at most 5 Task calls in a single message. All foreground Tasks block until they return — you cannot exceed the limit mid-flight. Before each batch, verify: how many tasks am I about to launch? If > 5, split into multiple batches.

### Claim Tasks

```bash
tk status <id> in_progress
```

**Known-solution detection**: Before selecting `subagent_type` for a Tier 7 bug, check if its notes contain `SAFEGUARD APPROVED:` (written by Phase 2.6 Step 4). If present, classify as "known fix" — resolve via `discover-agents.sh` routing category `code_simplify` (see `agent-routing.conf`) and pass the approval note as `fix_guidance` in the prompt context.

### Blackboard Write and File Ownership Context

Before dispatching sub-agents, create the blackboard file and build per-agent file ownership context from the NxN conflict matrix computed in Phase 3:

1. **Write the blackboard**: Build a JSON object with a top-level `batch` array (matching `sprint-next-batch.sh --json` output format) from Phase 3's file impact analysis, then pipe it to `write-blackboard.sh`:
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
   echo "$BATCH_JSON" | "$REPO_ROOT/scripts/write-blackboard.sh"
   ```
   The top-level key must be `batch`. Each entry must use `id` (the ticket ID) and `files` (list of files_likely_modified). Do not use `tasks`, `agents`, `task_id`, or `files_owned` — those are internal blackboard schema keys, not input keys.
   If `write-blackboard.sh` fails, log a warning and continue without blackboard — sub-agents will receive empty `{file_ownership_context}`. Blackboard failure must not block sub-agent dispatch.

2. **Read the blackboard and build file ownership context**: Read `.worktree-blackboard.json` and construct a per-agent ownership string for each sub-agent:
   ```bash
   BLACKBOARD="$REPO_ROOT/.worktree-blackboard.json"
   ```
   For each agent (task), build a `file_ownership_context` string with the format:
   ```
   You own: file1.py, file2.py. Other agents own: <task-id-X> owns file3.py, file4.py; <task-id-Y> owns file5.py.
   ```
   If the blackboard file does not exist (due to earlier failure or degradation), use an empty string for `file_ownership_context`.

3. **Populate the placeholder**: When filling the fix-task prompt template, replace `{file_ownership_context}` with the per-agent ownership string built above. Each sub-agent receives its own tailored context showing which files it owns and which files other agents in the batch own.

### Sub-Agent Prompt Template

For each fix task, launch via the Task tool. **Launch all sub-agents in the batch within a single message** (parallel tool calls).

Sub-agent prompt: Select the appropriate template based on the TDD Enforcement table:
- **TDD required** → Read `$PLUGIN_ROOT/skills/debug-everything/prompts/fix-task-tdd.md`
- **TDD not required** → Read `$PLUGIN_ROOT/skills/debug-everything/prompts/fix-task-mechanical.md`

Fill in the `{placeholders}` with issue-specific details (title, ID, category, error output, root cause location, and `{file_ownership_context}` from the blackboard step above) before passing to the sub-agent.

### Subagent Type Selection

Resolve `subagent_type` via `discover-agents.sh` using the routing category from `agent-routing.conf`. Run `$PLUGIN_SCRIPTS/discover-agents.sh` and use the resolved agent for each category.

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
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh file-overlap \
     --agent=<task-id-1>:<file1>,<file2> \
     --agent=<task-id-2>:<file3>,<file4>
   ```
   Outputs `CONFLICTS: <N>` + one `CONFLICT:` line per overlap with `PRIMARY=<agent>` and `SECONDARY=<agent1>,<agent2>`. Exit 0 = no conflicts, exit 1 = conflicts.
3. If conflicts detected, for each conflicting file:
   - **Primary agent**: the one whose ticket issue is most directly about that file (highest priority or most file-specific)
   - **Secondary agents**: all others. Before reverting, capture each secondary agent's diff for the conflicting files. Then revert all at once: `git checkout -- <conflicting-files>`
   - Re-run secondary agents **one at a time in priority order** (not in parallel), each with original prompt plus a `### Conflict Resolution Context` block containing the captured diff and instruction to not overwrite the primary agent's changes. Commit each re-run before launching the next.
   - After each re-run: if agent only touched non-conflicting files → success. If it overwrote the same files again → escalate to user, do not retry.
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

**Subagent**: `subagent_type="feature-dev:code-reviewer"`, `model="sonnet"`  # Tier 2: must evaluate root-cause-vs-symptom, regression risk, and convention violations from a raw diff — requires judgment across codebase context, not just output parsing

**Orchestrator action**:
- `PASS` → proceed to Step 2
- `CONCERN` → evaluate. If valid: revert changes (`git checkout -- <files>`), reopen the issue with the concern noted in description for the next fix attempt. If false positive: proceed to Step 2.

**Oscillation guard**: Track critic outcomes per issue ID. On the 2nd CONCERN for
the same issue, invoke `/dso:oscillation-check` (sub-agent, model="sonnet"  # Tier 2: must compare structural diffs across fix iterations to detect oscillation patterns) with
context=critic. If it returns OSCILLATION, escalate to user with both fix
approaches and both critic concerns. Do NOT retry.

### Step 2: Validate via Sub-Agent (/dso:debug-everything)

**Do NOT run validation directly in the orchestrator.** Launch a validation sub-agent:

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/post-batch-validation.md` and use its contents as the sub-agent prompt. Replace `{list of files modified by batch}` with the actual file list from this batch.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh post-batch and relays output verbatim — pure command execution with one bounded LIKELY_CAUSE inference from provided file list

### Step 3: Handle Failures (/dso:debug-everything)

| Sub-agent outcome | Action |
|------------------|--------|
| Success + tests pass | `tk add-note <id> "Fixed: <summary>"` then `tk close <id>` |
| Partial success | `tk add-note <id> "Partial: <details>."` |
| Failure | `tk status <id> open` then `tk add-note <id> "Failed: <error>."` |
| Regression | Revert changes (`git checkout -- <files>`), reopen, note regression |

**Bug close constraint (enforced by hookify)**: Only close a bug issue if the note references specific changed files (code fix) OR explicitly escalates to the user. Investigation findings alone are never sufficient.
- `tk add-note <id> "Fixed: added comment_penalty to quality_helpers.py"` (code change)
- `tk add-note <id> "Escalated to user: code path is correct, no fix possible"` (escalation)
- Do NOT close with only `tk add-note <id> "Investigated: code path is correct"` — use add-note for findings, then escalate or fix before closing

### Step 4: Decision Log (/dso:debug-everything)

Record the batch decisions and outcomes on the epic for observability:

```bash
tk add-note <epic-id> "BATCH {N} | Tier {T}
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
git diff | python3 $REPO_ROOT/scripts/semantic-conflict-check.py
```

Parse the JSON output:
- `"clean": true` — proceed with commit (Step 6).
- `"clean": false` — log conflicts, present to orchestrator for review. If any conflict has `"severity": "high"`, revert the conflicting files and re-dispatch the responsible sub-agent. If all conflicts are medium/low, note them in ticket and proceed.
- `"error"` field present — log warning, proceed with commit (graceful degradation). Semantic conflict check failure is non-fatal.

### Step 6: Commit & Sync (/dso:debug-everything)

**CONTEXT ANCHOR**: After the commit workflow completes, continue immediately at Step 7 (Discovery Collection) below. Do NOT stop or wait for user input after committing.

Read and execute `${CLAUDE_PLUGIN_ROOT}/docs/workflows/COMMIT-WORKFLOW.md` inline. Do NOT use the `/commit` Skill tool — nested skill invocations do not return control to the orchestrator, causing the debug-everything workflow to stall waiting for user input.

**Blackboard cleanup**: After the commit, run `write-blackboard.sh --clean` to remove the blackboard file:
```bash
"$REPO_ROOT/scripts/write-blackboard.sh" --clean
```
If blackboard cleanup fails, log a warning and continue — cleanup failure is non-fatal and must not block the next batch or graceful shutdown.

### Step 7: Discovery Collection (/dso:debug-everything)

After the commit completes and before launching the next batch, collect discoveries from sub-agents:

```bash
DISCOVERIES=$($REPO_ROOT/scripts/collect-discoveries.sh --format=prompt)
```

If discoveries exist (non-empty and not just `"None."`), inject the `## PRIOR_BATCH_DISCOVERIES` section into the next batch's sub-agent prompts by appending it to the fix-task prompt context.

If `collect-discoveries.sh` fails, log a warning and proceed without discovery propagation (graceful degradation).

### Step 8: Continuation Decision (/dso:debug-everything)

- If context compaction occurred → Phase 9 (graceful shutdown)
- If session usage >90% → Phase 9 (graceful shutdown)
- If more failures remain in this tier → Phase 5 (next batch)
- If tier is clear → Phase 7 (re-diagnose)

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

### Launch Validation Sub-Agent

Sub-agent prompt: Read `$PLUGIN_ROOT/skills/debug-everything/prompts/full-validation.md` and use its contents as the sub-agent prompt.

**Subagent**: Resolve via `discover-agents.sh` routing category `test_fix_unit` (see `agent-routing.conf`), `model="haiku"`  # Tier 1: runs validate-phase.sh full and relays structured output verbatim — pure command execution, ALL_PASS/SOME_FAIL is explicit in script output

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
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-release <lock-id> "All diagnostics passing, all bugs resolved"
   tk add-note <epic-id> "Health restored."
   tk close <epic-id>
   ```
   Discovery cleanup failure is non-fatal; log a warning and continue with lock release.
2. Proceed to **Phase 10** (Merge to Main & Verify).

### On Graceful Shutdown

1. Clean up discoveries and release the session lock:
   ```bash
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries
   $PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-release <lock-id> "Graceful shutdown — work remains"
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
   tk add-note <id> "Session shutdown. Progress: <summary>. Next: <what remains>."
   ```
6. Update the epic with remaining work summary:
   ```bash
   # List remaining open children
   tk children <epic-id>
   # Add a note summarizing what remains
   tk add-note <epic-id> "Graceful shutdown. Resolved: <N resolved>/<M total> issues. Remaining open: <list IDs and titles>. Next session should resume with tk ready."
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
tk ready; tk blocked
```

For every open bug, apply the three-outcome classification (Fixed / Escalated / Deferred) per the guide. Close fixed bugs with `tk close`. Present escalated bugs to the user.

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

If any bugs were routed to epics by Phase 2.5 (COMPLEX classification), append a dedicated section to the session summary **and present it to the user** before Phase 11:

```
## Epics requiring user attention
- <epic-id>: <title> (addresses bug <bug-id>)
```

One line per COMPLEX-routed bug. If no COMPLEX bugs were found this session, omit this section entirely.

Write to: `{auto-memory-dir}/debug-sessions.md` (append, don't overwrite).

**On subsequent runs**: During Phase 3 (Fix Planning), read `debug-sessions.md` if it exists. Use prior session data to:
- Prefer agent types that succeeded for similar failure categories
- Avoid agent types that required escalation for similar issues
- Flag recurring patterns to the user as potential systemic issues

---

## Phase 11: End Session (/dso:debug-everything)

After Phase 10 completes (both success and graceful shutdown paths), invoke `/dso:end-session` to close out the worktree session:

```
/dso:end-session
```

This handles any remaining session cleanup: closing in-progress issues, committing straggling changes, syncing tickets, and producing a final task summary.

**If not in a worktree** (`test -d .git`): skip this phase — `/dso:end-session` is only for ephemeral worktree sessions.

---

## TDD Enforcement

The orchestrator uses this table to decide whether to include TDD instructions in each sub-agent's prompt. The sub-agent prompt template (Phase 5) contains the full RED-GREEN-VALIDATE flow.

| Issue Type | TDD Required? | Why |
|-----------|---------------|-----|
| Runtime error without test | **YES** | Behavioral bug — most important TDD case |
| Logic bug (wrong output) | **YES** | Test proves correct behavior, prevents recurrence |
| Data corruption / state bug | **YES** | Test captures the exact failure condition |
| MyPy type error (complex) | **YES** | Multi-file type mismatches may cause runtime errors |
| MyPy type error (simple) | NO | Missing annotation or obvious fix — mypy itself is the test |
| Ruff lint violation | NO | Style/safety, not behavioral |
| Unit test failure | NO — failing test IS the RED test | Make it pass |
| E2E test failure | NO — failing test IS the RED test | Make it pass |
| Import error | NO | Mechanical fix — existing tests will validate |
| Config / environment issue | NO | Not testable via unit test |
| Infrastructure issue | CASE-BY-CASE | Code-fixable: yes. Config-only: no |
| Ticket bug (code/logic) | **YES** | Behavioral bug — test proves correct behavior |
| Ticket bug (tooling/script) | NO | Script behavior verified manually or by existing tests |
| Ticket bug (investigation) | NO | Investigation produces findings, not code |

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
| Context compaction | Immediate graceful shutdown. Checkpoint everything. |
| Git push fails (no upstream) | This is an ephemeral worktree branch — push is not required. Commit locally. |
| Merge to main fails (conflict) | Invoke `/dso:resolve-conflicts` to analyze and propose resolutions. Trivial conflicts (imports, whitespace, non-overlapping additions) are auto-resolved if validation passes. Semantic/ambiguous conflicts require human approval. If `/dso:resolve-conflicts` is unavailable or the user declines all proposals, relay the conflict error for manual resolution. |
| CI fails on main after merge | Return to Phase 2. Maximum 2 retries, then report to user for manual intervention. |
| Staging fails (Phase 10) | `/dso:validate-work` handles retry logic, screenshot evidence, and specific recommendations for all staging failure modes (deploy not ready, test fails, Playwright unreachable, AWS auth expired). Follow its report. For staging bug investigation, use `/dso:playwright-debug` 3-tier process (code analysis -> targeted browser_run_code -> full MCP only as last resort). |
| Concurrent session detected | `lock-acquire` returns `LOCK_BLOCKED`. STOP. Report lock issue ID and worktree path to user. |
| Stale lock found | `lock-acquire` returns `LOCK_STALE` (auto-reclaimed), then acquires new lock. Proceed. |
