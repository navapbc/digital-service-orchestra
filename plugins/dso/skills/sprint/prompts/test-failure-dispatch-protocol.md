# Test Failure Sub-Agent Dispatch Protocol

Common protocol for dispatching debugging sub-agents when tests fail during sprint execution.
Used by both Phase 5 (post-batch) and Phase 6 (E2E) test failure handlers.

## Input Payload

Build per `${CLAUDE_PLUGIN_ROOT}/docs/workflows/TEST-FAILURE-DISPATCH.md`:

| Field | Description |
|-------|-------------|
| `test_command` | The command that failed (caller provides) |
| `exit_code` | Exit code from the failed command |
| `stderr_tail` | Last 50 lines of output |
| `changed_files` | Files modified (caller provides scope) |
| `task_id` | Task ID for checkpoint notes (caller provides) |
| `context` | Dispatch context string (caller provides) |
| `attempt` | 1 on first try, increment on retry |
| `parent_task_id` | The epic ID (for discovered-work tickets) |
| `batch_task_ids` | IDs of all tasks in the current batch (Phase 5 only) |

## Model and Type Selection

Per TEST-FAILURE-DISPATCH.md Model Selection Table and Sub-Agent Type Selection table.

## Prompt Template

Read from `${CLAUDE_PLUGIN_ROOT}/skills/shared/prompts/test-failure-fix.md` and fill all placeholders with the input payload fields.

## Nesting Prohibition

The sprint ORCHESTRATOR dispatches the debugging sub-agent directly via `Task` tool — the debugging sub-agent must NOT dispatch nested `Task` calls. This respects CLAUDE.md rule #23 (two-level nesting causes `[Tool result missing due to internal error]` failures).

## Parse RESULT

| Result | Action |
|--------|--------|
| `PASS` | Tests fixed. Re-run validation to confirm, then continue. |
| `FAIL` (attempt 1) | Increment `attempt` to 2, retry with `opus` model. |
| `FAIL` (attempt 2) | Fall back: revert responsible task to open (`.claude/scripts/dso ticket transition <id> open`), add failure notes via `.claude/scripts/dso ticket comment`. |
| `PARTIAL` | Log concerns in ticket notes, continue with caveats. |
| Timeout / malformed | Fall back: revert task to open, add failure notes. |
