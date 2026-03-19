---
id: w21-3hgc
status: closed
deps: []
links: []
created: 2026-03-19T01:53:05Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-t1xp
---
# Write RED Tests for Tool Error Hook Guard

Append 7 bash function tests to tests/hooks/test-track-tool-errors.sh. Insert function calls BEFORE the existing print_summary call. Tests use temp dirs for isolation; each creates its own mock workflow-config.conf and mock read-config.sh via PATH override.

Tests to add:
- test_tracking_disabled_when_flag_absent(): no config key → hook returns 0, no counter write
- test_tracking_disabled_when_flag_false(): monitoring.tool_errors=false → no counter write
- test_tracking_enabled_when_flag_true(): monitoring.tool_errors=true → counter write occurs
- test_standalone_hook_disabled_when_flag_absent(): track-tool-errors.sh exits 0, no write
- test_standalone_hook_enabled_when_flag_true(): track-tool-errors.sh writes counter
- test_tracking_disabled_when_read_config_fails(): when read-config.sh exits non-zero (PATH-mocked via a script that exits 1), hook returns 0 without writing counter file — tests the 2>/dev/null || echo "false" fallback behavioral contract
- test_tracking_disabled_when_flag_invalid_value(): monitoring.tool_errors=yes → disabled (strict != "true")

TDD REQUIREMENT: These tests FAIL (RED) before Task 1b adds guards. Tests assert guard behavior that does not yet exist.

File: tests/hooks/test-track-tool-errors.sh (append to existing file)

## Acceptance Criteria

- [ ] Tests fail before implementation (RED state)
  Verify: ! bash tests/hooks/test-track-tool-errors.sh
- [ ] Function test_tracking_disabled_when_flag_absent defined
  Verify: grep -qE '^test_tracking_disabled_when_flag_absent[[:space:]]*\(\)' tests/hooks/test-track-tool-errors.sh
- [ ] Function test_tracking_disabled_when_flag_false defined
  Verify: grep -qE '^test_tracking_disabled_when_flag_false[[:space:]]*\(\)' tests/hooks/test-track-tool-errors.sh
- [ ] Function test_tracking_enabled_when_flag_true defined
  Verify: grep -qE '^test_tracking_enabled_when_flag_true[[:space:]]*\(\)' tests/hooks/test-track-tool-errors.sh
- [ ] Function test_standalone_hook_disabled_when_flag_absent defined
  Verify: grep -qE '^test_standalone_hook_disabled_when_flag_absent[[:space:]]*\(\)' tests/hooks/test-track-tool-errors.sh
- [ ] Function test_standalone_hook_enabled_when_flag_true defined
  Verify: grep -qE '^test_standalone_hook_enabled_when_flag_true[[:space:]]*\(\)' tests/hooks/test-track-tool-errors.sh
- [ ] Function test_tracking_disabled_when_read_config_fails defined
  Verify: grep -qE '^test_tracking_disabled_when_read_config_fails[[:space:]]*\(\)' tests/hooks/test-track-tool-errors.sh
- [ ] Function test_tracking_disabled_when_flag_invalid_value defined
  Verify: grep -qE '^test_tracking_disabled_when_flag_invalid_value[[:space:]]*\(\)' tests/hooks/test-track-tool-errors.sh
- [ ] All 7 function calls present in file
  Verify: bash -c 'count=$(grep -cE "^(test_tracking_disabled_when_flag_absent|test_tracking_disabled_when_flag_false|test_tracking_enabled_when_flag_true|test_standalone_hook_disabled_when_flag_absent|test_standalone_hook_enabled_when_flag_true|test_tracking_disabled_when_read_config_fails|test_tracking_disabled_when_flag_invalid_value)$" tests/hooks/test-track-tool-errors.sh); [ "$count" -ge 7 ]'
- [ ] Flag name referenced in tests
  Verify: grep -iq 'monitoring.tool_errors' tests/hooks/test-track-tool-errors.sh

- [ ] Tests use WORKFLOW_CONFIG_FILE env var for isolation (not PATH override) since guard calls read-config.sh by absolute path
  Verify: grep -q 'WORKFLOW_CONFIG_FILE' tests/hooks/test-track-tool-errors.sh

## Notes

<!-- note-id: p34sc4qe -->
<!-- timestamp: 2026-03-19T02:23:08Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: Modified/created test files and docs. Tests: RED state confirmed.

<!-- note-id: 1wlcxyng -->
<!-- timestamp: 2026-03-19T02:45:52Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: appended 7 RED test functions to tests/hooks/test-track-tool-errors.sh
