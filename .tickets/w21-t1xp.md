---
id: w21-t1xp
status: closed
deps: []
links: []
created: 2026-03-19T00:33:38Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# monitoring.tool_errors config flag for tool error tracking opt-in


## Notes

**2026-03-19T00:33:48Z**


## Context
DSO practitioners running the plugin on their own projects accumulate "Recurring tool error:" tickets that are noise for their workflow — the tool error tracking was built for the DSO project itself, where operational health matters. Today, there is no way to opt in or out: tracking is always on, but ticket creation is suppressed for two hardcoded noise categories. A project that wants clean ticket boards has no recourse, and a project that wants full tracking must rely on undocumented defaults. A single opt-in flag makes the feature explicit, documented, and safe-off for new adopters.

## Success Criteria
- When `monitoring.tool_errors` is absent or not `true`, `hook_track_tool_errors()` in `plugins/dso/hooks/lib/session-misc-functions.sh` returns 0 immediately without reading or writing the counter file; `sweep_tool_errors()` in `plugins/dso/skills/end-session/error-sweep.sh` returns 0 immediately without reading the counter file or creating tickets
- When `monitoring.tool_errors=true`, the hook categorizes errors via existing pattern matching, appends to `~/.claude/tool-error-counter.json`, increments category counts, and `sweep_tool_errors()` creates tickets for categories at or above the threshold — all existing behavior preserved
- The DSO plugin's own `workflow-config.conf` (at repo root) contains `monitoring.tool_errors=true`
- The `/dso:project-setup` skill prompts the user with a yes/no question during interactive configuration and writes `monitoring.tool_errors=true` or omits the key based on the user's answer (default: omit)
- `plugins/dso/docs/INSTALL.md` documents the flag, its default (false/absent), and when to enable it
- Unit tests in the existing hook and error-sweep test suites cover both the disabled path (no file writes, no ticket creation) and the enabled path (full tracking and ticket creation)

## Dependencies
None blocking. `read-config.sh` already supports boolean flag parsing. `dso-0wi2` (Project level config flags) is parallel and independent.

## Approach
Single boolean opt-in flag `monitoring.tool_errors=true` in `workflow-config.conf`. Both `hook_track_tool_errors()` and `sweep_tool_errors()` gate on this flag via `read-config.sh`. Absent or non-true = disabled (safe-off default). The flag is documented in INSTALL.md and prompted in the `/dso:project-setup` wizard.

