# Session Init (Diagnostic Mode entry)

Loaded from `/dso:debug-everything` Phase B Step 1 only when `OPEN_BUG_COUNT == 0` (Bug-Fix Mode bypasses this entire procedure).

## 1. Export environment

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
PLUGIN_SCRIPTS="$PLUGIN_ROOT/scripts"
```

## 2. Worktree isolation config

```bash
ISOLATION_ENABLED=$(bash "$REPO_ROOT/.claude/scripts/dso" read-config worktree.isolation_enabled 2>/dev/null || true)
```

Set `DISPATCH_ISOLATION=true` when `ISOLATION_ENABLED` equals `true`; otherwise `DISPATCH_ISOLATION=false`. All sub-agent dispatches in Phases C, F, G, H, I, J, L, and Validation Mode must pass `isolation: "worktree"` when `DISPATCH_ISOLATION=true`. Apply consistently — do not mix isolated and non-isolated dispatches in the same session. See `skills/shared/prompts/worktree-dispatch.md`.

## 3. Validation-loop config bound

```bash
_raw_max_cycles=$(bash "$PLUGIN_SCRIPTS/read-config.sh" debug.max_fix_validate_cycles 2>/dev/null || echo "")
```

Bind `MAX_FIX_VALIDATE_CYCLES` per these rules:
- Empty / missing → `3` (default).
- Non-numeric → `3` with warning `"WARNING: debug.max_fix_validate_cycles is not numeric ('$_raw_max_cycles') — defaulting to 3"`.
- `<= 0` → `0` (skip validation loop entirely; proceed directly to Phase J after Bug-Fix Mode).
- `> 10` → `10` with warning `"WARNING: debug.max_fix_validate_cycles ($raw_val) exceeds cap of 10 — capping at 10"`.
- Otherwise → `$_raw_max_cycles`.

## 4. Session lock

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh lock-acquire "debug-everything"  # shim-exempt
```

Outputs `LOCK_ID: <id>` (success), `LOCK_BLOCKED: <id>` + `LOCK_WORKTREE: <path>` (another session holds it), or `LOCK_STALE: <id>` (stale lock auto-reclaimed; new lock acquired on next `LOCK_ID:` line).

- **`LOCK_ID`**: persist for Phase K release and survive compaction:
  ```bash
  source "${PLUGIN_ROOT}/hooks/lib/deps.sh"
  echo "$LOCK_ID" > "$(get_artifacts_dir)/debug-lock-id"
  ```
- **`LOCK_BLOCKED`**: STOP. Report: "Another `/dso:debug-everything` session is running from `<worktree>`. Wait for it to finish, or close `<lock-id>` to force-release."
- **`LOCK_STALE`**: continue — new lock was acquired.

## 5. Discovery cleanup

```bash
$PLUGIN_SCRIPTS/agent-batch-lifecycle.sh cleanup-discoveries  # shim-exempt
```

Cleanup failure is non-fatal; log warning, continue.

## 6. Interactivity question

Ask via `AskUserQuestion`: `"Is this an interactive session? (yes/no — press Enter for yes)"`.

- `yes` / no answer / timeout / empty → `INTERACTIVE_SESSION=true` (default).
- `no` → `INTERACTIVE_SESSION=false`. At any gate that would normally pause for user input, defer instead of blocking:
  - Leave the bug open (do not attempt any fix requiring user input).
  - Add a machine-parseable comment: `INTERACTIVITY_DEFERRED: <gate_name> | <context_summary>` where `gate_name` is one of: `safeguard_approval`, `complex_escalation`, `file_overlap`, `oscillation_guard`, `bug_accountability`. `context_summary` includes enough state (ticket IDs, error summaries, conflicting agent IDs) for the next interactive session to resume.
  - Continue to next bug or phase without blocking.

**Deferral decisions are made at orchestrator level only.** `fix-bug` sub-agents do NOT honor `INTERACTIVE_SESSION` themselves — the orchestrator intercepts `COMPLEX_ESCALATION` reports and other escalation signals before they reach the user.

**Resume limitation**: Phase B resume scans `CHECKPOINT` lines in ticket comments — it does NOT scan `INTERACTIVITY_DEFERRED` lines. After a non-interactive session, manually run `.claude/scripts/dso ticket list --type=bug --status=open` (and `--status=in_progress`) and check for `INTERACTIVITY_DEFERRED` comments to find items requiring follow-up.

## 7. Resume check

1. `.claude/scripts/dso ticket list --type=epic` → grep for "Project Health Restoration".
2. If found, use that epic as the tracker (skip creating a new one in Phase C).
3. List in-progress issues: `.claude/scripts/dso ticket list --status=in_progress`.
4. For each in-progress issue, read notes via `.claude/scripts/dso ticket show <id>`, parse CHECKPOINT lines, and apply:
   - **CHECKPOINT 6/6 ✓** → fast-close: verify files exist, close with `.claude/scripts/dso ticket transition <id> open closed`.
   - **CHECKPOINT 5/6 ✓** → near-complete; fast-close without re-execution.
   - **CHECKPOINT 3/6 ✓ or 4/6 ✓** → partial; re-dispatch with checkpoint note as resume context.
   - **CHECKPOINT 1/6 ✓ or 2/6 ✓** → early; revert to open: `.claude/scripts/dso ticket transition <id> open`.
   - **No CHECKPOINT or malformed/ambiguous** → revert to open.
