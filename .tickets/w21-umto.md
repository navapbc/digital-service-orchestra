---
id: w21-umto
status: in_progress
deps: [w21-a91w]
links: []
created: 2026-03-19T01:53:40Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-t1xp
---
# Add monitoring.tool_errors Guard to sweep_tool_errors

Add early-exit guard at the top of sweep_tool_errors() in plugins/dso/skills/end-session/error-sweep.sh. sweep_validation_failures() in the same file is NOT modified.

Guard to add at top of sweep_tool_errors():

  local _SWEEP_DIR; _SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local _MONITORING; _MONITORING=$(bash "$_SWEEP_DIR/../../scripts/read-config.sh" monitoring.tool_errors 2>/dev/null || echo "false")
  [[ "$_MONITORING" != "true" ]] && return 0

When flag is absent/non-true: returns 0 immediately without reading counter file or creating tickets.
When flag is true: existing sweep behavior unchanged.

TDD REQUIREMENT: Makes all 3 tests from Task w21-a91w GREEN. bash tests/scripts/test-end-session-error-sweep.sh must exit 0.

## Acceptance Criteria

- [ ] bash tests/scripts/test-end-session-error-sweep.sh exits 0 (GREEN)
  Verify: bash tests/scripts/test-end-session-error-sweep.sh
- [ ] Guard exists in sweep_tool_errors() in error-sweep.sh
  Verify: grep -q 'monitoring.tool_errors' plugins/dso/skills/end-session/error-sweep.sh
- [ ] sweep_validation_failures does NOT contain the guard (zero occurrences)
  Verify: bash -c 'awk "/^sweep_validation_failures/,/^\}/" plugins/dso/skills/end-session/error-sweep.sh | grep -c "monitoring.tool_errors" | grep -q "^0$"'
- [ ] bash tests/run-all.sh exits 0
  Verify: bash tests/run-all.sh

