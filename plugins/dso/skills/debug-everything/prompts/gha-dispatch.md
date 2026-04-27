# GHA Scanner Dispatch

Single canonical procedure used in two locations:
1. **Phase A** — initial scan with epic-comment label `"GHA scan complete"`.
2. **Between-Batch GHA Refresh (Bug-Fix Mode)** — between-batch scan with epic-comment label `"GHA between-batch scan"`.

Caller passes `EPIC_COMMENT_LABEL` to disambiguate.

## Read config

```bash
GHA_SCAN_ENABLED=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config debug.gha_scan_enabled 2>/dev/null)
GHA_SCAN_ENABLED=${GHA_SCAN_ENABLED:-true}
GHA_WORKFLOWS=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config debug.gha_workflows 2>/dev/null)
GHA_WORKFLOWS=${GHA_WORKFLOWS:-}
```

## Gate checks (in order)

1. If `GHA_SCAN_ENABLED == false` → log `"GHA scan skipped: disabled via debug.gha_scan_enabled=false"` and return without dispatching.
2. If `GHA_WORKFLOWS` is absent or empty → log `"GHA scan skipped: no workflows configured"` and return without dispatching.

## Dispatch

```bash
_GHA_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
_GHA_ISOLATION_ENABLED=$(bash "$(git rev-parse --show-toplevel)/.claude/scripts/dso" read-config worktree.isolation_enabled 2>/dev/null)
_GHA_ISOLATION_ENABLED=${_GHA_ISOLATION_ENABLED:-false}
```

- Subagent: `subagent_type="general-purpose"`, `model="haiku"`.
- Prompt: read `${_GHA_PLUGIN_ROOT}/skills/debug-everything/prompts/gha-scanner.md` verbatim. Inject `WORKFLOWS=$GHA_WORKFLOWS` and `REPO_ROOT=$(git rev-parse --show-toplevel)` into prompt context.
- Isolation: apply `isolation: "worktree"` when `_GHA_ISOLATION_ENABLED == true`.

## After sub-agent returns

Parse compact JSON: `{"workflows_checked": N, "tickets_created": N, "failures_already_tracked": N, "new_ticket_ids": [...]}`.

If active epic ticket exists:
```bash
"$(git rev-parse --show-toplevel)/.claude/scripts/dso" ticket comment <epic-id> "${EPIC_COMMENT_LABEL}: <workflows_checked> workflows checked, <tickets_created> tickets created, <failures_already_tracked> already tracked. New tickets: <new_ticket_ids>"
```

If `tickets_created > 0`: new bug tickets (tagged `gha:<workflow-file-name>`) flow into the next open-bug-count check and are processed in Bug-Fix Mode on the next cycle.

If sub-agent returns `"GHA scan unavailable: workflow run tools not registered"`: log signal, return without writing epic comment.
