# Dispatch Fix Batch (Two-Phase Parallel Bug-Resolution Loop)

Loaded by `/dso:debug-everything` from both **Bug-Fix Mode Execution step 2** and **Phase G** (tiers 2–7). This is the single shared bug-resolution loop. The two modes differ only in what populates the list of bugs entering this loop:

- **Bug-Fix Mode** — pre-existing open bug tickets (tier 7), gathered in Bug-Fix Mode step 1.
- **Diagnostic Mode (Phase G)** — bugs discovered/triaged by Phases B–C–D + remaining failures from Phase F (tiers 2–7).

Once a chunk reaches this prompt, the dispatch mechanics are identical.

## Architecture: two-phase pipeline with ticket-scratch handoff

`/dso:fix-bug` Phase C dispatches investigator sub-agents via the Agent tool. Sub-agents launched via the Agent tool cannot dispatch their own sub-agents (hard Claude Code architectural constraint). To both (a) preserve `/dso:fix-bug`'s investigation protocol and (b) run N bugs in parallel, this loop splits fix-bug into two sub-agent dispatches per bug, with `ticket scratch` carrying the investigation result between them:

| Phase | Dispatch | fix-bug coverage | Sub-agent does | Output to orchestrator |
|-------|----------|------------------|----------------|------------------------|
| **1. Investigation** | parallel batch (`MODE: investigation-only`) | Phase A → Phase D Step 4 | Investigates **inline** (Read/Grep/Bash — no nested Agent dispatch); writes `fix-bug:investigation` scratch entry; terminates | compact summary: `INVESTIGATION_COMPLETE / COMPLEXITY / FIXABLE / SCRATCH_KEY` |
| **2. Fix application** | parallel batch (normal mode) | Phase C Step 0 Path A → Phase I | Loads `fix-bug:investigation` from scratch (fast-forwards Phase C); writes RED test, applies fix, commits | compact summary: bug_id + commit hash + status |

The orchestrator's context never sees the bulk investigation findings — they live in scratch. Only compact summaries cross the orchestrator boundary, giving ~10× context savings over a sequential `fix-bug` per bug.

The fix-bug skill's Phase C Step 0 (Path A / Path B / Path C) is the contract endpoint for this two-phase split. See `skills/fix-bug/SKILL.md` Phase C Step 0 and Phase D Step 4.

