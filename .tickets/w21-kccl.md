---
id: w21-kccl
status: open
deps: [w21-3hgc]
links: []
created: 2026-03-19T01:53:34Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-t1xp
---
# Add monitoring.tool_errors Guard to hook_track_tool_errors and track-tool-errors.sh

Add early-exit guard to two locations. Bundling required: splitting would leave one execution path ungated, creating inconsistent behavior.

1. Top of hook_track_tool_errors() in plugins/dso/hooks/lib/session-misc-functions.sh:

  local _HOOK_LIB_DIR; _HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local _MONITORING; _MONITORING=$(bash "$_HOOK_LIB_DIR/../../scripts/read-config.sh" monitoring.tool_errors 2>/dev/null || echo "false")
  [[ "$_MONITORING" != "true" ]] && return 0

2. Top of plugins/dso/hooks/track-tool-errors.sh (after HOOK_DIR is already defined):

  _MONITORING=$(bash "$HOOK_DIR/../../scripts/read-config.sh" monitoring.tool_errors 2>/dev/null || echo "false")
  [[ "$_MONITORING" != "true" ]] && exit 0

When flag is absent/non-true: returns 0 immediately with no file reads or writes.
When flag is true: existing behavior unchanged.

TDD REQUIREMENT: Makes all 7 tests from Task w21-3hgc GREEN. bash tests/hooks/test-track-tool-errors.sh must exit 0.

## Acceptance Criteria

- [ ] bash tests/hooks/test-track-tool-errors.sh exits 0 (GREEN — all 7 tests pass)
  Verify: bash tests/hooks/test-track-tool-errors.sh
- [ ] Guard exists in hook_track_tool_errors() in session-misc-functions.sh
  Verify: grep -q 'monitoring.tool_errors' plugins/dso/hooks/lib/session-misc-functions.sh
- [ ] Guard exists in track-tool-errors.sh
  Verify: grep -q 'monitoring.tool_errors' plugins/dso/hooks/track-tool-errors.sh
- [ ] Guard uses strict string equality (!= "true")
  Verify: grep -qE '!= "true"' plugins/dso/hooks/lib/session-misc-functions.sh
- [ ] bash tests/run-all.sh exits 0
  Verify: bash tests/run-all.sh

