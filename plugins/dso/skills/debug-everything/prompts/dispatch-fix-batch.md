# Dispatch Fix Batch (Phase G)

Loaded by `/dso:debug-everything` Phase G only — skipped entirely in Bug-Fix Mode (which delegates to fix-bug at orchestrator level).

## 1. Pre-batch checks

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check --db   # tiers 4-5  # shim-exempt: internal orchestration script
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh pre-check        # tiers 0-3, 6-7  # shim-exempt: internal orchestration script
```

Outputs `MAX_AGENTS`, `SESSION_USAGE`, `GIT_CLEAN`, `DB_STATUS`. Exit 1 ⇒ at least one check requires action.

**MAX_AGENTS protocol**:
- `unlimited` — dispatch ALL candidates in one batch, each with `run_in_background: true` in a single message.
- positive integer `N` — cap each batch at N; split into sequential batches of at most N if needed.
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

## 5. Dispatch each task via Task tool

Launch all sub-agents in the batch in a single message, each with `run_in_background: true`. Set `isolation: "worktree"` when `DISPATCH_ISOLATION=true`. Pass `ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)` so sub-agents can verify isolation.

Description: 3–5 word summary derived from ticket title (e.g., "Fix review gate hash"), not the bug ID.

**Delegate to `/dso:fix-bug`** — fix-bug encapsulates TDD vs. mechanical routing internally; debug-everything passes triage-derived context as pre-loaded data so fix-bug doesn't re-classify from scratch.

**Individual bug prompt**:
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

**Cluster prompt** (multiple related bugs resolved together):
```
/dso:fix-bug <id1> <id2> ...

### Triage Classification Context (pre-loaded — do not re-score)
Bug IDs: <id1>, <id2>
...

### File Ownership Context
{file_ownership_context}
```

**Triage-to-scoring mapping**:
- Tier 0–1 (mechanical): fix-bug bypasses scoring rubric.
- Tier 2+ (behavioral): provide severity + environment from triage. fix-bug performs its own post-investigation complexity evaluation (Step 4.5) by reading the `complexity-evaluator` named agent definition inline — it does NOT dispatch a sub-agent (avoids nested dispatch within sub-agent context). Fix-bug returns `COMPLEX_ESCALATION` if multi-agent planning is needed.

## 6. Subagent type selection

See `agent-routing-table.md` for the full table.