## 1. Pre-batch checks

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check --db   # tiers 4-5  # shim-exempt: internal orchestration script
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check        # tiers 0-3, 6-7  # shim-exempt: internal orchestration script
```

Outputs `MAX_AGENTS`, `SESSION_USAGE`, `GIT_CLEAN`, `DB_STATUS`. Exit 1 ⇒ at least one check requires action.

**MAX_AGENTS protocol**:
- `unlimited` — dispatch ALL candidates in one batch, each with `run_in_background: true` in a single message.
- positive integer `N` — cap each phase's batch at N; split into sequential batches of at most N if needed. The cap applies independently to the investigation phase and the fix phase.
- `0` — skip dispatch entirely. Comment on epic: `DISPATCH_SKIPPED: MAX_AGENTS=0 — resource constraints prevent sub-agent dispatch. Queued fixes: <list>`. Proceed to Phase K.

`/dso:debug-everything` does NOT invoke `context-check` separately because (1) `_compute_max_agents` inside `pre-check` already reads `CLAUDE_CONTEXT_WINDOW_USAGE` and throttles `MAX_AGENTS` to `1` at ≥ 90%, and (2) Phase H Step 13 detects literal context-compaction event banners.

## 2. Claim tasks

```bash
.claude/scripts/dso ticket transition <id> in_progress
```

**Known-solution detection**: if a Tier 7 ticket has `SAFEGUARD APPROVED:` (written by Phase D), classify as "known fix" — resolve via `code_simplify` routing category and pass the approval note as `fix_guidance` in prompt context.

## 3. Blackboard write

Build a JSON object matching `sprint-next-batch.sh --json` format from Phase E's file-impact analysis:  # tickets-boundary-ok: documentation reference to internal orchestration helper, not a tracker access
```json
{
  "batch": [
    {"id": "<ticket-id>", "files": ["path/to/file1.py", "path/to/file2.py"]},
    {"id": "<ticket-id>", "files": []}
  ]
}
```

```bash
echo "$BATCH_JSON" | .claude/scripts/dso write-blackboard.sh
```

Top-level key MUST be `batch`. Each entry uses `id` and `files`. If `write-blackboard.sh` fails, log warning, continue with empty `{file_ownership_context}` — must not block dispatch.

## 4. Build per-agent file-ownership context

Read the blackboard:
```bash
BLACKBOARD="${TMPDIR:-/tmp}/dso-blackboard-$(basename "$REPO_ROOT")/blackboard.json"
```

For each agent, build `file_ownership_context`:
```
You own: file1.py, file2.py. Other agents own: <task-id-X> owns file3.py, file4.py; <task-id-Y> owns file5.py.
```

Empty string when blackboard is unavailable.

## 5. Phase 1 — Investigation batch (parallel)

Dispatch ONE sub-agent per bug in the chunk using the Agent (Task) tool, all in a single message, each with `run_in_background: true`. Set `isolation: "worktree"` when `DISPATCH_ISOLATION=true` and inject `SESSION_BRANCH` / `SESSION_HEAD` into each prompt. Do NOT inject the orchestrator's session-worktree absolute path (per bug 9679-695c-6e11-4d95).

Description: 3–5 word summary derived from ticket title (e.g., "Investigate review gate hash"), prefixed with the literal `Investigate:` token.

**Investigation prompt** (per-bug):

```
/dso:fix-bug <bug-id>

MODE: investigation-only

### Two-Phase Pipeline Notice
You are running the investigation half of /dso:debug-everything's two-phase
parallel pipeline. Per fix-bug Phase C Step 0 Path B:
  1. Investigate inline using Read / Grep / Bash. Do NOT dispatch investigator
     sub-agents — sub-agents launched via the Agent tool cannot dispatch their
     own sub-agents (hard Claude Code constraint).
  2. Apply the investigator agent rubric inline: five-whys, hypothesis
     generation, empirical validation against running tests/code, root-cause
     candidates with confidence + evidence.
  3. At the end of Phase D Step 4, write the investigation envelope to
     ticket scratch under key `fix-bug:investigation` and TERMINATE.
  4. Do NOT proceed to Phase E. The orchestrator dispatches the fix-
     application sub-agent in Phase 2.

### Triage Classification Context (pre-loaded — do not re-score)
Bug ID: <bug-id>
Triage tier: <tier-number>
Severity (from triage priority): <P0=critical/2pts | P1=high/2pts | P2=medium/1pt | P3=low/0pts>
Environment: <CI failure | staging | local — from triage report>

### File Ownership Context
{file_ownership_context}
```

After all investigation sub-agents return, classify routing eligibility for Phase 2 directly from the **compact summary** in each sub-agent's stdout. The compact summary carries all six routing tokens (`INVESTIGATION_COMPLETE`, `COMPLEXITY`, `FIXABLE`, `MANUAL_APPROVAL_NEEDED`, `COMPLEX_ESCALATION`, `SCRATCH_KEY`) so the orchestrator does not need to re-open the scratch entry to decide routing:

- `COMPLEX_ESCALATION: true` → record `COMPLEX_ESCALATION: <bug-id>` in the tracking comment; do NOT auto-dispatch — the orchestrator handles via `/dso:brainstorm`; exclude from Phase 2
- `MANUAL_APPROVAL_NEEDED: true` → record `MANUAL_APPROVAL_QUEUED: <bug-id>` in the tracking comment; defer to user; exclude from Phase 2
- `FIXABLE: true` (and neither flag above) → include in Phase 2 fix batch
- `FIXABLE: false` (and neither flag above) → record `INVESTIGATION_FIXABLE_FALSE: <bug-id>` in the tracking comment; exclude from Phase 2

Token precedence: `COMPLEX_ESCALATION` > `MANUAL_APPROVAL_NEEDED` > `FIXABLE` (a single bug may carry multiple flags; the most-restrictive classification wins).

If any sub-agent fails to emit `INVESTIGATION_COMPLETE` on its final line, treat that bug as **investigation-failed**; do NOT include in Phase 2; record `INVESTIGATION_FAILED: <bug-id>` in the tracking comment and move on. Investigation failures do not block other bugs in the batch.

The scratch entry itself is consumed by the Phase 2 fix-application sub-agent, not by this orchestrator step. Each fixable bug's scratch entry MUST contain either the compact projection (under the 4 KB scratch ceiling) or the oversize-fallback envelope with `scratch_overflow=true` + `discovery_file=<path>`. The Phase 2 sub-agent transparently follows either path (see Path A in fix-bug Phase C Step 0).

## 6. Conflict-aware Phase 2 grouping

Re-read each fixable bug's `file_impact` (the orchestrator already has this from Phase E and the blackboard, but the investigation may have refined the file list — re-read scratch for the updated set):

```bash
.claude/scripts/dso ticket show <bug-id> | jq '.file_impact'
```

**Group fixable bugs into sub-batches** such that no two bugs in the same sub-batch touch overlapping files. The simplest heuristic:

1. Sort fixable bugs by descending priority (P0 first).
2. For each bug, scan its file set against the file sets already claimed by prior sub-batches in this dispatch round.
3. Place the bug in the first sub-batch that has no file overlap; if none qualifies, open a new sub-batch.

The number of sub-batches must respect `MAX_AGENTS`. If `MAX_AGENTS=N`, dispatch the first N non-conflicting bugs in this round; defer the rest to the next round.

## 7. Phase 2 — Fix-application batch (parallel)

Dispatch one sub-agent per bug in the conflict-safe sub-batch, all in a single message, each with `run_in_background: true`. Set `isolation: "worktree"` when `DISPATCH_ISOLATION=true` and inject `SESSION_BRANCH` / `SESSION_HEAD` per the same rules as Phase 1.

Description: prefix with `Fix:` (e.g., "Fix review gate hash").

**Fix-application prompt** (per-bug):

```
/dso:fix-bug <bug-id>

### Two-Phase Pipeline Notice
You are running the fix-application half of /dso:debug-everything's two-phase
parallel pipeline. The investigation has already been performed and written to
ticket scratch by an earlier sub-agent. Per fix-bug Phase C Step 0 Path A:
  1. Read `fix-bug:investigation` from ticket scratch and treat its embedded
     Investigation RESULT envelope as the output of Phase C Step 1 — SKIP the
     investigator sub-agent dispatch.
  2. Proceed directly to Phase C Step 2 (Hypothesis Validation Gate) using the
     scratch findings.
  3. Continue through Phases D–I as usual: RED test, fix, GREEN test, commit
     per COMMIT-WORKFLOW.md, close ticket.

### Triage Classification Context (pre-loaded — do not re-score)
Bug ID: <bug-id>
Triage tier: <tier-number>
Severity (from triage priority): <P0=critical/2pts | P1=high/2pts | P2=medium/1pt | P3=low/0pts>
Environment: <CI failure | staging | local — from triage report>

### File Ownership Context
{file_ownership_context}
```

After all fix sub-agents return, collect compact summaries (bug_id + commit hash + status) and proceed to Section 9 (Chunk wrap-up) below.

**Triage-to-scoring mapping** (unchanged from prior single-phase loop):
- Tier 0–1 (mechanical): fix-bug bypasses scoring rubric.
- Tier 2+ (behavioral): provide severity + environment from triage. fix-bug performs its own post-investigation complexity evaluation (Phase D Step 2) by reading the `complexity-evaluator` named agent definition inline — it does NOT dispatch a sub-agent (avoids nested dispatch within sub-agent context). Fix-bug returns `COMPLEX_ESCALATION` if multi-agent planning is needed.

## 8. Subagent type selection

See `agent-routing-table.md` for the full table.

## 9. Chunk wrap-up (ci-pr mode)

Execute this section after all Phase 2 fix sub-agents have returned their compact summaries. In `local` mode (DEBUG_MODE=direct or absent) skip to step 4 (reconciliation only).

### Step 1 — Sub-branch invariant pre-flight

Before opening a PR, confirm the sub-branch was created locally and pushed to origin:

```bash
.claude/scripts/dso assert-batch-branch.sh "<sub-branch-name>" || {
    echo "ABORT: sub-branch invariant violated. Push the sub-branch to origin before opening the PR." >&2
    exit 1
}
```

The gate exits 0 in `local` mode (silent no-op). In `ci-pr` mode the orchestrator MUST NOT open a PR if this gate fails — bypassing reproduces the Flow C silent-skip pattern (bug da45-7d92-6c86-42bc).

### Step 2 — Open sub-branch PR against SESSION_BRANCH (ci-pr mode only)

The sub-branch PR targets the session branch, NOT main:

```bash
gh pr create \
  --base "$SESSION_BRANCH" \
  --head "<sub-branch-name>" \
  --title "bug-fix: <chunk-label>" \
  --body "Bug-Fix Mode chunk <K> — automated fix batch"
```

`SESSION_BRANCH` is the session worktree branch resolved by `resolve-session-branch.sh` at Phase G / Bug-Fix Mode start. Passing `--base main` here is a defect.

### Step 3 — Await CI; route discriminated outcome

Wait for CI test jobs (Hook Tests, Script Tests, ShellCheck, Lint) to complete before merging:

- **`MERGED`**: CI review passed; merge sub-branch into session branch.
- **`ESCALATED`**: CI review failed or PR blocked; do NOT merge; write `SUBBRANCH_ESCALATED: <sub-branch> reason=<...>` ticket comment FIRST (authoritative source of truth for COMPACTION_RESUME), then update aggregate draft PR `BLOCKED_SUBBRANCHES:` annotation SECOND; continue to next chunk.
- **`ERROR`**: CI workflow failed to produce a result; handle identically to `ESCALATED` but with `reason=ci-workflow-error`; write `SUBBRANCH_ESCALATED: <sub-branch> reason=ci-workflow-error` ticket comment, then update `BLOCKED_SUBBRANCHES:` annotation; continue to next chunk.

`ESCALATED` and `ERROR` do NOT halt the chunk loop — proceed to the next chunk after recording the outcome.

### Step 4 — End-of-chunk reconciliation

Verify the chunk's K tickets reached expected terminal or in-progress states. For each ticket in the chunk:
- Fixed and committed → must be `closed`
- Investigation-failed / COMPLEX_ESCALATION / MANUAL_APPROVAL_NEEDED → must remain `open` or `in_progress` with a tracking comment

Write a `CHUNK_RESULT:` tracking comment on the debug session epic:

```bash
.claude/scripts/dso ticket comment <epic-id> \
  "CHUNK_RESULT: sub_branch=<name> batch=<K> merged=<Y/N> fixed=<n> escalated=<n> failed=<n> timestamp=<UTC>"
```

### Step 5 — Session-leakage detection (non-fatal)

```bash
STORY_BRANCH_PREFIX=bug-batch/ bash "$PLUGIN_SCRIPTS/detect-session-leakage.sh" 2>&1 || true  # shim-exempt: dispatch-fix-batch orchestrator-direct invocation
```

Leakage findings are non-fatal — log and continue.
